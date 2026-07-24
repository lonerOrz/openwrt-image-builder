#!/usr/bin/env bash
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# 检查 APK 文件名是否包含多余架构后缀（_all, _x86_64 等）
# 25.12.x ImageBuilder 要求文件名与内部元数据完全一致
# 仅在文件名确实包含多余后缀时才清理，否则保留原始文件名
clean_apk_filename() {
  local filename="$1"
  local cleaned="$filename"
  # 仅当文件名确实包含已知多余后缀时才清理
  case "$filename" in
    *_all.apk|*_x86_64.apk|*-x86-64.apk)
      cleaned="${filename%_all.apk}"
      cleaned="${cleaned%_x86_64.apk}"
      cleaned="${cleaned%-x86-64.apk}"
      cleaned="${cleaned}.apk"
      ;;
    *_aarch64_*.apk|-aarch64-*.apk)
      cleaned=$(echo "$filename" | sed -E 's/[-_]aarch64_[a-z0-9_-]+\.apk$/.apk/')
      ;;
  esac
  if [ "$cleaned" != "$filename" ]; then
    log_warn "APK 文件名包含多余架构后缀: $filename -> $cleaned"
  fi
  echo "$cleaned"
}

# 从 GitHub Release 解析 APK 下载地址
resolve_github_release_url() {
  local repo="$1" tag="$2" arch="$3" name="$4"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  [ "$tag" != "latest" ] && api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

  python3 - "$api_url" "$arch" "$name" <<'PY'
import json, sys, urllib.request, os

api_url, arch, pkg_name = sys.argv[1:4]
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
        if a["name"].endswith(suffix)
    ]
    if urls:
        print(urls[0])
    else:
        tag = data.get("tag_name", api_url)
        print(f"APK for {arch} not found in {tag}", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"Failed to fetch release: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# 解包 .run 文件（makeself 格式），提取其中的 .apk 文件
unpack_run_files() {
  local src_dir="$1"
  local dest_dir="$2"
  local tmp_dir
  tmp_dir=$(mktemp -d)

  local run_count=0
  for run_file in "$src_dir"/*.run; do
    [ -f "$run_file" ] || continue
    run_count=$((run_count + 1))
    local run_name
    run_name=$(basename "$run_file")
    log_info "  解包 [$run_count]: $run_name"
    if sh "$run_file" --target "$tmp_dir/unpack" --noexec >/dev/null 2>&1; then
      local apk_count
      apk_count=$(find "$tmp_dir/unpack" -name '*.apk' 2>/dev/null | wc -l)
      find "$tmp_dir/unpack" -name '*.apk' -exec cp {} "$dest_dir/" \;
      log_info "  提取完成: $apk_count 个 APK"
      rm -rf "$tmp_dir/unpack"
    else
      log_warn "  解包失败: $run_name"
    fi
  done

  # 同时也处理子目录中的 .apk 文件（如 wukongdaily/apk 仓库结构）
  local sub_apks
  sub_apks=$(find "$src_dir" -mindepth 2 -maxdepth 2 -name '*.apk' 2>/dev/null | wc -l)
  if [ "$sub_apks" -gt 0 ]; then
    find "$src_dir" -mindepth 2 -maxdepth 2 -name '*.apk' -exec cp {} "$dest_dir/" \;
    log_info "  子目录 APK: $sub_apks 个"
  fi

  rm -rf "$tmp_dir"
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
  log_info ""

  for i in $(seq 0 $((apks_count - 1))); do
    local name source_type repo tag arch download_url
    name=$(jq -r ".custom_apks[$i].name" "$profile_json")
    source_type=$(jq -r ".custom_apks[$i].source_type" "$profile_json")
    log_info "[$((i+1))/$apks_count] $name ($source_type)"

    if [ "$source_type" = "github_release" ]; then
      repo=$(jq -r ".custom_apks[$i].repo" "$profile_json")
      tag=$(jq -r ".custom_apks[$i].tag // \"latest\"" "$profile_json")
      arch=$(jq -r ".custom_apks[$i].arch" "$profile_json")
      log_info "  仓库: $repo | 标签: $tag | 架构: $arch"

      download_url=$(resolve_github_release_url "$repo" "$tag" "$arch" "$name")
      local fname="${download_url##*/}"
      # 25.12.x: 文件名必须与 APK 内部元数据完全一致
      # 仅清理开发者添加的多余架构后缀（_all, _x86_64 等）
      fname=$(clean_apk_filename "$fname")

      safe_download "$download_url" "$packages_dir/$fname"
      local fsize
      fsize=$(du -h "$packages_dir/$fname" 2>/dev/null | cut -f1)
      log_info "  下载完成: $fname ($fsize)"
    elif [ "$source_type" = "direct_url" ]; then
      local url
      url=$(jq -r ".custom_apks[$i].url" "$profile_json")
      log_info "  URL: $url"
      local fname="${url##*/}"
      safe_download "$url" "$packages_dir/$fname"
      local fsize
      fsize=$(du -h "$packages_dir/$fname" 2>/dev/null | cut -f1)
      log_info "  下载完成: $fname ($fsize)"
    elif [ "$source_type" = "git_clone" ]; then
      repo=$(jq -r ".custom_apks[$i].repo" "$profile_json")
      local path
      path=$(jq -r ".custom_apks[$i].path // \"\"" "$profile_json")
      log_info "  仓库: $repo | 路径: ${path:-/}"
      local clone_dir
      clone_dir=$(mktemp -d)

      if git clone --depth=1 "https://github.com/${repo}.git" "$clone_dir/repo" >/dev/null 2>&1; then
        local src_path="$clone_dir/repo"
        [ -n "$path" ] && src_path="$clone_dir/repo/$path"

        if [ -d "$src_path" ]; then
          local before_count
          before_count=$(ls "$packages_dir"/*.apk 2>/dev/null | wc -l)
          # 检查是否有 .run 文件需要解包
          if ls "$src_path"/*.run >/dev/null 2>&1; then
            unpack_run_files "$src_path" "$packages_dir"
          fi
          # 同时也复制直接存在的 .apk 文件
          find "$src_path" -maxdepth 1 -name '*.apk' -exec cp {} "$packages_dir/" \;
          local after_count
          after_count=$(ls "$packages_dir"/*.apk 2>/dev/null | wc -l)
          local new_apks=$((after_count - before_count))
          log_info "  获取完成: 新增 $new_apks 个 APK"
        else
          log_error "  路径不存在: $path"
        fi
      else
        log_error "  克隆失败: $repo"
      fi
      rm -rf "$clone_dir"
    else
      log_warn "  未知 source_type: $source_type，跳过"
    fi
    log_info ""
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
