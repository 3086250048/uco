#!/usr/bin/env python3
import csv
import glob
import os
import argparse
from datetime import datetime

DEFAULT_MAC_DIR = os.environ.get("MAC_TABLE_DIR", "/srv/smb/mac_table")
DEFAULT_WIRELESS_DIR = os.environ.get("WIRELESS_USER_DIR", "/srv/smb/Wireless_user")
DEFAULT_ICG_DIR = os.environ.get("ICG_USER_DIR", "/srv/smb/icg_users")
DEFAULT_FIND_DIR = os.environ.get("FIND_OUTPUT_DIR", "/srv/smb/find")
DEFAULT_AREAS = ["UCO", "GZ", "HN", "JS", "KS", "MLK", "TJ", "YZ"]

AGG_PORT_KEYWORDS = (
    "bridge-aggregation",
    "eth-trunk",
    "port-channel",
    "route-aggregation",
)


def get_latest_csv(dir_path):
    csv_files = glob.glob(os.path.join(dir_path, "*.csv"))
    return max(csv_files, key=os.path.getmtime) if csv_files else None


def get_all_csv(dir_path):
    return sorted(glob.glob(os.path.join(dir_path, "*.csv")), key=os.path.getmtime, reverse=True)


def get_wireless_csvs(dir_path, areas):
    csv_files = get_all_csv(dir_path)
    for area in areas:
        csv_file = get_latest_csv(os.path.join(dir_path, area))
        if csv_file:
            csv_files.append(csv_file)
    return sorted(dict.fromkeys(csv_files), key=os.path.getmtime, reverse=True)


def normalize_mac(mac):
    value = "".join(ch for ch in mac.lower() if ch in "0123456789abcdef")
    if len(value) != 12:
        return ""
    return f"{value[0:4]}-{value[4:8]}-{value[8:12]}"


def is_aggregation_port(port_name):
    port = port_name.strip().lower()
    return any(keyword in port for keyword in AGG_PORT_KEYWORDS)


def is_valid_ip(ip):
    value = ip.strip()
    if value in {"", "0.0.0.0"}:
        return False
    parts = value.split(".")
    if len(parts) != 4:
        return False
    try:
        nums = [int(part) for part in parts]
    except ValueError:
        return False
    return all(0 <= num <= 255 for num in nums)


def dedupe_dicts(rows, keys):
    seen = set()
    result = []
    for row in rows:
        marker = tuple(row.get(key, "") for key in keys)
        if marker in seen:
            continue
        seen.add(marker)
        result.append(row)
    return result


def format_table(headers, rows):
    if not rows:
        return ["  无"]

    widths = []
    for i, header in enumerate(headers):
        max_width = len(header)
        for row in rows:
            max_width = max(max_width, len(str(row[i])))
        widths.append(max_width)

    lines = []
    header_line = "  " + "  ".join(str(headers[i]).ljust(widths[i]) for i in range(len(headers)))
    separator = "  " + "  ".join("-" * widths[i] for i in range(len(headers)))
    lines.extend([header_line, separator])
    for row in rows:
        lines.append("  " + "  ".join(str(row[i]).ljust(widths[i]) for i in range(len(headers))))
    return lines


def load_mac_table(csv_path, area, state):
    with open(csv_path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
        reader = csv.reader(f)
        next(reader, None)
        for row in reader:
            if len(row) < 6:
                continue

            mac = normalize_mac(row[3].strip())
            host_ip = row[5].strip()
            if not mac:
                continue

            item = {
                "area": area,
                "device_ip": row[0].strip(),
                "device_name": row[1].strip(),
                "vlan": row[2].strip(),
                "mac": mac,
                "port": row[4].strip(),
                "host_ip": host_ip,
                "source": csv_path,
            }

            state["mac_rows"].setdefault(mac, []).append(item)
            if is_valid_ip(host_ip):
                state["ip_to_macs"].setdefault(host_ip, set()).add(mac)


def load_wireless(csv_path, state):
    with open(csv_path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
        reader = csv.reader(f)
        next(reader, None)
        for row in reader:
            if len(row) < 5:
                continue

            mac = normalize_mac(row[3].strip())
            host_ip = row[4].strip()
            if not mac:
                continue

            item = {
                "ap_name": row[0].strip(),
                "username": row[1].strip(),
                "ap_id": row[2].strip(),
                "mac": mac,
                "host_ip": host_ip,
                "source": csv_path,
            }

            state["wireless_rows"].setdefault(mac, []).append(item)
            if is_valid_ip(host_ip):
                state["ip_to_macs"].setdefault(host_ip, set()).add(mac)


def load_icg_users(csv_path, state):
    with open(csv_path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            username = (row.get("username") or "").strip()
            policy_name = (row.get("policy_name") or "").strip()
            policy_status = (row.get("policy_status") or "").strip()
            policy_type = (row.get("policy_type") or "").strip().lower()
            policy_type_text = (row.get("policy_type_text") or "").strip()
            host_ip = (row.get("ip") or "").strip()
            if (
                not username
                or not policy_name
                or policy_status != "启用"
                or (policy_type != "nhapp" and policy_type_text != "应用控制策略")
            ):
                continue

            item = {
                "username": username,
                "ip": host_ip,
                "policy_name": policy_name,
                "policy_priority": (row.get("policy_priority") or "").strip(),
                "policy_status": policy_status,
                "policy_type_text": policy_type_text or policy_type,
                "policy_source": (row.get("policy_source") or row.get("policy_match") or "").strip(),
            }
            state["icg_policy_rows_by_user"].setdefault(username.lower(), []).append(item)
            if is_valid_ip(host_ip):
                state["icg_policy_rows_by_ip"].setdefault(host_ip, []).append(item)


def build_state(mac_dir, wireless_dir, icg_dir, areas):
    state = {
        "mac_rows": {},
        "wireless_rows": {},
        "icg_policy_rows_by_user": {},
        "icg_policy_rows_by_ip": {},
        "ip_to_macs": {},
        "mac_sources": [],
        "wireless_sources": [],
        "icg_sources": [],
    }

    for sub in areas:
        src_dir = os.path.join(mac_dir, sub)
        if not os.path.isdir(src_dir):
            continue
        csv_file = get_latest_csv(src_dir)
        if not csv_file:
            print(f"No CSV file found in {src_dir}")
            continue
        print(f"Processing mac_table {csv_file}")
        state["mac_sources"].append(csv_file)
        load_mac_table(csv_file, sub, state)

    wireless_files = get_wireless_csvs(wireless_dir, areas)
    if wireless_files:
        for wireless_csv in wireless_files:
            print(f"Processing wireless_user {wireless_csv}")
            state["wireless_sources"].append(wireless_csv)
            load_wireless(wireless_csv, state)
    else:
        print(f"No CSV file found in {wireless_dir}")

    icg_csv = os.path.join(icg_dir, "latest_icg_users.csv")
    if not os.path.exists(icg_csv):
        icg_csv = get_latest_csv(icg_dir)
    if icg_csv:
        print(f"Processing icg_users {icg_csv}")
        state["icg_sources"].append(icg_csv)
        load_icg_users(icg_csv, state)
    else:
        print(f"No CSV file found in {icg_dir}")

    return state


def collect_icg_policy_rows(ip, macs, state):
    rows = []
    usernames = set()
    for mac in macs:
        for wireless in state["wireless_rows"].get(mac, []):
            username = wireless.get("username", "").strip()
            if username and username != "(未认证)":
                usernames.add(username.lower())

    for username in sorted(usernames):
        rows.extend(state["icg_policy_rows_by_user"].get(username, []))
    rows.extend(state["icg_policy_rows_by_ip"].get(ip, []))
    return dedupe_dicts(
        rows,
        ["username", "policy_type_text", "policy_name", "policy_priority", "policy_status", "policy_source"],
    )


def render_ip_block(ip, macs, state):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        f"## {timestamp}",
        f"查询IP: {ip}",
        f"关联MAC: {', '.join(sorted(macs))}",
        "",
    ]

    for mac in sorted(macs):
        mac_rows = dedupe_dicts(
            state["mac_rows"].get(mac, []),
            ["area", "device_ip", "device_name", "vlan", "mac", "port", "host_ip"],
        )
        wireless_rows = dedupe_dicts(
            state["wireless_rows"].get(mac, []),
            ["ap_name", "username", "ap_id", "mac", "host_ip"],
        )
        wireless_access_rows = [row for row in wireless_rows if row["host_ip"] == ip]
        access_rows = [row for row in mac_rows if not is_aggregation_port(row["port"])]

        if wireless_access_rows:
            lines.append("无线接入信息:")
            lines.extend(format_table(
                ["AP名称", "APID", "用户名", "MAC", "IP"],
                [[r["ap_name"], r["ap_id"], r["username"], r["mac"], r["host_ip"]] for r in wireless_access_rows],
            ))
            lines.append("")
            continue

        if access_rows:
            lines.append("有线非聚合接入口:")
            lines.extend(format_table(
                ["区域", "设备IP", "设备名称", "VLAN", "端口", "主机IP"],
                [[r["area"], r["device_ip"], r["device_name"], r["vlan"], r["port"], r["host_ip"]] for r in access_rows],
            ))
            lines.append("")
        else:
            lines.append("无线接入信息:")
            if wireless_rows:
                lines.extend(format_table(
                    ["AP名称", "APID", "用户名", "MAC", "IP"],
                    [[r["ap_name"], r["ap_id"], r["username"], r["mac"], r["host_ip"]] for r in wireless_rows],
                ))
            else:
                lines.append("  无匹配无线记录")
            lines.append("")

    icg_policy_rows = collect_icg_policy_rows(ip, macs, state)
    if icg_policy_rows:
        lines.append("ICG用户策略信息:")
        lines.extend(format_table(
            ["用户名", "策略类型", "策略名称", "优先级", "状态", "来源"],
            [
                [
                    r["username"],
                    r["policy_type_text"],
                    r["policy_name"],
                    r["policy_priority"],
                    r["policy_status"],
                    r["policy_source"],
                ]
                for r in icg_policy_rows
            ],
        ))
        lines.append("")

    return "\n".join(lines).rstrip() + "\n\n"


def write_find_files(state, find_dir):
    os.makedirs(find_dir, exist_ok=True)

    for ip, macs in sorted(state["ip_to_macs"].items()):
        if not is_valid_ip(ip):
            continue

        out_file = os.path.join(find_dir, f"{ip}.txt")
        old_content = ""
        if os.path.exists(out_file):
            with open(out_file, "r", encoding="utf-8") as f:
                old_content = f.read()

        new_block = render_ip_block(ip, macs, state)
        with open(out_file, "w", encoding="utf-8") as f:
            f.write(new_block + old_content)


def parse_args():
    parser = argparse.ArgumentParser(description="从 MAC/无线 CSV 生成按 IP 查询的文本索引。")
    parser.add_argument("--mac-dir", default=DEFAULT_MAC_DIR)
    parser.add_argument("--wireless-dir", default=DEFAULT_WIRELESS_DIR)
    parser.add_argument("--icg-dir", default=DEFAULT_ICG_DIR)
    parser.add_argument("--find-dir", default=DEFAULT_FIND_DIR)
    parser.add_argument("--areas", default=",".join(DEFAULT_AREAS), help="逗号分隔的区域目录名")
    return parser.parse_args()


def main():
    args = parse_args()
    areas = [item.strip() for item in args.areas.split(",") if item.strip()]
    state = build_state(args.mac_dir, args.wireless_dir, args.icg_dir, areas)
    write_find_files(state, args.find_dir)
    print(f"Done. Generated/updated {len(state['ip_to_macs'])} files in {args.find_dir}")


if __name__ == "__main__":
    main()
