#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
# ============================================================
# 脚本名称: collect_pvid_with_sysname.sh
# 功能: 采集交换机端口PVID，并输出设备名称（sysName）
# 输出字段: 设备IP, 设备名称, 端口名称, PVID
# 依赖: snmpbulkwalk, snmpget, awk, join
# ============================================================

COMMUNITY="ucoswitch"
SNMP_VERSION="2c"
OUTPUT_DIR="./"
PARALLEL_JOBS=5
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
# 获取 -i 参数的文件名（不含路径）
BASENAME=$(basename "$IP_LIST_FILE")
# 输出文件名：时间戳_文件名_pvid.csv
FINAL_OUTPUT="${OUTPUT_DIR}/${TIMESTAMP}_${BASENAME}_pvid.csv"
TMP_PREFIX="${OUTPUT_DIR}/.pvid_tmp_$$"

cleanup() {
    rm -f "${TMP_PREFIX}"_* 2>/dev/null
}
trap cleanup EXIT

echo "开始采集（含设备名称），输出文件: $FINAL_OUTPUT"

process_switch() {
    local ip="$1"
    local tmp_if="${TMP_PREFIX}_${ip//./_}_if"
    local tmp_pvid="${TMP_PREFIX}_${ip//./_}_pvid"
    local tmp_out="${TMP_PREFIX}_${ip//./_}_out"

    # 0. 获取设备名称 (sysName)
    local sysname=""
    sysname=$(snmpget -v "$SNMP_VERSION" -c "$COMMUNITY" -Oqv "$ip" 1.3.6.1.2.1.1.5.0 2>/dev/null | tr -d '"')
    if [[ -z "$sysname" ]]; then
        sysname="$ip"
        echo "  注意: $ip 无法获取 sysName，使用 IP 作为设备名称" >&2
    fi

    # 1. 获取 ifIndex -> ifDescr 映射
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$ip" 1.3.6.1.2.1.2.2.1.2 > "$tmp_if" 2>/dev/null
    if [[ ! -s "$tmp_if" ]]; then
        echo "  警告: $ip 无法获取接口列表" >&2
        return 1
    fi

    # 2. 获取 PVID
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$ip" 1.3.6.1.2.1.17.7.1.4.5.1.1 > "$tmp_pvid" 2>/dev/null
    if [[ ! -s "$tmp_pvid" ]]; then
        echo "  警告: $ip 无法获取 PVID 表" >&2
        return 1
    fi

    # 3. 解析 ifDescr
    awk '/STRING:/ {
        split($1, a, ".")
        idx = a[length(a)]
        name = $0
        sub(/.*STRING: "/, "", name)
        sub(/".*/, "", name)
        print idx, name
    }' "$tmp_if" | sort -n > "${tmp_out}_ifindex.txt"

    # 4. 解析 PVID（兼容 Gauge32/INTEGER 等）
    awk '/(INTEGER|Gauge32|Counter32|Unsigned32):/ {
        split($1, a, ".")
        idx = a[length(a)]
        pvid = $NF
        if (pvid ~ /[0-9]+/) {
            gsub(/[^0-9]/, "", pvid)
        }
        print idx, pvid
    }' "$tmp_pvid" | sort -n > "${tmp_out}_pvid.txt"

    # 5. 合并并添加设备名称列
    join -j 1 "${tmp_out}_ifindex.txt" "${tmp_out}_pvid.txt" | \
        awk -v ip="$ip" -v devname="$sysname" '
        BEGIN { OFS="," }
        function csv(value) {
            gsub(/"/, "\"\"", value)
            return "\"" value "\""
        }
        {
            pvid = $NF
            port = $0
            sub(/^[^[:space:]]+[[:space:]]+/, "", port)
            sub(/[[:space:]][^[:space:]]+$/, "", port)
            print csv(ip), csv(devname), csv(port), csv(pvid)
        }' > "$tmp_out"

    rm -f "${tmp_out}_ifindex.txt" "${tmp_out}_pvid.txt" "$tmp_if" "$tmp_pvid"

    if [[ ! -s "$tmp_out" ]]; then
        echo "  警告: $ip 合并后无输出" >&2
        rm -f "$tmp_out"
        return 1
    fi

    echo "  完成: $ip ($(wc -l < "$tmp_out") 个端口)" >&2
    return 0
}

export -f process_switch
export COMMUNITY SNMP_VERSION TMP_PREFIX

read_ip_list "$IP_LIST_FILE" | xargs -r -I {} -P "$PARALLEL_JOBS" bash -c 'process_switch "$@"' _ {}

# 汇总输出，头部增加设备名称列
{
    printf '\xEF\xBB\xBF'
    echo "设备IP,设备名称,端口名称,PVID"
    cat "${TMP_PREFIX}"_*_out 2>/dev/null | sort -V -k1,1
} > "$FINAL_OUTPUT"

total_records=$(count_csv_records "$FINAL_OUTPUT")
echo "采集完成，共 $total_records 条记录，保存至 $FINAL_OUTPUT"

cleanup
