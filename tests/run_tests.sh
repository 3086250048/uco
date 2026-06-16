#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" "$ROOT_DIR/bin/__pycache__"' EXIT

export PATH="$ROOT_DIR/tests/mocks:$PATH"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -Fq "$expected" "$file" || fail "$file 未包含: $expected"
}

chmod +x "$ROOT_DIR/tests/mocks/snmpget" "$ROOT_DIR/tests/mocks/snmpbulkwalk"

IP_LIST="$TMP_DIR/ip.list"
{
    echo "# comment"
    echo "192.0.2.1"
} > "$IP_LIST"

"$ROOT_DIR/bin/collect_mac.sh" -i "$IP_LIST" -o "$TMP_DIR/mac" -p 2 >/dev/null
MAC_CSV="$(find "$TMP_DIR/mac" -name '*_mac.csv' | head -n 1)"
assert_file_contains "$MAC_CSV" '"192.0.2.1","10","0011-2233-4455","GigabitEthernet1/0/1"'

"$ROOT_DIR/bin/collect_mac_arp.sh" -i "$IP_LIST" -o "$TMP_DIR/mac_arp" -p 2 >/dev/null
MAC_ARP_CSV="$(find "$TMP_DIR/mac_arp" -name '*.csv' | head -n 1)"
assert_file_contains "$MAC_ARP_CSV" '"192.0.2.1","TestSwitch","10","0011-2233-4455","GigabitEthernet1/0/1","10.0.0.5"'

"$ROOT_DIR/bin/filter_100M_port.sh" -i "$IP_LIST" -o "$TMP_DIR/low" -p 2 >/dev/null
LOW_CSV="$(find "$TMP_DIR/low" -name '*.csv' | head -n 1)"
assert_file_contains "$LOW_CSV" '"TestSwitch","192.0.2.1","GigabitEthernet1/0/1","100"'

"$ROOT_DIR/bin/get_access_vlan.sh" -i "$IP_LIST" -o "$TMP_DIR/pvid" -p 2 >/dev/null
PVID_CSV="$(find "$TMP_DIR/pvid" -name '*_pvid.csv' | head -n 1)"
assert_file_contains "$PVID_CSV" '"192.0.2.1","TestSwitch","GigabitEthernet1/0/1","10"'

"$ROOT_DIR/bin/collect_switch_time.sh" -i "$IP_LIST" -o "$TMP_DIR/time" -p 2 >/dev/null
TIME_CSV="$(find "$TMP_DIR/time" -name '*_switch_time.csv' | head -n 1)"
assert_file_contains "$TIME_CSV" '"TestSwitch","192.0.2.1","2026-06-16 09:30:00.00 +08:00"'

AC_CONFIG="$TMP_DIR/ac_areas.tsv"
{
    printf 'UCO\t192.0.2.10\tucoac6508\thuawei\n'
    printf 'TJ\t192.0.2.20\tucoswitch\th3c\n'
} > "$AC_CONFIG"
"$ROOT_DIR/bin/collect_ac6508_users.sh" -f "$AC_CONFIG" -o "$TMP_DIR/ac" -p 1 >/dev/null
AC_CSV="$(find "$TMP_DIR/ac/UCO" -name '*_ac6508_users.csv' | head -n 1)"
assert_file_contains "$AC_CSV" 'AP-1,alice,7,0011-2233-4455,10.0.0.5'
TJ_AC_CSV="$(find "$TMP_DIR/ac/TJ" -name '*_ac6508_users.csv' | head -n 1)"
assert_file_contains "$TJ_AC_CSV" 'AP1,bob,70c6-dd1b-8e40,c2b8-c93e-6815,10.205.20.57'
if grep -Fq '8ca9-82f9-bc80' "$TJ_AC_CSV"; then
    fail "$TJ_AC_CSV 包含已下线客户端"
fi

mkdir -p "$TMP_DIR/index/mac/UCO" "$TMP_DIR/index/wireless/UCO" "$TMP_DIR/index/icg" "$TMP_DIR/index/find"
cp "$MAC_ARP_CSV" "$TMP_DIR/index/mac/UCO/latest.csv"
cp "$AC_CSV" "$TMP_DIR/index/wireless/UCO/latest.csv"
{
    echo 'username,displayName,mail,department,title,company,userPrincipalName,ip,mac,policy_name,policy_priority,policy_status,policy_type,policy_type_text,policy_state,policy_source,policy_group,policy_match,ap_name,ap_id'
    echo 'alice,Alice,,,,,alice@example.com,10.0.0.5,0011-2233-4455,Test-01,4,启用,nhapp,应用控制策略,,local,,app_policy:user,AP-1,7'
} > "$TMP_DIR/index/icg/latest_icg_users.csv"
"$ROOT_DIR/bin/csv_to_ip.py" --mac-dir "$TMP_DIR/index/mac" --wireless-dir "$TMP_DIR/index/wireless" --icg-dir "$TMP_DIR/index/icg" --find-dir "$TMP_DIR/index/find" --areas UCO >/dev/null
assert_file_contains "$TMP_DIR/index/find/10.0.0.5.txt" '查询IP: 10.0.0.5'
assert_file_contains "$TMP_DIR/index/find/10.0.0.5.txt" '无线接入信息:'
assert_file_contains "$TMP_DIR/index/find/10.0.0.5.txt" 'ICG用户策略信息:'
assert_file_contains "$TMP_DIR/index/find/10.0.0.5.txt" 'Test-01'

bash -n "$ROOT_DIR"/bin/*.sh "$ROOT_DIR/bin/get_mac_port"
python3 -m py_compile \
    "$ROOT_DIR/bin/csv_to_ip.py" \
    "$ROOT_DIR/bin/collect_icg_users.py" \
    "$ROOT_DIR/bin/icg_lookup_for_ip.py" \
    "$ROOT_DIR/bin/samba_audit_trigger.py"

echo "OK: all tests passed"
