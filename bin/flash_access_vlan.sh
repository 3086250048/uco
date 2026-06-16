#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"

CONFIG="${1:-$ROOT_DIR/config/pvid_switches.tsv}"
ensure_file "$CONFIG"

while IFS=$'\t' read -r _floor switch_file; do
    [[ -z "${switch_file:-}" || "${_floor:0:1}" == "#" ]] && continue
    "$SCRIPT_DIR/get_access_vlan.sh" \
        -i "$ROOT_DIR/config/switches/$switch_file" \
        -o "/srv/smb/PVID" \
        -p "${PARALLEL_JOBS:-20}"
done < "$CONFIG"
