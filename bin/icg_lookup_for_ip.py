#!/usr/bin/env python3
import argparse
import csv
import json
import os
import re
import sys
import time
from datetime import datetime

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if ROOT_DIR not in sys.path:
    sys.path.insert(0, ROOT_DIR)
BIN_DIR = os.path.join(ROOT_DIR, "bin")
if BIN_DIR not in sys.path:
    sys.path.insert(0, BIN_DIR)

from collect_icg_users import (  # noqa: E402
    DEFAULT_AREAS,
    DEFAULT_ENV_FILE,
    DEFAULT_OUTPUT_DIR,
    DEFAULT_WIRELESS_DIR,
    build_rows,
    cfg,
    get_token,
    latest_csv,
    load_env_file,
    normalize_mac,
    query_app_policies,
    query_user_detail,
)


FIELDS = [
    "username",
    "displayName",
    "mail",
    "department",
    "title",
    "company",
    "userPrincipalName",
    "ip",
    "mac",
    "policy_name",
    "policy_priority",
    "policy_status",
    "policy_type",
    "policy_type_text",
    "policy_state",
    "policy_source",
    "policy_group",
    "policy_match",
    "ap_name",
    "ap_id",
]

BEGIN_MARKER = "## ICG用户策略信息 BEGIN"
END_MARKER = "## ICG用户策略信息 END"


def is_valid_ip(value):
    parts = value.split(".")
    if len(parts) != 4:
        return False
    try:
        nums = [int(part) for part in parts]
    except ValueError:
        return False
    return all(0 <= num <= 255 for num in nums)


def ip_from_path(path):
    name = os.path.basename(path)
    if name.endswith(".txt"):
        name = name[:-4]
    return name if is_valid_ip(name) else ""


def latest_wireless_csvs(wireless_dir, areas):
    paths = []
    root_latest = latest_csv(wireless_dir)
    if root_latest:
        paths.append(root_latest)
    for area in areas:
        path = latest_csv(os.path.join(wireless_dir, area))
        if path:
            paths.append(path)
    return list(dict.fromkeys(paths))


def usernames_from_wireless(ip, wireless_dir, areas):
    users = {}
    for path in latest_wireless_csvs(wireless_dir, areas):
        with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
            reader = csv.reader(f)
            next(reader, None)
            for row in reader:
                if len(row) < 5 or row[4].strip() != ip:
                    continue
                username = row[1].strip()
                if not username or username == "(未认证)":
                    continue
                users.setdefault(username.lower(), {
                    "username": username,
                    "ip": row[4].strip(),
                    "mac": normalize_mac(row[3].strip()),
                    "ap_name": row[0].strip(),
                    "ap_id": row[2].strip(),
                })
    return users


def usernames_from_ip_file(ip, path):
    users = {}
    if not os.path.exists(path):
        return users
    mac_pattern = re.compile(r"^[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}$")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if ip not in line or "用户名" in line or "查询IP" in line:
                continue
            parts = line.split()
            for idx, part in enumerate(parts):
                if not mac_pattern.match(part):
                    continue
                if idx + 1 >= len(parts) or parts[idx + 1] != ip or idx < 3:
                    continue
                username = parts[idx - 1].strip()
                if username and username != "(未认证)":
                    users.setdefault(username.lower(), {
                        "username": username,
                        "ip": ip,
                        "mac": part,
                        "ap_name": " ".join(parts[:idx - 2]),
                        "ap_id": parts[idx - 2],
                    })
    return users


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path, payload):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def load_cached_rows(csv_path):
    rows = []
    with open(csv_path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({field: row.get(field, "") for field in FIELDS})
    return filter_enabled_app_rows(rows)


def is_enabled_app_policy(row):
    policy_type = (row.get("policy_type") or "").strip().lower()
    policy_type_text = (row.get("policy_type_text") or "").strip()
    policy_status = (row.get("policy_status") or "").strip()
    return (
        (policy_type == "nhapp" or policy_type_text == "应用控制策略")
        and policy_status == "启用"
        and bool((row.get("policy_name") or "").strip())
    )


def filter_enabled_app_rows(rows):
    return [row for row in rows if is_enabled_app_policy(row)]


def collect_rows(ip, endpoints_by_user, env, timeout):
    icg_base = cfg(env, "ICG_BASE", "https://10.2.1.77").rstrip("/")
    icg_user = cfg(env, "ICG_USERNAME")
    icg_password = cfg(env, "ICG_PASSWORD")
    missing = [name for name, value in (("ICG_USERNAME", icg_user), ("ICG_PASSWORD", icg_password)) if not value]
    if missing:
        raise RuntimeError(f"missing config values: {', '.join(missing)}")

    token = get_token(icg_base, icg_user, icg_password)
    app_policies = query_app_policies(icg_base, token)
    users = []
    details = {}
    failures = {}
    wireless_by_user = {}

    for key, endpoint in sorted(endpoints_by_user.items()):
        username = endpoint["username"]
        users.append({"sAMAccountName": [username]})
        wireless_by_user[key] = [{
            "ip": endpoint.get("ip") or ip,
            "mac": endpoint.get("mac", ""),
            "ap_name": endpoint.get("ap_name", ""),
            "ap_id": endpoint.get("ap_id", ""),
        }]
        try:
            details[username] = query_user_detail(icg_base, token, username, timeout=timeout)
        except Exception as exc:
            failures[username] = str(exc)
            details[username] = {"status": "error", "error": str(exc), "data": []}

    rows = filter_enabled_app_rows(build_rows(users, details, app_policies, wireless_by_user))
    return rows, details, app_policies, failures


def format_table(headers, rows):
    if not rows:
        return ["  无"]
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, value in enumerate(row):
            widths[idx] = max(widths[idx], len(str(value)))
    lines = [
        "  " + "  ".join(headers[idx].ljust(widths[idx]) for idx in range(len(headers))),
        "  " + "  ".join("-" * widths[idx] for idx in range(len(headers))),
    ]
    for row in rows:
        lines.append("  " + "  ".join(str(row[idx]).ljust(widths[idx]) for idx in range(len(headers))))
    return lines


def dedupe_rows(rows):
    seen = set()
    result = []
    for row in rows:
        key = (
            row.get("username", ""),
            row.get("policy_type_text", ""),
            row.get("policy_name", ""),
            row.get("policy_priority", ""),
            row.get("policy_status", ""),
            row.get("policy_source", ""),
        )
        if key in seen:
            continue
        seen.add(key)
        result.append(row)
    return result


def policy_names_for_user(rows):
    by_user = {}
    for row in dedupe_rows(filter_enabled_app_rows(rows)):
        username = (row.get("username") or "").strip().lower()
        policy_name = (row.get("policy_name") or "").strip()
        if not username or not policy_name:
            continue
        by_user.setdefault(username, []).append(policy_name)
    return by_user


def unique_policy_names(rows):
    names = []
    seen = set()
    for row in dedupe_rows(filter_enabled_app_rows(rows)):
        policy_name = (row.get("policy_name") or "").strip()
        if not policy_name or policy_name in seen:
            continue
        seen.add(policy_name)
        names.append(policy_name)
    return names


def render_block(ip, endpoints_by_user, rows, failures, generated_at, cached):
    lines = [
        f"查询时间：{generated_at}",
        f"查询IP：{ip}",
        f"缓存结果：{'是' if cached else '否'}",
        "",
    ]
    endpoint_rows = [
        [
            item.get("username", ""),
            item.get("ip", "") or ip,
            item.get("mac", ""),
            item.get("ap_name", ""),
            item.get("ap_id", ""),
        ]
        for item in endpoints_by_user.values()
    ]
    lines.extend(format_table(["用户名", "IP", "MAC", "AP名称", "APID"], endpoint_rows))
    lines.extend(["", "启用的应用控制策略", "------------------"])
    policy_names = unique_policy_names(rows)
    lines.extend(policy_names if policy_names else ["无"])
    if failures:
        lines.append("")
        lines.append("查询失败用户:")
        lines.extend(format_table(["用户名", "错误"], [[name, err] for name, err in sorted(failures.items())]))
    return "\n".join(lines) + "\n\n"


def update_ip_file(path, block):
    old_content = ""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            old_content = f.read()
    old_marker_pattern = re.compile(re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER) + r"\n*", re.S)
    cleaned = old_marker_pattern.sub("", old_content)
    new_block_pattern = re.compile(r"^查询时间：.*?(?=^## \d{4}-\d{2}-\d{2}|\Z)", re.S | re.M)
    cleaned = new_block_pattern.sub("", cleaned, count=1).lstrip()
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(block)
        f.write(cleaned)
    os.replace(tmp, path)


def parse_args():
    parser = argparse.ArgumentParser(description="按 IP 文件中的用户名查询 ICG 策略并写回 IP 文件。")
    parser.add_argument("ip_file")
    parser.add_argument("--env-file", default=DEFAULT_ENV_FILE)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--wireless-dir", default=DEFAULT_WIRELESS_DIR)
    parser.add_argument("--areas", default=",".join(DEFAULT_AREAS))
    parser.add_argument("--cache-ttl", type=int, default=600)
    parser.add_argument("--timeout", type=int, default=20)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    ip = ip_from_path(args.ip_file)
    if not ip:
        print(f"not an IP txt file: {args.ip_file}", file=sys.stderr)
        return 2

    areas = [item.strip() for item in args.areas.split(",") if item.strip()]
    endpoints = usernames_from_ip_file(ip, args.ip_file)
    endpoints.update(usernames_from_wireless(ip, args.wireless_dir, areas))
    os.makedirs(args.output_dir, exist_ok=True)

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    csv_path = os.path.join(args.output_dir, f"{ip}_icg_users.csv")
    json_path = os.path.join(args.output_dir, f"{ip}_icg_users.json")
    cached = False
    details = {}
    app_policies = []
    failures = {}

    if not endpoints:
        block = render_block(ip, endpoints, [], {}, generated_at, cached=False)
        update_ip_file(args.ip_file, block)
        return 0

    if (
        not args.force
        and args.cache_ttl > 0
        and os.path.exists(csv_path)
        and time.time() - os.path.getmtime(csv_path) < args.cache_ttl
    ):
        rows = load_cached_rows(csv_path)
        cached = True
    else:
        env = load_env_file(args.env_file)
        rows, details, app_policies, failures = collect_rows(ip, endpoints, env, timeout=args.timeout)
        write_csv(csv_path, rows)
        write_json(json_path, {
            "generated_at": generated_at,
            "ip": ip,
            "usernames": [item["username"] for item in endpoints.values()],
            "row_count": len(rows),
            "failure_count": len(failures),
            "failures": failures,
            "details": details,
            "app_policies": app_policies,
        })

    block = render_block(ip, endpoints, rows, failures, generated_at, cached)
    update_ip_file(args.ip_file, block)
    print(f"updated {args.ip_file}; users={len(endpoints)} rows={len(rows)} cached={cached}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
