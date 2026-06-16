#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
# ============================================================
# 脚本名称: collect_mac_arp_universal.sh
# 功能: 并行获取多台交换机的MAC地址表，并关联ARP表获取对应IP
#       自动适配设备：优先使用Q-BRIDGE-MIB（含VLAN），回退BRIDGE-MIB（无VLAN）
# 输出字段: 设备IP, 设备名称, VLAN, MAC, 端口, 主机IP
# 依赖: snmpbulkwalk (net-snmp-utils), awk
# ============================================================

COMMUNITY="ucoswitch"
SNMP_VERSION="2c"
OUTPUT_DIR="./"
PARALLEL_JOBS=10
IP_LIST_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) IP_LIST_FILE="$2"; shift 2 ;;
        -o) OUTPUT_DIR="$2"; shift 2 ;;
        -p) PARALLEL_JOBS="$2"; shift 2 ;;
        -c) COMMUNITY="$2"; shift 2 ;;
        -h|--help) echo "用法: $0 -i <ip_list_file> [-o output_dir] [-p parallel_jobs] [-c community]"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[[ -n "$IP_LIST_FILE" ]] || die "用法: $0 -i <ip_list_file> [-o output_dir] [-p parallel_jobs] [-c community]"
ensure_file "$IP_LIST_FILE"

ensure_dir "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d%H")
FINAL_OUTPUT="${OUTPUT_DIR}/${TIMESTAMP}.csv"
TMP_PREFIX="${OUTPUT_DIR}/.mac_ip_tmp_$$"

cleanup() {
    rm -f "${TMP_PREFIX}"_* 2>/dev/null
}
trap cleanup EXIT

echo "开始采集（自动适配VLAN），临时文件前缀: ${TMP_PREFIX}_ ，最终输出: $FINAL_OUTPUT"

process_switch() {
    local switch_ip="$1"
    local sysname=$(snmpget -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.1.5.0" 2>/dev/null | awk -F'"' '{print $2}')
    local tmp_if=$(mktemp) || return 1
    local tmp_port=$(mktemp) || return 1
    local tmp_mac_q=$(mktemp) || return 1
    local tmp_mac_b=$(mktemp) || return 1
    local tmp_arp=$(mktemp) || return 1
    local tmp_out="${TMP_PREFIX}_${switch_ip//./_}"

    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.2.2.1.2" > "$tmp_if" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.17.1.4.1.2" > "$tmp_port" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.17.7.1.2.2.1.2" > "$tmp_mac_q" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.17.4.3.1.2" > "$tmp_mac_b" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.4.22.1.2" > "$tmp_arp" 2>/dev/null &
    wait

    if [[ ! -s "$tmp_if" || ! -s "$tmp_port" ]]; then
        rm -f "$tmp_if" "$tmp_port" "$tmp_mac_q" "$tmp_mac_b" "$tmp_arp"
        return 1
    fi

    local use_q_bridge=0
    if [[ -s "$tmp_mac_q" ]] && grep -q "INTEGER:" "$tmp_mac_q"; then
        use_q_bridge=1
    fi

    if [[ $use_q_bridge -eq 0 && ! -s "$tmp_mac_b" ]]; then
        rm -f "$tmp_if" "$tmp_port" "$tmp_mac_q" "$tmp_mac_b" "$tmp_arp"
        return 1
    fi

    if [[ $use_q_bridge -eq 1 ]]; then
        awk -v ip="$switch_ip" -v devname="$sysname" '
        BEGIN { OFS="," }
        function csv(value) {
            gsub(/"/, "\"\"", value)
            return "\"" value "\""
        }
        FILENAME == ARGV[1] && /STRING:/ {
            split($1, a, ".")
            ifIndex = a[length(a)]
            name = $0
            sub(/.*STRING: "/, "", name)
            sub(/".*/, "", name)
            ifindex_to_name[ifIndex] = name
            next
        }
        FILENAME == ARGV[2] && /INTEGER:/ {
            split($1, a, ".")
            logicalPort = a[length(a)]
            ifIndex = $NF
            logical_to_ifindex[logicalPort] = ifIndex
            next
        }
        FILENAME == ARGV[3] && /Hex-STRING:/ {
            oid = $1
            split(oid, oid_parts, ".")
            n = length(oid_parts)
            if (n >= 4) {
                ip_addr = oid_parts[n-3] "." oid_parts[n-2] "." oid_parts[n-1] "." oid_parts[n]
            } else {
                next
            }
            mac_hex_str = $0
            sub(/.*Hex-STRING: /, "", mac_hex_str)
            gsub(/ /, "", mac_hex_str)
            mac_hex_str = tolower(mac_hex_str)
            if (length(mac_hex_str) >= 12) {
                mac_key = substr(mac_hex_str,1,4) "-" substr(mac_hex_str,5,4) "-" substr(mac_hex_str,9,4)
                if (!(mac_key in mac_to_ip)) {
                    mac_to_ip[mac_key] = ip_addr
                }
            }
            next
        }
        FILENAME == ARGV[4] && /INTEGER:/ {
            oid = $1
            split(oid, oid_parts, ".")
            n = length(oid_parts)
            if (n < 8) next
            vlan = oid_parts[n-6]
            mac_bytes[1] = oid_parts[n-5] + 0
            mac_bytes[2] = oid_parts[n-4] + 0
            mac_bytes[3] = oid_parts[n-3] + 0
            mac_bytes[4] = oid_parts[n-2] + 0
            mac_bytes[5] = oid_parts[n-1] + 0
            mac_bytes[6] = oid_parts[n] + 0
            mac_hex = ""
            for (i=1; i<=6; i++) {
                mac_hex = mac_hex sprintf("%02x", mac_bytes[i])
            }
            mac = substr(mac_hex,1,4) "-" substr(mac_hex,5,4) "-" substr(mac_hex,9,4)
            logical_port = $NF
            ifIndex = logical_to_ifindex[logical_port]
            port_name = ifindex_to_name[ifIndex]
            if (port_name == "") port_name = "未知(逻辑端口 " logical_port ")"
            host_ip = (mac in mac_to_ip) ? mac_to_ip[mac] : ""
            print csv(ip), csv(devname), csv(vlan), csv(mac), csv(port_name), csv(host_ip)
            next
        }' "$tmp_if" "$tmp_port" "$tmp_arp" "$tmp_mac_q" > "$tmp_out"
    else
        awk -v ip="$switch_ip" -v devname="$sysname" '
        BEGIN { OFS="," }
        function csv(value) {
            gsub(/"/, "\"\"", value)
            return "\"" value "\""
        }
        FILENAME == ARGV[1] && /STRING:/ {
            split($1, a, ".")
            ifIndex = a[length(a)]
            name = $0
            sub(/.*STRING: "/, "", name)
            sub(/".*/, "", name)
            ifindex_to_name[ifIndex] = name
            next
        }
        FILENAME == ARGV[2] && /INTEGER:/ {
            split($1, a, ".")
            logicalPort = a[length(a)]
            ifIndex = $NF
            logical_to_ifindex[logicalPort] = ifIndex
            next
        }
        FILENAME == ARGV[3] && /Hex-STRING:/ {
            oid = $1
            split(oid, oid_parts, ".")
            n = length(oid_parts)
            if (n >= 4) {
                ip_addr = oid_parts[n-3] "." oid_parts[n-2] "." oid_parts[n-1] "." oid_parts[n]
            } else {
                next
            }
            mac_hex_str = $0
            sub(/.*Hex-STRING: /, "", mac_hex_str)
            gsub(/ /, "", mac_hex_str)
            mac_hex_str = tolower(mac_hex_str)
            if (length(mac_hex_str) >= 12) {
                mac_key = substr(mac_hex_str,1,4) "-" substr(mac_hex_str,5,4) "-" substr(mac_hex_str,9,4)
                if (!(mac_key in mac_to_ip)) {
                    mac_to_ip[mac_key] = ip_addr
                }
            }
            next
        }
        FILENAME == ARGV[4] && /INTEGER:/ {
            oid = $1
            split(oid, oid_parts, ".")
            n = length(oid_parts)
            if (n < 6) next
            mac_bytes[1] = oid_parts[n-5] + 0
            mac_bytes[2] = oid_parts[n-4] + 0
            mac_bytes[3] = oid_parts[n-3] + 0
            mac_bytes[4] = oid_parts[n-2] + 0
            mac_bytes[5] = oid_parts[n-1] + 0
            mac_bytes[6] = oid_parts[n] + 0
            mac_hex = ""
            for (i=1; i<=6; i++) {
                mac_hex = mac_hex sprintf("%02x", mac_bytes[i])
            }
            mac = substr(mac_hex,1,4) "-" substr(mac_hex,5,4) "-" substr(mac_hex,9,4)
            logical_port = $NF
            ifIndex = logical_to_ifindex[logical_port]
            port_name = ifindex_to_name[ifIndex]
            if (port_name == "") port_name = "未知(逻辑端口 " logical_port ")"
            vlan = ""
            host_ip = (mac in mac_to_ip) ? mac_to_ip[mac] : ""
            print csv(ip), csv(devname), csv(vlan), csv(mac), csv(port_name), csv(host_ip)
            next
        }' "$tmp_if" "$tmp_port" "$tmp_arp" "$tmp_mac_b" > "$tmp_out"
    fi

    rm -f "$tmp_if" "$tmp_port" "$tmp_mac_q" "$tmp_mac_b" "$tmp_arp"
    if [[ ! -s "$tmp_out" ]]; then
        rm -f "$tmp_out"
        return 1
    fi
    return 0
}

export -f process_switch
export COMMUNITY SNMP_VERSION TMP_PREFIX

read_ip_list "$IP_LIST_FILE" | xargs -r -I {} -P "$PARALLEL_JOBS" bash -c 'process_switch "$@"' _ {}

{
    printf '\xEF\xBB\xBF'
    echo "设备IP,设备名称,VLAN,MAC,端口,主机IP"
    cat "${TMP_PREFIX}"_* 2>/dev/null | sort -V -k1,1
} > "$FINAL_OUTPUT"

total_records=$(count_csv_records "$FINAL_OUTPUT")
echo "采集完成，共 $total_records 条记录，保存至 $FINAL_OUTPUT"

cleanup
