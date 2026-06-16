#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"

LOCK_DIR="${REFRESH_LOCK_DIR:-/tmp/switch-toolkit-lock}"
LOG_FILE="${REFRESH_LOG_FILE:-/var/log/switch-toolkit-refresh.log}"
DEFAULT_PARALLEL_JOBS="${REFRESH_PARALLEL_JOBS:-6}"

usage() {
    cat <<USAGE
用法: $0 <任务名>

任务名:
  mac-arp        刷新 MAC/ARP 表
  100m-port      刷新低速率端口
  access-vlan    刷新 PVID
  switch-time    刷新交换机时间
  wireless       刷新无线用户表
  icg-users      刷新 ICG 用户策略信息
  find-index     生成按 IP 查询索引
  all            按顺序执行 mac-arp、wireless、find-index
USAGE
}

log() {
    local message="$*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE" >&2
}

set_low_priority() {
    if command -v ionice >/dev/null 2>&1; then
        ionice -c 3 -p "$$" >/dev/null 2>&1 || true
    else
        true
    fi
    renice -n 10 -p "$$" >/dev/null 2>&1 || true
}

run_task_body() {
    local task="$1"
    export PARALLEL_JOBS="${PARALLEL_JOBS:-$DEFAULT_PARALLEL_JOBS}"

    case "$task" in
        mac-arp)
            "$SCRIPT_DIR/flash_mac_arp.sh"
            ;;
        100m-port)
            "$SCRIPT_DIR/flash_100M_port.sh"
            ;;
        access-vlan)
            "$SCRIPT_DIR/flash_access_vlan.sh"
            ;;
        switch-time)
            "$SCRIPT_DIR/flash_switch_time.sh"
            ;;
        wireless)
            "$SCRIPT_DIR/collect_ac6508_users.sh" -p "${WIRELESS_PARALLEL_JOBS:-2}"
            ;;
        icg-users)
            "$SCRIPT_DIR/collect_icg_users.py"
            ;;
        find-index)
            "$SCRIPT_DIR/csv_to_ip.py"
            ;;
        all)
            run_task_body mac-arp
            run_task_body wireless
            run_task_body find-index
            ;;
        -h|--help|"")
            usage
            ;;
        *)
            usage >&2
            die "未知任务名: $task"
            ;;
    esac
}

main() {
    local task="${1:-}"
    case "$task" in
        -h|--help)
            usage
            exit 0
            ;;
        "")
            usage >&2
            exit 2
            ;;
    esac

    mkdir -p "$LOCK_DIR" || die "无法创建锁目录: $LOCK_DIR"

    local global_lock="$LOCK_DIR/refresh.lock"
    local task_lock="$LOCK_DIR/${task//[^A-Za-z0-9_.-]/_}.lock"

    exec 9>"$global_lock" || die "无法打开全局锁: $global_lock"
    if ! flock -n 9; then
        log "[跳过] 已有刷新任务在执行，本次任务不启动: $task"
        exit 0
    fi

    exec 8>"$task_lock" || die "无法打开任务锁: $task_lock"
    if ! flock -n 8; then
        log "[跳过] 同类刷新任务正在执行，本次任务不启动: $task"
        exit 0
    fi

    log "[开始] $task, PARALLEL_JOBS=${PARALLEL_JOBS:-$DEFAULT_PARALLEL_JOBS}"
    set_low_priority
    run_task_body "$task"
    local status=$?
    if [[ $status -eq 0 ]]; then
        log "[完成] $task"
    else
        log "[失败] $task, exit=$status"
    fi
    return "$status"
}

main "$@"
