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
DAEDE_REPO="${DAEDE_REPO:-kenzok8/openwrt-daede}"
DAEDE_RELEASE_TAG="${DAEDE_RELEASE_TAG:-latest}"
DAEDE_ARCH="${DAEDE_ARCH:-aarch64}"
DAEDE_APK_URL="${DAEDE_APK_URL:-}"

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci-theme-argon luci-app-daede kmod-sched-core curl nano nginx openssl-util}"
REMOVE_PACKAGES="${REMOVE_PACKAGES:--luci-app-wifihistory -luci-app-advancedplus -luci-app-filemanager -luci-app-wizard -coremark -ds-lite -usb-modeswitch -luci-app-attendedsysupgrade}"
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

resolve_daede_apk_url() {
  if [ -n "$DAEDE_APK_URL" ]; then
    printf '%s\n' "$DAEDE_APK_URL"
    return
  fi

  local release_api
  if [ "$DAEDE_RELEASE_TAG" = "latest" ]; then
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/latest"
  else
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/tags/$DAEDE_RELEASE_TAG"
  fi

  python3 - "$release_api" "$DAEDE_ARCH" <<'PY'
import json
import os
import sys
import urllib.request

release_api, arch = sys.argv[1:3]
request = urllib.request.Request(
    release_api,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "kenzok8-imagebuilder",
    },
)
token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", f"Bearer {token}")

with urllib.request.urlopen(request, timeout=30) as response:
    release = json.load(response)

suffix = f"-{arch}.apk"
matches = [
    asset.get("browser_download_url") or asset.get("url")
    for asset in release.get("assets", [])
    if asset.get("name", "").startswith("luci-app-daede-")
    and asset.get("name", "").endswith(suffix)
]

if not matches:
    tag = release.get("tag_name", release_api)
    raise SystemExit(f"luci-app-daede APK for {arch} not found in {tag}")

print(matches[0])
PY
}

install_daede_apk() {
  case "$INSTALL_DAEDE" in
    1|true|yes) ;;
    *)
      echo "Skipping luci-app-daede release APK download."
      return
      ;;
  esac

  local packages_dir="$WORK_DIR/imagebuilder/packages"
  local daede_url
  daede_url="$(resolve_daede_apk_url)"
  mkdir -p "$packages_dir"

  # Strip the -<arch> suffix from the release filename. apk mkndx indexes the
  # package under its canonical name-version.apk; if the file keeps the
  # -x86_64 suffix the index entry points to a missing file and the build
  # fails with "package mentioned in index not found".
  local fname="${daede_url##*/}"
  fname="${fname%-${DAEDE_ARCH}.apk}.apk"

  echo "Downloading luci-app-daede APK: $daede_url -> $fname"
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$packages_dir/$fname" "$daede_url"
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

# Rename local APK files to comply with APK naming: name-version.apk
# The APK resolver requires physical filename == <name>-<version>.apk
normalize_local_apks() {
  local packages_dir="$WORK_DIR/imagebuilder/packages"
  local apk_tool="$WORK_DIR/imagebuilder/staging_dir/host/bin/apk"

  [ -d "$packages_dir" ] || return 0
  [ -f "$apk_tool" ] || {
    echo "WARNING: apk tool not found at $apk_tool, skipping normalization."
    return 0
  }

  local count=0
  for apk_file in "$packages_dir"/*.apk; do
    [ -f "$apk_file" ] || continue
    local fname="${apk_file##*/}"

    # Skip system packages
    case "$fname" in
      base-files-*|libc-*|kernel-*) continue ;;
    esac

    # Use apk adbdump to extract name and version from APK metadata
    local info
    if ! info=$("$apk_tool" adbdump "$apk_file" 2>/dev/null); then
      echo "WARNING: Failed to read metadata from $fname, skipping"
      continue
    fi

    local pkg_name pkg_version
    pkg_name=$(echo "$info" | sed -n 's/^P: //p' | head -n1)
    pkg_version=$(echo "$info" | sed -n 's/^V: //p' | head -n1)

    if [ -z "$pkg_name" ] || [ -z "$pkg_version" ]; then
      echo "WARNING: Could not extract name/version from $fname, skipping"
      continue
    fi

    local dest_name="${pkg_name}-${pkg_version}.apk"
    if [ "$fname" != "$dest_name" ]; then
      echo "Renaming: $fname -> $dest_name"
      rm -f "$packages_dir/$dest_name"
      mv "$apk_file" "$packages_dir/$dest_name"
      count=$((count + 1))
    fi
  done

  echo "Normalized $count APK file(s)"
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

log_section "安装 daede APK"
install_daede_apk
log_end

log_section "安装第三方包"
install_custom_packages
log_end

log_section "规范化本地 APK 文件名"
normalize_local_apks
log_end

log_section "重建 APK 索引"
PACKAGES_DIR="$WORK_DIR/imagebuilder/packages"
if [ -d "$PACKAGES_DIR" ] && ls "$PACKAGES_DIR"/*.apk >/dev/null 2>&1; then
  rm -f "$PACKAGES_DIR/packages.adb"
  if (cd "$PACKAGES_DIR" && "../staging_dir/host/bin/apk" mkndx \
      --allow-untrusted --output packages.adb *.apk 2>&1); then
    echo "APK 索引已重建: $(ls "$PACKAGES_DIR"/*.apk 2>/dev/null | wc -l) 个包"
  else
    echo "WARNING: apk mkndx 失败，本地包可能无法被识别"
  fi
else
  echo "无本地 .apk 文件，跳过索引重建"
fi
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
echo "Install daede APK: $INSTALL_DAEDE"
echo "Daede release: $DAEDE_REPO@$DAEDE_RELEASE_TAG ($DAEDE_ARCH)"
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
- The luci-app-daede release APK was not copied into the local ImageBuilder
  packages directory, or its architecture does not match the selected target.

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
  # 确保 packages.adb 被重建（ImageBuilder 的 package_reload 可能跳过）
  rm -f "$WORK_DIR/imagebuilder/packages/packages.adb"
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
