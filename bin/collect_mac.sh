#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
# ============================================================
# 脚本名称: collect_mac_fixed.sh
# 功能: 并行获取多台交换机的MAC地址表，输出CSV（无行交错）
# 使用: ./collect_mac_fixed.sh -i ip_list.txt [-o output_dir] [-p 10]
# 依赖: snmpbulkwalk (net-snmp-utils), awk (mawk/gawk均可)
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
FINAL_OUTPUT="${OUTPUT_DIR}/${TIMESTAMP}_mac.csv"
TMP_PREFIX="${OUTPUT_DIR}/.mac_tmp_$$"

# 清理临时文件的函数
cleanup() {
    rm -f "${TMP_PREFIX}"_* 2>/dev/null
}
trap cleanup EXIT

echo "开始采集，临时文件前缀: ${TMP_PREFIX}_ ，最终输出: $FINAL_OUTPUT"

# ---------- 处理单台交换机 ----------
process_switch() {
    local switch_ip="$1"
    local tmp_if=$(mktemp) || return 1
    local tmp_port=$(mktemp) || return 1
    local tmp_mac=$(mktemp) || return 1
    local tmp_out="${TMP_PREFIX}_${switch_ip//./_}"   # 避免IP中的点影响文件名

    # 并行获取三张表 (snmpbulkwalk 更快)
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.2.2.1.2" > "$tmp_if" 2>/dev/null &
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.17.1.4.1.2" > "$tmp_port" 2>/dev/null &
    snmpbulkwalk -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "1.3.6.1.2.1.17.7.1.2.2.1.2" > "$tmp_mac" 2>/dev/null &
    wait

    # 检查文件有效性（非空）
    if [[ ! -s "$tmp_if" || ! -s "$tmp_port" || ! -s "$tmp_mac" ]]; then
        rm -f "$tmp_if" "$tmp_port" "$tmp_mac"
        return 1
    fi

    # 使用 awk 完成所有映射和输出（兼容 mawk 和 gawk）
    awk -v ip="$switch_ip" '
    BEGIN { OFS="," }
    function csv(value) {
        gsub(/"/, "\"\"", value)
        return "\"" value "\""
    }
    # 读取 ifDescr 文件：构建 ifIndex -> 接口名 映射
    FILENAME == ARGV[1] && /STRING:/ {
        # 提取 ifIndex（OID 最后一个点后的数字）
        split($1, a, ".")
        ifIndex = a[length(a)]
        # 提取接口名（双引号内的内容）
        name = $0
        sub(/.*STRING: "/, "", name)
        sub(/".*/, "", name)
        ifindex_to_name[ifIndex] = name
        next
    }
    # 读取 dot1dBasePortIfIndex 文件：构建逻辑端口 -> ifIndex 映射
    FILENAME == ARGV[2] && /INTEGER:/ {
        split($1, a, ".")
        logicalPort = a[length(a)]          # 最后一个点后的数字
        ifIndex = $NF                       # 行末数字
        logical_to_ifindex[logicalPort] = ifIndex
        next
    }
    # 读取 dot1qTpFdbPort 文件：输出最终记录
    FILENAME == ARGV[3] && /INTEGER:/ {
        # 解析 OID 后缀：格式为 .VLAN.MAC1.MAC2.MAC3.MAC4.MAC5.MAC6
        # OID 完整形式: 1.3.6.1.2.1.17.7.1.2.2.1.2.VLAN.MAC1...MAC6
        split($1, oid_parts, ".")
        n = length(oid_parts)
        if (n >= 20) {   # 确保有足够字段
            vlan = oid_parts[n-6]
            # MAC 的6个十进制字节
            mac_bytes[1]=oid_parts[n-5]; mac_bytes[2]=oid_parts[n-4]
            mac_bytes[3]=oid_parts[n-3]; mac_bytes[4]=oid_parts[n-2]
            mac_bytes[5]=oid_parts[n-1]; mac_bytes[6]=oid_parts[n]
            # 转十六进制小写，格式 xxxx-xxxx-xxxx
            mac_hex = sprintf("%02x%02x%02x%02x%02x%02x",
                              mac_bytes[1], mac_bytes[2], mac_bytes[3],
                              mac_bytes[4], mac_bytes[5], mac_bytes[6])
            mac = substr(mac_hex,1,4) "-" substr(mac_hex,5,4) "-" substr(mac_hex,9,4)
            logical_port = $NF
            ifIndex = logical_to_ifindex[logical_port]
            port_name = ifindex_to_name[ifIndex]
            if (port_name == "") port_name = "未知(逻辑端口 " logical_port ")"
            print csv(ip), csv(vlan), csv(mac), csv(port_name)
        }
        next
    }' "$tmp_if" "$tmp_port" "$tmp_mac" > "$tmp_out"

    rm -f "$tmp_if" "$tmp_port" "$tmp_mac"
    
    # 如果临时输出文件为空，删除它（表示该交换机无有效数据）
    if [[ ! -s "$tmp_out" ]]; then
        rm -f "$tmp_out"
        return 1
    fi
    return 0
}

export -f process_switch
export COMMUNITY SNMP_VERSION TMP_PREFIX

# 并行执行所有交换机（每个进程输出到独立临时文件）
read_ip_list "$IP_LIST_FILE" | xargs -r -I {} -P "$PARALLEL_JOBS" bash -c 'process_switch "$@"' _ {}

# 合并所有临时文件到最终输出文件（可选添加表头）
{
    printf '\xEF\xBB\xBF'
    echo "IP,VLAN,MAC,Port"   # CSV 表头
    cat "${TMP_PREFIX}"_* 2>/dev/null | sort -V   # 按IP排序，提高可读性
} > "$FINAL_OUTPUT"

# 统计有效记录数（不含表头）
total_records=$(count_csv_records "$FINAL_OUTPUT")
echo "采集完成，共 $total_records 条记录，保存至 $FINAL_OUTPUT"

# 清理临时文件（trap 已保证，但可显式再清一次）
cleanup
