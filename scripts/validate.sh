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

# 确保绝对路径
if [[ "$PROFILE_JSON" != /* ]]; then
  PROFILE_JSON="$PWD/$PROFILE_JSON"
fi

TARGET_PROFILE=$(jq -r '.profile' "$PROFILE_JSON")
ALL_ADD_PKGS=$(jq -r '.packages.add | join(" ")' "$PROFILE_JSON")
REMOVE_PKGS=$(jq -r '.packages.remove | map("-" + .) | join(" ")' "$PROFILE_JSON")

# 排除 custom_apks 包名——它们是本地 APK，不在远程 feed 中
CUSTOM_NAMES=$(jq -r '.custom_apks // [] | .[].name' "$PROFILE_JSON" 2>/dev/null || true)
ADD_PKGS=""
for pkg in $ALL_ADD_PKGS; do
  skip=false
  for cname in $CUSTOM_NAMES; do
    [ "$pkg" = "$cname" ] && skip=true && break
  done
  $skip || ADD_PKGS="$ADD_PKGS $pkg"
done
ADD_PKGS="${ADD_PKGS# }"
PACKAGES="$ADD_PKGS $REMOVE_PKGS"

log_section "Preflight 依赖求解预检"
log_info "目标设备: $TARGET_PROFILE"
log_info "待安装（feed）: $ADD_PKGS"
log_info "待移除: $REMOVE_PKGS"

cd "$IB_DIR"

# 用 ImageBuilder 自带的 make manifest 做依赖预检
if ! make manifest PROFILE="$TARGET_PROFILE" PACKAGES="$PACKAGES"; then
  log_error "依赖求解失败！请修正包列表后重试。"
  cat >&2 <<'EOF'

=== 故障诊断 ===
依赖求解无法通过的常见原因：
1. 远程 Feed 与当前 ImageBuilder 版本不一致（snapshot 构建常见）
2. kmod-* 内核模块在当前内核版本中不存在
3. 第三方 APK 依赖的包未被 feed 覆盖
4. 包名拼写错误或已更名
================
EOF
  exit 1
fi

log_info "Preflight 预检通过！"
log_end
