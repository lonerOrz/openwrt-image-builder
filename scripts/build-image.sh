#!/usr/bin/env bash
set -euo pipefail

# --- Profile loading ---
DEVICE_PROFILE="${DEVICE_PROFILE:-friendlyarm_nanopi-r2s}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="${PROFILE_DIR:-$(dirname "$SCRIPT_DIR")/profiles}"
PROFILE_FILE="${PROFILE_DIR}/${DEVICE_PROFILE}.env"

if [ -f "$PROFILE_FILE" ]; then
  echo "Loading device profile: $DEVICE_PROFILE"
  # shellcheck disable=SC1090
  source "$PROFILE_FILE"
else
  echo "WARNING: Profile $PROFILE_FILE not found, using script defaults." >&2
fi

# --- Logging helpers (GitHub Actions compatible) ---
log_section() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::group::[$(date '+%H:%M:%S')] $1"
  else
    echo "=== $1 ==="
  fi
}

log_end() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::endgroup::"
  fi
}

BUILD_START=$(date +%s)

# --- Variable defaults (profile values take priority via env) ---
VERSION="${VERSION:-25.12-SNAPSHOT}"
TARGET="${TARGET:-rockchip/armv8}"
PROFILE="${PROFILE:-friendlyarm_nanopi-r2s}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-r2s}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-512}"
INSTALL_DAEDE="${INSTALL_DAEDE:-1}"
DAEDE_ARCH="${DAEDE_ARCH:-aarch64}"

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci-theme-argon luci-app-daede kmod-sched-core curl nano nginx openssl-util}"
REMOVE_PACKAGES="${REMOVE_PACKAGES:--luci-app-wifihistory -luci-app-advancedplus -luci-app-filemanager -luci-app-wizard -coremark -ds-lite -usb-modeswitch -luci-app-attendedsysupgrade}"
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

configure_daede_feed() {
  case "$INSTALL_DAEDE" in
    1|true|yes) ;;
    *)
      echo "Skipping daede feed configuration."
      return
      ;;
  esac

  local ib_dir="$WORK_DIR/imagebuilder"
  local repos_file="$ib_dir/repositories"
  local feed_base="https://down.dllkids.xyz/openwrt-feed/25.12"

  # Architecture candidates: exact arch → common sub-archs → all
  local arch_candidates=("$DAEDE_ARCH")
  case "$DAEDE_ARCH" in
    aarch64|arm64)
      arch_candidates+=("aarch64_cortex-a53" "aarch64_cortex-a72" "aarch64_generic")
      ;;
    aarch64_*)
      [ "$DAEDE_ARCH" = "aarch64_generic" ] || arch_candidates+=("aarch64_generic")
      ;;
  esac
  arch_candidates+=("all")

  # Find a working feed
  local feed_url=""
  for arch in "${arch_candidates[@]}"; do
    local candidate_url="$feed_base/$arch/packages.adb"
    if curl -fsSL -o /dev/null "$candidate_url" 2>/dev/null; then
      feed_url="$candidate_url"
      echo "Found daede feed: $arch"
      break
    fi
  done

  if [ -z "$feed_url" ]; then
    echo "ERROR: No daede feed found for $DAEDE_ARCH (tried: ${arch_candidates[*]})" >&2
    exit 1
  fi

  # Add feed to ImageBuilder repositories
  echo "$feed_url" >> "$repos_file"
  echo "Added daede feed: $feed_url"

  # Install signing key to rootfs so flashed firmware can verify daede packages
  local key_dir="$ib_dir/files/etc/apk/keys"
  mkdir -p "$key_dir"
  if curl -fsSL -o "$key_dir/dllkids-feed.pub.pem" \
    "https://down.dllkids.xyz/openwrt-feed/keys/dllkids-feed.pub.pem" 2>/dev/null; then
    echo "Installed daede feed signing key"
  else
    echo "WARNING: Failed to download daede signing key" >&2
  fi
}

install_custom_packages() {
  [ -z "$CUSTOM_PACKAGES" ] && return

  local packages_dir="$WORK_DIR/imagebuilder/packages"
  mkdir -p "$packages_dir"

  echo "$CUSTOM_PACKAGES" | while IFS='=' read -r pkg_name pkg_url; do
    pkg_name="$(echo "$pkg_name" | xargs)"
    pkg_url="$(echo "$pkg_url" | xargs)"
    [ -z "$pkg_name" ] || [ -z "$pkg_url" ] && continue
    local fname="${pkg_url##*/}"
    echo "Downloading custom package: $pkg_name -> $fname"
    curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
      -o "$packages_dir/$fname" "$pkg_url"
  done
}

log_section "下载 ImageBuilder"
if [ ! -s "$IB_ARCHIVE" ]; then
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$IB_ARCHIVE" "$IMAGEBUILDER_URL"
fi
log_end

log_section "解压 ImageBuilder"
rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$WORK_DIR/imagebuilder" --strip-components=1
log_end

log_section "安装自定义文件"
cp -a files "$WORK_DIR/imagebuilder/files"
# Merge device-specific overlay if present
DEVICE_OVERLAY="${PROFILE_DIR}/${DEVICE_PROFILE}/files"
if [ -d "$DEVICE_OVERLAY" ]; then
  echo "Merging device overlay: $DEVICE_OVERLAY"
  cp -a "$DEVICE_OVERLAY/." "$WORK_DIR/imagebuilder/files/"
fi
log_end

log_section "配置 daede 仓库"
configure_daede_feed
log_end

log_section "安装第三方包"
install_custom_packages
log_end

cd "$WORK_DIR/imagebuilder"

# 合并包列表: 安装的包 + 要移除的包
PACKAGES="$EXTRA_PACKAGES $REMOVE_PACKAGES"

echo "Version: $VERSION"
echo "Target: $TARGET"
echo "Profile: $PROFILE"
echo "Rootfs part size: ${ROOTFS_PARTSIZE}MB"
echo "Install: $EXTRA_PACKAGES"
echo "Remove: $REMOVE_PACKAGES"
echo "Custom packages: ${CUSTOM_PACKAGES:-(none)}"
echo "Daede feed: $INSTALL_DAEDE (arch: $DAEDE_ARCH)"
mkdir -p "$OUT_DIR"
echo "extra_packages=$PACKAGES" > "$OUT_DIR/.extra_packages"
echo "$EXTRA_IMAGE_NAME" > "$OUT_DIR/.extra_image_name"

diagnose_failure() {
  cat >&2 <<'EOF'

ImageBuilder failed.

Common causes:
- The selected ImmortalWrt snapshot ImageBuilder and package feeds are out of sync.
- luci-app-daede or dae/daed dependencies (kmod-sched-core) are missing from
  the selected target's kmod feed for the current kernel version.
- The daede feed (down.dllkids.xyz) may be temporarily unavailable.

About BTF (no longer a blocker on 25.12):
- ImmortalWrt 25.12 kernels enable CONFIG_DEBUG_INFO_BTF by default. dae/daed reads BTF
  directly from /sys/kernel/btf/vmlinux at runtime and does NOT require a separate
  vmlinux-btf package.

Next choices:
- Retry later after feeds finish syncing.
- Set INSTALL_DAEDE=0 to build without daede and install it post-flash.
- Verify kmod-* packages exist for the target+kernel combo via:
    make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES"
EOF
}

log_section "Preflight 检查"
if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then
  if ! make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES"; then
    diagnose_failure
    exit 1
  fi
else
  echo "Preflight skipped."
fi
log_end

log_section "构建固件"
if ! make image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES=files \
    BIN_DIR="$OUT_DIR" \
    EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"; then
  diagnose_failure
  exit 1
fi
log_end

log_section "整理输出文件"
cd "$OUT_DIR"

# 自适应多架构重命名（同时支持 combined-efi 和 squashfs-sdcard）
for f in *-combined-efi.img.gz; do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}-combined-efi.img.gz"; done
for f in *-combined-efi.img;    do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}-combined-efi.img";    done
for f in *-squashfs-sdcard.img.gz; do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}-squashfs-sdcard.img.gz"; done
for f in *-squashfs-sdcard.img;    do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}-squashfs-sdcard.img";    done
for f in *-kernel; do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}-kernel"; done
for f in *-rootfs.tar.gz; do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}-rootfs.tar.gz"; done
for f in *.manifest; do [ -f "$f" ] && mv "$f" "immortalwrt-${EXTRA_IMAGE_NAME}.manifest"; done

for f in *.img.gz *.img *.kernel *.tar.gz *.manifest; do
  [ -f "$f" ] || continue
  sha256sum "$f"
done > sha256sums

# 动态查找实际文件名，用于 Release 说明
IMG_GZ_NAME="$(find . -maxdepth 1 -name "*.img.gz" -exec basename {} \; | head -n 1)"
IMG_NAME="$(find . -maxdepth 1 -name "*.img" -not -name "*.img.gz" -not -name "*.img.tar.gz" -exec basename {} \; | head -n 1)"
IMG_GZ_NAME="${IMG_GZ_NAME:-immortalwrt-${EXTRA_IMAGE_NAME}-squashfs-sdcard.img.gz}"
IMG_NAME="${IMG_NAME:-immortalwrt-${EXTRA_IMAGE_NAME}-squashfs-sdcard.img}"

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"
cat > BUILD-MANIFEST.txt <<BODYEOF
## ${EXTRA_IMAGE_NAME} 固件 · ImmortalWrt ${VERSION}

基于 ImmortalWrt ${VERSION}，${PROFILE} (${TARGET}) 镜像。

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | dd 写入（压缩） | ${IMG_GZ_NAME} |
| **img** | dd 写入（未压缩） | ${IMG_NAME} |

### 镜像详情

- **目标设备**：${PROFILE}
- **架构**：${TARGET}
- **根分区大小**：${ROOTFS_PARTSIZE} MB
- **构建日期**：${BUILD_DATE}
- **ImageBuilder**：${IMAGEBUILDER_URL}

### 预装软件

\$(cat "$OUT_DIR/.extra_packages" 2>/dev/null || echo "$EXTRA_PACKAGES")

### 校验

\`\`\`bash
sha256sum -c sha256sums --ignore-missing
\`\`\`
BODYEOF
log_end

# --- GitHub Step Summary ---
BUILD_END=$(date +%s)
BUILD_ELAPSED=$((BUILD_END - BUILD_START))
BUILD_MINUTES=$((BUILD_ELAPSED / 60))
BUILD_SECONDS=$((BUILD_ELAPSED % 60))

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 构建报告 · ${EXTRA_IMAGE_NAME}"
    echo ""
    echo "| 项目 | 值 |"
    echo "|------|-----|"
    echo "| 设备 Profile | \`${PROFILE}\` |"
    echo "| 架构 | \`${TARGET}\` |"
    echo "| 根分区 | ${ROOTFS_PARTSIZE} MB |"
    echo "| 构建用时 | ${BUILD_MINUTES}m ${BUILD_SECONDS}s |"
    echo ""
    echo "### 输出文件"
    echo ""
    echo "| 文件 | 大小 | SHA256 |"
    echo "|------|------|--------|"
    for f in "$OUT_DIR"/*.img.gz "$OUT_DIR"/*.img "$OUT_DIR"/*.kernel "$OUT_DIR"/*.tar.gz; do
      [ -f "$f" ] || continue
      fname="$(basename "$f")"
      fsize="$(du -h "$f" | cut -f1)"
      fhash="$(sha256sum "$f" | cut -d' ' -f1 | head -c 16)…"
      echo "| ${fname} | ${fsize} | \`${fhash}\` |"
    done
    echo ""
    echo "### 软件包"
    echo ""
    echo "**安装:** \`$EXTRA_PACKAGES\`"
    echo ""
    echo "**移除:** \`$REMOVE_PACKAGES\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi

ls -la "$OUT_DIR"
