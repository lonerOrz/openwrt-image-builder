#!/usr/bin/env bash
# 主构建入口: 串联 schema 验证 → bootstrap → 第三方包处理 → 预检 → 构建
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/package_manager.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"

PROFILE_JSON="${1:-}"
SCHEMA_JSON="${SCRIPT_DIR}/../config/schema.json"
WORK_DIR="${WORK_DIR:-$PWD/work}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"

if [ -z "$PROFILE_JSON" ] || [ ! -f "$PROFILE_JSON" ]; then
  log_error "请指定配置文件，如: ./scripts/build.sh config/profiles/friendlyarm_nanopi-r2s.json"
  exit 1
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"
BUILD_START=$(date +%s)

# ============================================
# 步骤 1: JSON Schema 静态验证
# ============================================
log_section "步骤 1/6: 配置文件验证"
if ! python3 "$SCRIPT_DIR/lib/validator.py" "$SCHEMA_JSON" "$PROFILE_JSON"; then
  log_error "JSON 结构校验失败，请检查配置是否符合 schema.json 规范。"
  exit 1
fi
log_end

# ============================================
# 步骤 2: 引导运行环境
# ============================================
log_section "步骤 2/6: 下载并解压 ImageBuilder"
IB_DIR=$(bootstrap_imagebuilder "$PROFILE_JSON" "$WORK_DIR")
log_end

# ============================================
# 步骤 3: 处理第三方 APK
# ============================================
log_section "步骤 3/6: 处理第三方 APK"
process_custom_apks "$IB_DIR" "$PROFILE_JSON"
log_end

# ============================================
# 步骤 4: Preflight 依赖求解预检
# ============================================
if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then
  log_section "步骤 4/6: Preflight 依赖预检"
  if ! "$SCRIPT_DIR/validate.sh" "$PROFILE_JSON" "$IB_DIR"; then
    log_error "静态依赖推导未通过！请修正包列表后重试。"
    exit 1
  fi
  log_end
else
  log_info "跳过 Preflight 预检（PREFLIGHT=$PREFLIGHT）。"
fi

# ============================================
# 步骤 5: 注入自定义系统配置文件
# ============================================
log_section "步骤 5/6: 注入自定义系统配置文件"
rm -rf "$IB_DIR/files"
if [ -d "files" ]; then
  cp -a files "$IB_DIR/files"
fi

# 合并设备专属 overlay（如果有）
PROFILE_DIR="${PROFILE_DIR:-$(dirname "$PROFILE_JSON")}"
DEVICE_PROFILE=$(jq -r '.profile' "$PROFILE_JSON")
DEVICE_OVERLAY="${PROFILE_DIR}/${DEVICE_PROFILE}/files"
if [ -d "$DEVICE_OVERLAY" ]; then
  log_info "合并设备 overlay: $DEVICE_OVERLAY"
  cp -a "$DEVICE_OVERLAY/." "$IB_DIR/files/"
fi
log_end

# ============================================
# 步骤 6: 执行固件构建
# ============================================
log_section "步骤 6/6: 执行固件构建"
TARGET_PROFILE=$(jq -r '.profile' "$PROFILE_JSON")
ROOTFS_SIZE=$(jq -r '.rootfs_partsize' "$PROFILE_JSON")
EXTRA_NAME=$(jq -r '.extra_image_name' "$PROFILE_JSON")

ADD_PKGS=$(jq -r '.packages.add | join(" ")' "$PROFILE_JSON")
REMOVE_PKGS=$(jq -r '.packages.remove | map("-" + .) | join(" ")' "$PROFILE_JSON")
FINAL_PKGS="$ADD_PKGS $REMOVE_PKGS"

log_info "Target: $(jq -r '.target' "$PROFILE_JSON")"
log_info "Profile: $TARGET_PROFILE"
log_info "Rootfs: ${ROOTFS_SIZE}MB"
log_info "Packages: $FINAL_PKGS"

cd "$IB_DIR"
if ! make image \
    PROFILE="$TARGET_PROFILE" \
    PACKAGES="$FINAL_PKGS" \
    FILES=files \
    BIN_DIR="$OUT_DIR" \
    EXTRA_IMAGE_NAME="$EXTRA_NAME" \
    ROOTFS_PARTSIZE="$ROOTFS_SIZE"; then
  log_error "固件构建失败！"
  exit 1
fi
log_end

# ============================================
# 整理输出
# ============================================
log_section "构建完成"
cd "$OUT_DIR"

for f in *-combined-efi.img.gz; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}-combined-efi.img.gz"; done
for f in *-combined-efi.img; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}-combined-efi.img"; done
for f in *-squashfs-sdcard.img.gz; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}-squashfs-sdcard.img.gz"; done
for f in *-squashfs-sdcard.img; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}-squashfs-sdcard.img"; done
for f in *-kernel; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}-kernel"; done
for f in *-rootfs.tar.gz; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}-rootfs.tar.gz"; done
for f in *.manifest; do [ -f "$f" ] && mv "$f" "daede-${EXTRA_NAME}.manifest"; done

for f in *.img.gz *.img *.kernel *.tar.gz *.manifest; do
  [ -f "$f" ] || continue
  sha256sum "$f"
done > sha256sums

BUILD_END=$(date +%s)
BUILD_ELAPSED=$((BUILD_END - BUILD_START))
BUILD_MINUTES=$((BUILD_ELAPSED / 60))
BUILD_SECONDS=$((BUILD_ELAPSED % 60))

log_info "构建用时: ${BUILD_MINUTES}m ${BUILD_SECONDS}s"
log_info "输出文件: $(ls -1 "$OUT_DIR"/*.img.gz "$OUT_DIR"/*.img 2>/dev/null | wc -l) 个镜像"
log_end
