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

process_custom_apks() {
  local ib_dir="$1"
  local profile_json="$2"
  local packages_dir="$ib_dir/packages"

  mkdir -p "$packages_dir"

  local apks_count
  apks_count=$(jq '.custom_apks | length' "$profile_json" 2>/dev/null || echo "0")
  if [ "$apks_count" = "0" ] || [ "$apks_count" = "null" ]; then
    log_info "无第三方 APK 配置，跳过。"
    return
  fi

  log_info "处理 $apks_count 个第三方 APK..."

  for i in $(seq 0 $((apks_count - 1))); do
    local name source_type repo tag arch download_url
    name=$(jq -r ".custom_apks[$i].name" "$profile_json")
    source_type=$(jq -r ".custom_apks[$i].source_type" "$profile_json")

    if [ "$source_type" = "github_release" ]; then
      repo=$(jq -r ".custom_apks[$i].repo" "$profile_json")
      tag=$(jq -r ".custom_apks[$i].tag // \"latest\"" "$profile_json")
      arch=$(jq -r ".custom_apks[$i].arch" "$profile_json")

      download_url=$(resolve_github_release_url "$repo" "$tag" "$arch")
      local fname="${download_url##*/}"
      fname="${fname%-${arch}.apk}.apk"

      safe_download "$download_url" "$packages_dir/$fname"
      log_info "已下载: $fname"
    elif [ "$source_type" = "direct_url" ]; then
      local url
      url=$(jq -r ".custom_apks[$i].url" "$profile_json")
      local fname="${url##*/}"
      safe_download "$url" "$packages_dir/$fname"
      log_info "下载直链包: $fname"
    fi
  done
}

# 重建 APK 本地索引并注册本地源（使用绝对路径解决上游相对路径 Bug）
rebuild_local_index() {
  local ib_dir="$1"
  local packages_dir="$ib_dir/packages"
  local apk_tool="$ib_dir/staging_dir/host/bin/apk"
  local repos_file="$ib_dir/repositories"

  if [ ! -d "$packages_dir" ] || ! ls "$packages_dir"/*.apk >/dev/null 2>&1; then
    log_info "无本地 .apk 文件，跳过索引重建与本地源注册。"
    return
  fi

  rm -f "$packages_dir/packages.adb"
  log_info "正在为本地第三方 APK 建立索引..."

  if (cd "$packages_dir" && "$apk_tool" mkndx --allow-untrusted --output packages.adb *.apk 2>&1); then
    local count
    count=$(ls "$packages_dir"/*.apk 2>/dev/null | wc -l)
    log_info "本地 APK 索引重建完毕（$count 个包）。"

    # 使用绝对路径 file:// 协议注册本地源，兼容新版 APK 安全策略
    local abs_packages_dir
    abs_packages_dir=$(cd "$packages_dir" && pwd)

    if [ -f "$repos_file" ]; then
      if ! grep -q "$abs_packages_dir" "$repos_file"; then
        echo "file://$abs_packages_dir/packages.adb" >> "$repos_file"
        log_info "本地源注册完成: file://$abs_packages_dir/packages.adb"
      fi
    fi
  else
    log_error "apk mkndx 失败，本地包可能无法被识别"
    return 1
  fi
}
