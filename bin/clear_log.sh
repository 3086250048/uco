#!/usr/bin/env bash
set -uo pipefail

# 基础目录
BASE_DIR="${BASE_DIR:-/srv/smb/mac_table}"

# 需要清理的子目录列表
DIRS=("GZ" "HN" "JS" "KS" "MLK" "UCO" "YZ")

# 保留天数
DAYS="${DAYS:-30}"

# 日志文件（记录清理操作）
LOG_FILE="${LOG_FILE:-/var/log/switch-toolkit-cleanup.log}"

# 记录开始时间
echo "$(date): 开始批量清理日志文件" >> "$LOG_FILE"

# 遍历每个子目录
for dir in "${DIRS[@]}"; do
    TARGET="${BASE_DIR}/${dir}"
    if [[ -d "$TARGET" ]]; then
        echo "清理目录: $TARGET" >> "$LOG_FILE"
        # 查找并删除超过 DAYS 天的文件
        find "$TARGET" -type f -mtime "+${DAYS}" -delete
        # 可选：同时删除空目录（如果需要）
        # find "$TARGET" -type d -empty -delete
    else
        echo "警告: 目录 $TARGET 不存在，跳过" >> "$LOG_FILE"
    fi
done

echo "$(date): 批量清理完成" >> "$LOG_FILE"
