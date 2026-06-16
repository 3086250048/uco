#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"

CONFIG="${1:-$ROOT_DIR/config/areas.tsv}"
ensure_file "$CONFIG"

while IFS=$'\t' read -r area switch_file; do
    [[ -z "${area:-}" || "${area:0:1}" == "#" ]] && continue
    "$SCRIPT_DIR/collect_mac_arp.sh" \
        -i "$ROOT_DIR/config/switches/$switch_file" \
        -o "/srv/smb/mac_table/$area" \
        -p "${PARALLEL_JOBS:-20}"
done < "$CONFIG"
