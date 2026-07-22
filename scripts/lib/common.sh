#!/usr/bin/env bash
set -euo pipefail

# 统一日志格式（GitHub Actions compatible）
log_info() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::notice::$1"
  else
    echo -e "\033[1;32m[INFO]\033[0m $1"
  fi
}

log_warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning::$1" >&2
  else
    echo -e "\033[1;33m[WARN]\033[0m $1" >&2
  fi
}

log_error() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::$1" >&2
  else
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
  fi
}

log_section() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::group::[$(date '+%H:%M:%S')] $1"
  else
    echo ""
    echo "=== $1 ==="
  fi
}

log_end() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::endgroup::"
  fi
}

# 安全下载网络文件（带重试和超时）
safe_download() {
  local url="$1"
  local dest="$2"
  log_info "正在下载: $url"
  curl -L --retry 5 --retry-delay 3 --connect-timeout 30 -o "$dest" "$url"
}

# 获取脚本所在目录的绝对路径
get_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}
