#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"

COMMUNITY="ucoswitch"
SNMP_VERSION="2c"
OUTPUT_DIR="./"
PARALLEL_JOBS=10
IP_LIST_FILE=""

SYSNAME_OID="1.3.6.1.2.1.1.5"
H3C_TIME_OID="1.3.6.1.4.1.25506.2.3.1.1.1"
STD_TIME_OID="1.3.6.1.2.1.25.1.2"
UPTIME_OID="1.3.6.1.2.1.1.3"

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
FINAL_OUTPUT="${OUTPUT_DIR}/${TIMESTAMP}_switch_time.csv"
TMP_PREFIX="${OUTPUT_DIR}/.switch_time_tmp_$$"

cleanup() {
    rm -f "${TMP_PREFIX}"_* 2>/dev/null
}
trap cleanup EXIT

csv_escape() {
    local value="$1"
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//\"/\"\"}
    printf '"%s"' "$value"
}

parse_hex_time() {
    local input="$1"
    local hex

    hex=$(echo "$input" | sed 's/.*Hex-STRING: //g' | tr -d '"')
    hex=$(echo "$hex" | grep -Eo '([0-9A-Fa-f]{2} ?)+' | head -n 1)

    [[ -z "$hex" ]] && echo "" && return

    read -ra a <<< "$hex"

    [[ ${#a[@]} -lt 8 ]] && echo "" && return

    for b in "${a[@]}"; do
        if ! [[ "$b" =~ ^[0-9A-Fa-f]{2}$ ]]; then
            echo ""
            return
        fi
    done

    local year=$((16#${a[0]} * 256 + 16#${a[1]}))
    local month=$((16#${a[2]}))
    local day=$((16#${a[3]}))
    local hour=$((16#${a[4]}))
    local min=$((16#${a[5]}))
    local sec=$((16#${a[6]}))
    local centi=$((16#${a[7]}))

    local tz=""
    if [[ ${#a[@]} -ge 11 ]]; then
        local sign="${a[8]}"
        local tzh=$((16#${a[9]}))
        local tzm=$((16#${a[10]}))

        if [[ "$sign" == "2B" ]]; then
            tz="+$(printf "%02d:%02d" "$tzh" "$tzm")"
        elif [[ "$sign" == "2D" ]]; then
            tz="-$(printf "%02d:%02d" "$tzh" "$tzm")"
        fi
    fi

    printf "%04d-%02d-%02d %02d:%02d:%02d.%02d %s" \
        "$year" "$month" "$day" "$hour" "$min" "$sec" "$centi" "$tz"
}

get_first_value() {
    awk -F'= ' 'NF >= 2 {print $2; exit}'
}

process_switch() {
    local switch_ip="$1"
    local tmp_out="${TMP_PREFIX}_${switch_ip//./_}"

    local name_raw h3c_raw std_raw uptime_raw
    local name sys_time uptime

    name_raw=$(snmpbulkwalk -t 2 -r 1 -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "$SYSNAME_OID" 2>/dev/null)
    name=$(echo "$name_raw" | get_first_value | sed 's/^STRING: //; s/"//g')
    [[ -z "$name" ]] && name="获取失败"

    h3c_raw=$(snmpbulkwalk -t 2 -r 1 -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "$H3C_TIME_OID" 2>/dev/null)
    sys_time=$(parse_hex_time "$h3c_raw")

    if [[ -z "$sys_time" ]]; then
        std_raw=$(snmpbulkwalk -t 2 -r 1 -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "$STD_TIME_OID" 2>/dev/null)
        sys_time=$(parse_hex_time "$std_raw")
    fi

    [[ -z "$sys_time" ]] && sys_time="获取失败"

    uptime_raw=$(snmpbulkwalk -t 2 -r 1 -v "$SNMP_VERSION" -c "$COMMUNITY" "$switch_ip" "$UPTIME_OID" 2>/dev/null)
    uptime=$(echo "$uptime_raw" | get_first_value | sed 's/^Timeticks: //')
    [[ -z "$uptime" ]] && uptime="获取失败"

    {
        csv_escape "$name"
        printf ','
        csv_escape "$switch_ip"
        printf ','
        csv_escape "$sys_time"
        printf ','
        csv_escape "$uptime"
        printf '\n'
    } > "$tmp_out"
}

export -f process_switch
export -f parse_hex_time
export -f get_first_value
export -f csv_escape
export COMMUNITY SNMP_VERSION TMP_PREFIX
export SYSNAME_OID H3C_TIME_OID STD_TIME_OID UPTIME_OID

read_ip_list "$IP_LIST_FILE" | xargs -r -I {} -P "$PARALLEL_JOBS" bash -c 'process_switch "$@"' _ {}

{
    printf '\xEF\xBB\xBF'
    echo "交换机名称,设备IP,系统时间,运行时间"
    cat "${TMP_PREFIX}"_* 2>/dev/null | sort -V -t, -k2,2
} > "$FINAL_OUTPUT"

total=$(count_csv_records "$FINAL_OUTPUT")

echo "采集完成，共 $total 台设备，保存至 $FINAL_OUTPUT"
