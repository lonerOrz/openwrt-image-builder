#!/usr/bin/env bash
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# 从 GitHub Release 解析 APK 下载地址
resolve_github_release_url() {
  local repo="$1" tag="$2" arch="$3"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  [ "$tag" != "latest" ] && api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

  python3 - "$api_url" "$arch" <<'PY'
import json, sys, urllib.request, os

api_url, arch = sys.argv[1:3]
req = urllib.request.Request(api_url, headers={
    "Accept": "application/vnd.github+json",
    "User-Agent": "openwrt-imagebuilder",
})
token = os.environ.get("GITHUB_TOKEN")
if token:
    req.add_header("Authorization", f"Bearer {token}")

try:
    with urllib.request.urlopen(req, timeout=30) as res:
        data = json.load(res)
    suffix = f"-{arch}.apk"
    urls = [
        a["browser_download_url"] for a in data.get("assets", [])
        if a["name"].startswith("luci-app-daede-") and a["name"].endswith(suffix)
    ]
    if urls:
        print(urls[0])
    else:
        tag = data.get("tag_name", api_url)
        print(f"luci-app-daede APK for {arch} not found in {tag}", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"Failed to fetch release: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# 处理 custom_apks 数组：下载、校验架构、规范命名
process_custom_apks() {
  local ib_dir="$1"
  local profile_json="$2"
  local packages_dir="$ib_dir/packages"
  local apk_tool="$ib_dir/staging_dir/host/bin/apk"

  mkdir -p "$packages_dir"

  # 检查是否有 custom_apks 配置
  local apks_count
  apks_count=$(jq '.custom_apks | length' "$profile_json" 2>/dev/null || echo "0")
  if [ "$apks_count" = "0" ] || [ "$apks_count" = "null" ]; then
    log_info "无第三方 APK 配置，跳过。"
    return
  fi

  log_info "处理 $apks_count 个第三方 APK..."

  # 逐个处理
  for i in $(seq 0 $((apks_count - 1))); do
    local name source_type repo tag arch download_url
    name=$(jq -r ".custom_apks[$i].name" "$profile_json")
    source_type=$(jq -r ".custom_apks[$i].source_type" "$profile_json")

    if [ "$source_type" = "github_release" ]; then
      repo=$(jq -r ".custom_apks[$i].repo" "$profile_json")
      tag=$(jq -r ".custom_apks[$i].tag // \"latest\"" "$profile_json")
      arch=$(jq -r ".custom_apks[$i].arch" "$profile_json")

      download_url=$(resolve_github_release_url "$repo" "$tag" "$arch")
      local temp_apk="$packages_dir/${name}_temp.apk"
      safe_download "$download_url" "$temp_apk"

      # 用 apk 提取元数据并校验架构
      if [ -f "$apk_tool" ]; then
        local meta
        if ! meta=$("$apk_tool" adbdump "$temp_apk" 2>/dev/null); then
          log_error "APK 文件损坏或非法: $name"
          rm -f "$temp_apk"
          exit 1
        fi

        local real_name real_version real_arch
        real_name=$(echo "$meta" | sed -n 's/^P: //p' | head -n1)
        real_version=$(echo "$meta" | sed -n 's/^V: //p' | head -n1)
        real_arch=$(echo "$meta" | sed -n 's/^A: //p' | head -n1)

        # 架构兼容性检查（允许 all/noarch 或精确匹配）
        if [ "$real_arch" != "all" ] && [ "$real_arch" != "noarch" ] && [ "$real_arch" != "$arch" ]; then
          log_error "第三方 APK 架构冲突！期望: $arch, 实际: $real_arch"
          rm -f "$temp_apk"
          exit 1
        fi

        # 规范命名为 NAME-VERSION.apk
        local dest_apk="$packages_dir/${real_name}-${real_version}.apk"
        mv "$temp_apk" "$dest_apk"
        log_info "规范化成功: ${real_name}-${real_version}.apk"
      else
        log_warn "未找到 apk 工具，跳过架构校验，使用原始文件名"
        mv "$temp_apk" "$packages_dir/${name}.apk"
      fi
    elif [ "$source_type" = "direct_url" ]; then
      local url
      url=$(jq -r ".custom_apks[$i].url" "$profile_json")
      local fname="${url##*/}"
      safe_download "$url" "$packages_dir/$fname"
      log_info "下载直链包: $fname"
    fi
  done
}

# 重建 APK 本地索引
rebuild_local_index() {
  local ib_dir="$1"
  local packages_dir="$ib_dir/packages"
  local apk_tool="$ib_dir/staging_dir/host/bin/apk"

  if [ ! -d "$packages_dir" ] || ! ls "$packages_dir"/*.apk >/dev/null 2>&1; then
    log_info "无本地 .apk 文件，跳过索引重建。"
    return
  fi

  rm -f "$packages_dir/packages.adb"
  if (cd "$packages_dir" && "$apk_tool" mkndx --allow-untrusted --output packages.adb *.apk 2>&1); then
    local count
    count=$(ls "$packages_dir"/*.apk 2>/dev/null | wc -l)
    log_info "本地 APK 索引重建完毕（$count 个包）。"
  else
    log_error "apk mkndx 失败，本地包可能无法被识别"
    exit 1
  fi
}
