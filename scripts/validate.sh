#!/usr/bin/env bash
# Preflight 依赖求解预检
# 用法: ./scripts/validate.sh <profile.json> <ib_dir> <sandbox_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PROFILE_JSON="${1:-}"
IB_DIR="${2:-}"
SANDBOX_DIR="${3:-}"

if [ -z "$PROFILE_JSON" ] || [ -z "$IB_DIR" ]; then
  log_error "用法: validate.sh <profile.json> <ib_dir> [sandbox_dir]"
  exit 1
fi

SANDBOX_DIR="${SANDBOX_DIR:-$PWD/work/sandbox}"

TARGET_PROFILE=$(jq -r '.profile' "$PROFILE_JSON")
ADD_PKGS=$(jq -r '.packages.add | join(" ")' "$PROFILE_JSON")
REMOVE_PKGS=$(jq -r '.packages.remove | map("-" + .) | join(" ")' "$PROFILE_JSON")

log_section "Preflight 依赖求解预检"
log_info "目标设备: $TARGET_PROFILE"
log_info "待安装: $ADD_PKGS"
log_info "待移除: $REMOVE_PKGS"

cd "$IB_DIR"

# 构建临时沙盒
rm -rf "$SANDBOX_DIR"
mkdir -p "$SANDBOX_DIR/var/lib/apk" "$SANDBOX_DIR/etc/apk"
cp -r keys "$SANDBOX_DIR/etc/apk/keys"
cp repositories.conf "$SANDBOX_DIR/etc/apk/repositories"

# 将本地包路径追加到沙盒的 repositories
if [ -d "packages" ] && ls packages/*.apk >/dev/null 2>&1; then
  echo "file://$IB_DIR/packages" >> "$SANDBOX_DIR/etc/apk/repositories"
fi

# 更新索引
if ! ./staging_dir/host/bin/apk --root "$SANDBOX_DIR" --keys-dir "$SANDBOX_DIR/etc/apk/keys" update >/dev/null 2>&1; then
  log_error "上游/本地软件源索引同步失败，请检查网络或 ImageBuilder URL。"
  exit 1
fi

# Dry-run 依赖求解（--allow-untrusted 支持未签名的第三方包）
log_info "正在模拟依赖求解..."
if ./staging_dir/host/bin/apk --root "$SANDBOX_DIR" --keys-dir "$SANDBOX_DIR/etc/apk/keys" \
  add --allow-untrusted --dry-run $ADD_PKGS $REMOVE_PKGS >/dev/null 2>&1; then
  log_info "Preflight 预检通过！依赖链完整，无冲突。"
else
  log_error "依赖求解失败！以下是详细错误:"
  ./staging_dir/host/bin/apk --root "$SANDBOX_DIR" --keys-dir "$SANDBOX_DIR/etc/apk/keys" \
    add --allow-untrusted --dry-run $ADD_PKGS $REMOVE_PKGS 2>&1 || true
  log_error "请修正配置文件中的包名或依赖后重试。"
  exit 1
fi

log_end
