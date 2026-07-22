#!/usr/bin/env bash
# 用法: ./scripts/discover.sh config/profiles/friendlyarm_nanopi-r2s.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_JSON="${1:-}"

if [ -z "$PROFILE_JSON" ] || [ ! -f "$PROFILE_JSON" ]; then
  echo "Error: 请提供有效的 Profile 配置文件路径。" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/discover.py" "$PROFILE_JSON"
