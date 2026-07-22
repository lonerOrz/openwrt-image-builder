#!/usr/bin/env bash
# 用法: ./scripts/discover.sh config/profiles/friendlyarm_nanopi-r2s.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"

PROFILE_JSON="${1:-}"
if [ -z "$PROFILE_JSON" ] || [ ! -f "$PROFILE_JSON" ]; then
  log_error "请提供有效的 Profile 配置文件，例如: ./scripts/discover.sh config/profiles/friendlyarm_nanopi-r2s.json"
  exit 1
fi

WORK_DIR="$PWD/work"
mkdir -p "$WORK_DIR"

log_section "引导环境初始化"
IB_DIR=$(bootstrap_imagebuilder "$PROFILE_JSON" "$WORK_DIR")
log_end

TARGET_PROFILE=$(jq -r '.profile' "$PROFILE_JSON")

log_section "设备 [$TARGET_PROFILE] 默认集成的基础包列表"
cd "$IB_DIR"

# 通过 make manifest 获取默认打包到 ROM 里的基础包
DEFAULT_PACKAGES=$(make manifest PROFILE="$TARGET_PROFILE" 2>/dev/null | grep -v "^Manifest" | tr ' ' '\n' | sort -u || true)

COUNT=$(echo "$DEFAULT_PACKAGES" | grep -c . || true)
echo ""
echo "设备 [$TARGET_PROFILE] 默认集成的基础包列表 (共 $COUNT 个):"
echo "--------------------------------------------------------"
echo "$DEFAULT_PACKAGES" | sed 's/^/  - /'
echo ""
echo "提示: 您可以根据上述列表，将不需要的包写进配置文件中的 \"packages.remove\" 数组内。"
log_end

log_section "当前配置的包列表"
ADD_PKGS=$(jq -r '.packages.add | join(", ")' "$PROFILE_JSON")
REMOVE_PKGS=$(jq -r '.packages.remove | join(", ")' "$PROFILE_JSON")
echo ""
echo "将安装: $ADD_PKGS"
echo "将移除: $REMOVE_PKGS"
log_end
