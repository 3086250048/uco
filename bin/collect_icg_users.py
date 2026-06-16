#!/usr/bin/env python3
import argparse
import base64
import concurrent.futures
import csv
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import ssl
from datetime import datetime


DEFAULT_ENV_FILE = "/root/.config/switch-toolkit/icg.env"
DEFAULT_OUTPUT_DIR = "/srv/smb/icg_users"
DEFAULT_WIRELESS_DIR = "/srv/smb/Wireless_user"
DEFAULT_AREAS = ["UCO", "GZ", "HN", "JS", "KS", "MLK", "TJ", "YZ"]


def load_env_file(path):
    values = {}
    if not path or not os.path.exists(path):
        return values
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def cfg(env, key, default=""):
    return os.environ.get(key) or env.get(key) or default


def decode_ldif_value(line):
    if "::" in line:
        key, value = line.split("::", 1)
        try:
            return key, base64.b64decode(value.strip()).decode("utf-8", errors="replace")
        except Exception:
            return key, value.strip()
    key, value = line.split(":", 1)
    return key, value.strip()


def first(row, key):
    values = row.get(key) or []
    return values[0] if values else ""


def run_ldapsearch(ad_host, bind_user, bind_password, base_dn, limit, include_disabled):
    filter_parts = [
        "(objectCategory=person)",
        "(objectClass=user)",
        "(sAMAccountName=*)",
        "(!(sAMAccountName=*$))",
    ]
    if not include_disabled:
        filter_parts.append("(!(userAccountControl:1.2.840.113556.1.4.803:=2))")
    ldap_filter = "(&" + "".join(filter_parts) + ")"
    attrs = [
        "sAMAccountName",
        "displayName",
        "distinguishedName",
        "mail",
        "department",
        "title",
        "company",
        "userPrincipalName",
        "userAccountControl",
    ]
    cmd = [
        "ldapsearch",
        "-LLL",
        "-x",
        "-o",
        "ldif-wrap=no",
        "-H",
        ad_host,
        "-D",
        bind_user,
        "-w",
        bind_password,
        "-b",
        base_dn,
    ]
    if limit:
        cmd.extend(["-z", str(limit)])
    cmd.append(ldap_filter)
    cmd.extend(attrs)
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode not in (0, 4):
        raise RuntimeError(f"ldapsearch failed: rc={proc.returncode} {proc.stderr.strip()}")

    entries = []
    current = {}
    for line in proc.stdout.splitlines():
        if not line.strip() or line.startswith("#"):
            if current:
                entries.append(current)
                current = {}
            continue
        if line.startswith(" ") or ":" not in line:
            continue
        key, value = decode_ldif_value(line)
        current.setdefault(key, []).append(value)
    if current:
        entries.append(current)

    seen = set()
    users = []
    for entry in entries:
        username = first(entry, "sAMAccountName")
        if not username or username in seen:
            continue
        seen.add(username)
        users.append(entry)
    return users


def request_json(url, method="GET", token="", data=None, timeout=60):
    headers = {}
    body = None
    if token:
        headers["token"] = token
    if data is not None:
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers["Content-type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_token(icg_base, username, password):
    payload = {
        "username": username,
        "password": hashlib.md5(password.encode("utf-8")).hexdigest(),
    }
    data = request_json(f"{icg_base}/api/v1/interface/token", method="POST", data=payload, timeout=30)
    if data.get("status") != 0 or not isinstance(data.get("data"), dict) or not data["data"].get("token"):
        raise RuntimeError(f"failed to get ICG token: {data}")
    return data["data"]["token"]


def query_user_detail(icg_base, token, username, timeout=90):
    url = f"{icg_base}/api/v1/interface/user/detail?name={urllib.parse.quote(username)}"
    return request_json(url, token=token, timeout=timeout)


def post_form_json(url, token, params, timeout=90):
    body = urllib.parse.urlencode(params).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "token": token,
            "Content-type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def query_app_policies(icg_base, token, page_size=200):
    policies = []
    start = 0
    total = None
    while total is None or start < total:
        data = post_form_json(
            f"{icg_base}/api/v1/policy_policyconfig/dapp/query",
            token,
            {"start": start, "limit": page_size},
        )
        if not data.get("success"):
            raise RuntimeError(f"failed to query app policies: {data}")
        batch = data.get("data") or []
        policies.extend(batch)
        total = int(data.get("total") or len(policies))
        if not batch:
            break
        start += len(batch)
    return policies


def latest_csv(dir_path):
    if not os.path.isdir(dir_path):
        return None
    files = [
        os.path.join(dir_path, name)
        for name in os.listdir(dir_path)
        if name.endswith(".csv")
    ]
    return max(files, key=os.path.getmtime) if files else None


def normalize_mac(mac):
    value = "".join(ch for ch in (mac or "").lower() if ch in "0123456789abcdef")
    if len(value) != 12:
        return ""
    return f"{value[0:4]}-{value[4:8]}-{value[8:12]}"


def load_wireless_user_map(wireless_dir, areas):
    by_user = {}
    paths = []
    latest = latest_csv(wireless_dir)
    if latest:
        paths.append(latest)
    for area in areas:
        path = latest_csv(os.path.join(wireless_dir, area))
        if path:
            paths.append(path)
    for path in dict.fromkeys(paths):
        with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
            reader = csv.reader(f)
            next(reader, None)
            for row in reader:
                if len(row) < 5:
                    continue
                username = row[1].strip()
                if not username or username == "(未认证)":
                    continue
                item = {
                    "ip": row[4].strip(),
                    "mac": normalize_mac(row[3].strip()),
                    "ap_name": row[0].strip(),
                    "ap_id": row[2].strip(),
                }
                by_user.setdefault(username.lower(), []).append(item)
    return by_user


def short_group(path, username):
    parts = [part for part in (path or "").split("/") if part]
    if parts and parts[0] in {"user", "adserver"}:
        parts = parts[1:]
    if parts and parts[0].startswith("AD-"):
        parts = parts[1:]
    if parts and parts[-1].lower() == username.lower():
        parts = parts[:-1]
    return "/".join(parts[-3:]) if len(parts) > 3 else "/".join(parts)


def policy_status_text(value):
    if value is True or value == 1 or value == "1":
        return "启用"
    if value is False or value == 0 or value == "0":
        return "禁用"
    return "" if value is None else str(value)


def collect_policy_conditions(policy):
    user_data = (((policy.get("user") or {}).get("data") or {}).get("user") or {})
    who = user_data.get("who") or []
    adwho = user_data.get("adwho") or []
    source_ips = user_data.get("sourceIp") or []
    return who, adwho, source_ips


def policy_matches_user(policy, username, fullpaths):
    who, adwho, source_ips = collect_policy_conditions(policy)
    if not who and not adwho and not source_ips and not ((policy.get("user") or {}).get("data") or {}).get("object"):
        return False, ""

    lower_name = username.lower()
    lower_fullpaths = [fp.lower() for fp in fullpaths if fp]
    for item in who:
        name = str(item.get("name") or "").lower()
        fullpath = str(item.get("fullpath") or "").lower()
        item_type = str(item.get("type") or "")
        if name == lower_name or fullpath.endswith("/" + lower_name):
            return True, "user"
        if item_type == "2" and fullpath:
            prefix = fullpath if fullpath.endswith("/") else fullpath + "/"
            if any(fp.startswith(prefix) for fp in lower_fullpaths):
                return True, "group"
    for item in adwho:
        name = str(item.get("name") or "").lower()
        if name == lower_name:
            return True, "aduser"
    return False, ""


def source_ips_for_policy(policy):
    _, _, source_ips = collect_policy_conditions(policy)
    ips = []
    for item in source_ips:
        if isinstance(item, str):
            ips.append(item)
        elif isinstance(item, dict):
            for key in ("ip", "name", "value"):
                if item.get(key):
                    ips.append(str(item[key]))
                    break
    return ips


def build_rows(users, details, app_policies, wireless_by_user):
    rows = []
    for entry in users:
        username = first(entry, "sAMAccountName")
        detail = details.get(username) or {}
        records = detail.get("data") if isinstance(detail, dict) else []
        records = records if isinstance(records, list) else []
        fullpaths = [rec.get("fullpath", "") for rec in records if isinstance(rec, dict)]
        wireless_items = wireless_by_user.get(username.lower()) or [{"ip": "", "mac": "", "ap_name": "", "ap_id": ""}]

        base = {
            "username": username,
            "displayName": first(entry, "displayName"),
            "mail": first(entry, "mail"),
            "department": first(entry, "department"),
            "title": first(entry, "title"),
            "company": first(entry, "company"),
            "userPrincipalName": first(entry, "userPrincipalName"),
        }

        for rec in records:
            if not isinstance(rec, dict):
                continue
            source = "AD/远端" if (rec.get("fullpath") or "").startswith("/adserver/") else "本地"
            group = short_group(rec.get("fullpath", ""), username)
            for policy in rec.get("policy") or []:
                if not isinstance(policy, dict):
                    continue
                for endpoint in wireless_items:
                    rows.append({
                        **base,
                        "ip": endpoint.get("ip", ""),
                        "mac": endpoint.get("mac", ""),
                        "policy_name": policy.get("name", ""),
                        "policy_priority": "",
                        "policy_status": policy_status_text(policy.get("status")),
                        "policy_type": policy.get("type", ""),
                        "policy_type_text": policy.get("typeText", ""),
                        "policy_state": policy.get("state", ""),
                        "policy_source": source,
                        "policy_group": group,
                        "policy_match": "user_detail",
                        "ap_name": endpoint.get("ap_name", ""),
                        "ap_id": endpoint.get("ap_id", ""),
                    })

        for policy in app_policies:
            matched, match_type = policy_matches_user(policy, username, fullpaths)
            if not matched:
                continue
            source_ips = source_ips_for_policy(policy)
            endpoints = wireless_items
            if source_ips:
                endpoints = [{"ip": ip, "mac": "", "ap_name": "", "ap_id": ""} for ip in source_ips]
            for endpoint in endpoints:
                rows.append({
                    **base,
                    "ip": endpoint.get("ip", ""),
                    "mac": endpoint.get("mac", ""),
                    "policy_name": policy.get("name", ""),
                    "policy_priority": policy.get("priority", ""),
                    "policy_status": policy_status_text(policy.get("status")),
                    "policy_type": policy.get("type", "nhapp"),
                    "policy_type_text": "应用控制策略",
                    "policy_state": "",
                    "policy_source": policy.get("source", ""),
                    "policy_group": "",
                    "policy_match": f"app_policy:{match_type}",
                    "ap_name": endpoint.get("ap_name", ""),
                    "ap_id": endpoint.get("ap_id", ""),
                })
    return rows


def write_outputs(output_dir, rows, details, app_policies, users, failures):
    os.makedirs(output_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    csv_path = os.path.join(output_dir, f"{timestamp}_icg_users.csv")
    json_path = os.path.join(output_dir, f"{timestamp}_icg_users.json")
    latest_csv_path = os.path.join(output_dir, "latest_icg_users.csv")
    latest_json_path = os.path.join(output_dir, "latest_icg_users.json")

    fields = [
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
    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({
            "generated_at": timestamp,
            "user_count": len(users),
            "row_count": len(rows),
            "app_policy_count": len(app_policies),
            "failure_count": len(failures),
            "failures": failures,
            "details": details,
            "app_policies": app_policies,
        }, f, ensure_ascii=False, indent=2)

    for src, dst in ((csv_path, latest_csv_path), (json_path, latest_json_path)):
        tmp = dst + ".tmp"
        with open(src, "rb") as rf, open(tmp, "wb") as wf:
            wf.write(rf.read())
        os.replace(tmp, dst)
    return csv_path, json_path


def parse_args():
    parser = argparse.ArgumentParser(description="从 AD 用户和 ICG API 采集用户关联策略。")
    parser.add_argument("--env-file", default=DEFAULT_ENV_FILE)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--wireless-dir", default=DEFAULT_WIRELESS_DIR)
    parser.add_argument("--areas", default=",".join(DEFAULT_AREAS))
    parser.add_argument("--limit", type=int, default=0, help="限制 AD 用户数量，0 表示不限制")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--include-disabled", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    env = load_env_file(args.env_file)
    ad_host = cfg(env, "AD_HOST", "ldap://10.2.1.9")
    ad_bind = cfg(env, "AD_BIND_USER")
    ad_password = cfg(env, "AD_PASSWORD")
    ad_base_dn = cfg(env, "AD_BASE_DN", "DC=uco,DC=com")
    icg_base = cfg(env, "ICG_BASE", "https://10.2.1.77").rstrip("/")
    icg_user = cfg(env, "ICG_USERNAME")
    icg_password = cfg(env, "ICG_PASSWORD")
    missing = [name for name, value in (
        ("AD_BIND_USER", ad_bind),
        ("AD_PASSWORD", ad_password),
        ("ICG_USERNAME", icg_user),
        ("ICG_PASSWORD", icg_password),
    ) if not value]
    if missing:
        print(f"missing config values: {', '.join(missing)}", file=sys.stderr)
        return 2

    started = time.time()
    areas = [item.strip() for item in args.areas.split(",") if item.strip()]
    print(f"读取 AD 用户: {ad_host} {ad_base_dn}")
    users = run_ldapsearch(ad_host, ad_bind, ad_password, ad_base_dn, args.limit, args.include_disabled)
    print(f"AD 用户数: {len(users)}")

    print("读取无线用户名与 IP/MAC 映射")
    wireless_by_user = load_wireless_user_map(args.wireless_dir, areas)
    print(f"无线用户映射数: {len(wireless_by_user)}")

    print("获取 ICG token")
    token = get_token(icg_base, icg_user, icg_password)
    print("读取 ICG 应用控制策略")
    app_policies = query_app_policies(icg_base, token)
    print(f"应用控制策略数: {len(app_policies)}")

    details = {}
    failures = {}
    print(f"读取 ICG 用户详情，并发: {args.workers}")
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        future_to_user = {
            executor.submit(query_user_detail, icg_base, token, first(entry, "sAMAccountName")): first(entry, "sAMAccountName")
            for entry in users
        }
        for idx, future in enumerate(concurrent.futures.as_completed(future_to_user), 1):
            username = future_to_user[future]
            try:
                details[username] = future.result()
            except Exception as exc:
                failures[username] = str(exc)
                details[username] = {"status": "error", "error": str(exc), "data": []}
            if idx % 100 == 0 or idx == len(users):
                print(f"  已处理 {idx}/{len(users)}")

    rows = build_rows(users, details, app_policies, wireless_by_user)
    csv_path, json_path = write_outputs(args.output_dir, rows, details, app_policies, users, failures)
    print(f"完成: users={len(users)} rows={len(rows)} failures={len(failures)} elapsed={time.time() - started:.1f}s")
    print(f"CSV: {csv_path}")
    print(f"JSON: {json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
