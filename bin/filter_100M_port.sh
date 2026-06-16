#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
# ============================================================
# 脚本名称: filter_100M_port.sh
# 功能: 并行获取多台交换机所有端口速率，筛选 1000M 以下的端口
# 新增: 仅记录端口状态为 UP 且速率 >0、非 vlanif 接口的端口
# 输出字段: 设备名称, 设备IP, 端口, 速率(Mbps)
# 依赖: snmpbulkwalk, snmpget (net-snmp-utils), awk
# ============================================================

COMMUNITY="ucoswitch"
SNMP_VERSION="2c"
OUTPUT_DIR="./"
PARALLEL_JOBS=10
IP_LIST_FILE=""

# 解析参数
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
FINAL_OUTPUT="${OUTPUT_DIR}/低速率端口_${TIMESTAMP}.csv"
TMP_PREFIX="${OUTPUT_DIR}/.low_speed_tmp_$$"

cleanup() {
    rm -f "${TMP_PREFIX}"_* 2>/dev/null
}
trap cleanup EXIT

echo "开始采集（仅端口UP且速率<1000M，排除速率0和vlan接口），临时文件前缀: ${TMP_PREFIX}_ ，最终输出: $FINAL_OUTPUT"

process_switch() {
    local switch_ip="$1"
    local tmp_ifdescr=$(mktemp) || return 1
    local tmp_ifspeed=$(mktemp) || return 1
    local tmp_ifoper=$(mktemp) || return 1
    local tmp_sysname=$(mktemp) || return 1
    local tmp_out="${TMP_PREFIX}_${switch_ip//./_}"

    # 并行获取 ifDescr, ifSpeed, ifOperStatus 以及 sysName
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.2.2.1.2" > "$tmp_ifdescr" 2>/dev/null &
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.2.2.1.5" > "$tmp_ifspeed" 2>/dev/null &
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.2.2.1.8" > "$tmp_ifoper" 2>/dev/null &
    snmpget -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.1.5.0" > "$tmp_sysname" 2>/dev/null &
    wait

    # 检查四个文件是否都非空
    if [[ ! -s "$tmp_ifdescr" || ! -s "$tmp_ifspeed" || ! -s "$tmp_ifoper" || ! -s "$tmp_sysname" ]]; then
        rm -f "$tmp_ifdescr" "$tmp_ifspeed" "$tmp_ifoper" "$tmp_sysname"
        return 1
    fi

    # 提取设备名称（sysName），若失败则设为 unknown
    local sysname=$(awk -F '"' '/STRING/ {print $2; exit}' "$tmp_sysname")
    if [[ -z "$sysname" ]]; then
        sysname="unknown"
    fi

    # 使用 awk 关联三张表，条件：
    #   速率 < 1Gbps 且 操作状态为 up(1) 且 速率 > 0 且 端口名不包含 vlan (忽略大小写)
    awk -v ip="$switch_ip" -v name="$sysname" '
    BEGIN { OFS="," }
    function csv(value) {
        gsub(/"/, "\"\"", value)
        return "\"" value "\""
    }
    # 辅助函数：从 INTEGER 行中提取数字，例如将 "up(1)" 转换为 1
    function extract_number(str) {
        gsub(/.*\(|\)/, "", str)
        return str + 0
    }

    # 文件1: ifDescr -> 映射 ifIndex 到端口名
    FILENAME == ARGV[1] && /STRING:/ {
        split($1, a, ".")
        idx = a[length(a)]
        name_field = $0
        sub(/.*STRING: "/, "", name_field)
        sub(/".*/, "", name_field)
        ifdesc[idx] = name_field
        next
    }

    # 文件2: ifSpeed -> 匹配任何包含等号的行，适应 Gauge32, INTEGER 等类型
    FILENAME == ARGV[2] && /=/ {
        split($1, a, ".")
        idx = a[length(a)]
        speed_bps = $NF
        speed_mbps = int(speed_bps / 1000000)
        speeds[idx] = speed_mbps
        next
    }

    # 文件3: ifOperStatus -> 检查状态为 up(1) 且速率满足条件，输出
    FILENAME == ARGV[3] && /INTEGER:/ {
        split($1, a, ".")
        idx = a[length(a)]
        oper_raw = $NF
        oper = extract_number(oper_raw)
        # 增加过滤：速率 > 0 且 端口名不包含 vlan (忽略大小写)
        if (ifdesc[idx] != "" && speeds[idx] != "" && oper == 1 && speeds[idx] < 1000 && speeds[idx] > 0 && ifdesc[idx] !~ /[Vv]lan/) {
            print csv(name), csv(ip), csv(ifdesc[idx]), csv(speeds[idx])
        }
        next
    }' "$tmp_ifdescr" "$tmp_ifspeed" "$tmp_ifoper" > "$tmp_out"

    rm -f "$tmp_ifdescr" "$tmp_ifspeed" "$tmp_ifoper" "$tmp_sysname"
    if [[ ! -s "$tmp_out" ]]; then
        rm -f "$tmp_out"
        return 1
    fi
    return 0
}

export -f process_switch
export COMMUNITY SNMP_VERSION TMP_PREFIX

read_ip_list "$IP_LIST_FILE" | xargs -r -I {} -P "$PARALLEL_JOBS" bash -c 'process_switch "$@"' _ {}

# 合并所有临时文件，加上 CSV 表头
{
    printf '\xEF\xBB\xBF'
    echo "设备名称,设备IP,端口,速率(Mbps)"
    cat "${TMP_PREFIX}"_* 2>/dev/null | sort -V -k2,2
} > "$FINAL_OUTPUT"

total_records=$(count_csv_records "$FINAL_OUTPUT")
echo "采集完成，共 $total_records 条记录（UP且低速率端口，已排除速率0和vlan接口），保存至 $FINAL_OUTPUT"

cleanup
