#!/usr/bin/env bash

set -o pipefail

project_root() {
    local source="${BASH_SOURCE[0]}"
    local dir
    dir="$(cd "$(dirname "$source")/.." && pwd)"
    printf '%s\n' "$dir"
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

ensure_file() {
    [[ -f "$1" ]] || die "文件不存在: $1"
}

ensure_dir() {
    mkdir -p "$1" || die "无法创建目录: $1"
}

csv_escape() {
    local value="${1-}"
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//\"/\"\"}
    printf '"%s"' "$value"
}

read_ip_list() {
    local file="$1"
    ensure_file "$file"
    awk '
        {
            sub(/\r$/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 != "") print
        }
    ' "$file"
}

run_parallel_ips() {
    local ip_file="$1"
    local jobs="$2"
    local worker="$3"

    read_ip_list "$ip_file" |
        xargs -r -I {} -P "$jobs" bash -c '"$1" "$2"' _ "$worker" {}
}

with_csv_header() {
    local output="$1"
    local header="$2"
    shift 2
    {
        printf '\xEF\xBB\xBF'
        printf '%s\n' "$header"
        "$@"
    } > "$output"
}

count_csv_records() {
    local file="$1"
    tail -n +2 "$file" 2>/dev/null | wc -l
}

script_dir() {
    local source="${BASH_SOURCE[1]}"
    cd "$(dirname "$source")" && pwd
}
