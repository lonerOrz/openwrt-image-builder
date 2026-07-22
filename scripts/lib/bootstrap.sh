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

  # 下载 ImageBuilder 压缩包（有缓存则跳过）
  if [ ! -f "$ib_archive" ]; then
    log_info "正在获取 ImageBuilder 归档文件..."
    safe_download "$ib_url" "$ib_archive"
  else
    log_info "发现已缓存的 ImageBuilder 归档，跳过下载。"
  fi

  # 解压缩（若已存在且 staging_dir 正常，则跳过）
  if [ ! -f "$ib_dir/staging_dir/host/bin/apk" ]; then
    log_info "解压 ImageBuilder..."
    rm -rf "$ib_dir"
    mkdir -p "$ib_dir"
    tar --use-compress-program=unzstd -xf "$ib_archive" -C "$ib_dir" --strip-components=1
    log_info "ImageBuilder 展开完成。"
  else
    log_info "ImageBuilder 运行环境已就绪，跳过解压。"
  fi

  # 输出 IB_DIR 供调用方使用
  echo "$ib_dir"
}
