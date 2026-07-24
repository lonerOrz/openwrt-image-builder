#!/usr/bin/env bash
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# 下载并解压 ImageBuilder，支持缓存
bootstrap_imagebuilder() {
  local profile_json="$1"
  local work_dir="$2"

  local ib_url
  ib_url=$(jq -r '.imagebuilder_url' "$profile_json")

  local archive_name="${ib_url##*/}"
  local ib_archive="$work_dir/$archive_name"
  local ib_dir="$work_dir/imagebuilder"

  mkdir -p "$work_dir"

  log_info "ImageBuilder URL: $ib_url"

  # 下载 ImageBuilder 压缩包（有缓存则跳过，但 URL 变化时重新下载）
  local cache_url_file="$work_dir/.ib_url"
  local cached_url=""
  [ -f "$cache_url_file" ] && cached_url=$(cat "$cache_url_file")
  if [ ! -f "$ib_archive" ] || [ "$cached_url" != "$ib_url" ]; then
    log_info "下载 ImageBuilder 归档文件..."
    safe_download "$ib_url" "$ib_archive"
    echo "$ib_url" > "$cache_url_file"
    local archive_size
    archive_size=$(du -h "$ib_archive" 2>/dev/null | cut -f1)
    log_info "下载完成: $archive_name ($archive_size)"
  else
    log_info "使用缓存: $archive_name (URL 未变化)"
  fi

  # 解压缩（若已存在且 staging_dir 正常，则跳过）
  if [ ! -f "$ib_dir/staging_dir/host/bin/apk" ]; then
    log_info "解压 ImageBuilder..."
    rm -rf "$ib_dir"
    mkdir -p "$ib_dir"
    tar --use-compress-program=unzstd -xf "$ib_archive" -C "$ib_dir" --strip-components=1
    local ib_files
    ib_files=$(find "$ib_dir" -maxdepth 1 -type f | wc -l)
    log_info "解压完成: $ib_files 个顶级文件/目录"
  else
    log_info "ImageBuilder 已就绪，跳过解压。"
  fi

  # 输出 IB_DIR 供调用方使用
  echo "$ib_dir"
}
