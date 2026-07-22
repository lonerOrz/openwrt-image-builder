#!/usr/bin/env bash
# Preflight 依赖求解预检
# 用法: ./scripts/validate.sh <profile.json> <ib_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PROFILE_JSON="${1:-}"
IB_DIR="${2:-}"

if [ -z "$PROFILE_JSON" ] || [ -z "$IB_DIR" ]; then
  log_error "用法: validate.sh <profile.json> <ib_dir>"
  exit 1
fi

TARGET_PROFILE=$(jq -r '.profile' "$PROFILE_JSON")
ADD_PKGS=$(jq -r '.packages.add | join(" ")' "$PROFILE_JSON")
REMOVE_PKGS=$(jq -r '.packages.remove | map("-" + .) | join(" ")' "$PROFILE_JSON")
PACKAGES="$ADD_PKGS $REMOVE_PKGS"

log_section "Preflight 依赖求解预检"
log_info "目标设备: $TARGET_PROFILE"
log_info "待安装: $ADD_PKGS"
log_info "待移除: $REMOVE_PKGS"

cd "$IB_DIR"

# 用 ImageBuilder 自带的 make manifest 做依赖预检
if ! make manifest PROFILE="$TARGET_PROFILE" PACKAGES="$PACKAGES"; then
  log_error "依赖求解失败！请修正包列表后重试。"
  exit 1
fi

log_info "Preflight 预检通过！"
log_end
