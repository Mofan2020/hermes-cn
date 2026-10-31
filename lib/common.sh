#!/usr/bin/env bash
# 公共函数：日志、平台探测、通用工具。
# 被 lib/*.sh 与 hermes-cn.sh 共同 source。
#
# 兼容性基线：bash 3.2（macOS 自带）、GNU bash 4/5、busybox ash。
# 因此不使用关联数组（declare -A）、${var^^}、mapfile、&>> 等高版本特性。

# 防止重复 source
if [ -n "${HERMES_CN_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
HERMES_CN_COMMON_LOADED=1

# ---------- 路径 ----------
CN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CN_ROOT_DIR="$(cd "$CN_LIB_DIR/.." && pwd)"
export CN_LIB_DIR CN_ROOT_DIR

# ---------- 日志 ----------
# 仅在非交互或显式开启时输出彩色，避免污染管道输出。
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  CN_RED='\033[31m'; CN_GRN='\033[32m'; CN_YEL='\033[33m'
  CN_BLU='\033[34m'; CN_DIM='\033[2m'; CN_BLD='\033[1m'; CN_RST='\033[0m'
else
  CN_RED=''; CN_GRN=''; CN_YEL=''; CN_BLU=''; CN_DIM=''; CN_BLD=''; CN_RST=''
fi

cn_log()  { printf "${CN_DIM}[hermes-cn]${CN_RST} %s\n" "$*" >&2; }
cn_ok()   { printf "${CN_GRN}  ✓${CN_RST} %s\n" "$*" >&2; }
cn_warn() { printf "${CN_YEL}  !${CN_RST} %s\n" "$*" >&2; }
cn_err()  { printf "${CN_RED}  ✗${CN_RST} %s\n" "$*" >&2; }
cn_step() { printf "${CN_BLD}==>${CN_RST} %s\n" "$*" >&2; }

cn_die() {
  cn_err "$*"
  exit 1
}

# ---------- 通用工具 ----------

# cn_have <cmd> —— 命令是否存在
cn_have() {
  command -v "$1" >/dev/null 2>&1
}

# cn_platform —— 输出 linux | darwin | 其他
cn_platform() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)  echo linux ;;
    Darwin*) echo darwin ;;
    *)       echo unknown ;;
  esac
}

# cn_arch —— 输出 x86_64 | aarch64 | 其他
cn_arch() {
  case "$(uname -m 2>/dev/null || echo unknown)" in
    x86_64|amd64)   echo x86_64 ;;
    aarch64|arm64)  echo aarch64 ;;
    armv7l)         echo armv7l ;;
    *)              echo unknown ;;
  esac
}

# cn_python_bin —— 找一个可用的 python3
cn_python_bin() {
  for c in python3 python; do
    if cn_have "$c"; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# cn_http_code <url> [extra curl args...]
# 输出 HTTP 状态码；连接失败输出 000。永远返回 0，方便在条件里使用。
cn_http_code() {
  _url="$1"; shift
  _code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "${CN_PROBE_CONNECT_TIMEOUT:-8}" \
    --max-time "${CN_PROBE_TIMEOUT:-25}" \
    -L "$@" "$_url" 2>/dev/null)
  [ -z "$_code" ] && _code=000
  printf '%s' "$_code"
}

# cn_http_get <url> [extra curl args...] —— 下载到 stdout，失败返回非 0
cn_http_get() {
  _url="$1"; shift
  curl -sS -f \
    --connect-timeout "${CN_PROBE_CONNECT_TIMEOUT:-8}" \
    --max-time "${CN_PROBE_TIMEOUT:-25}" \
    -L "$@" "$_url"
}

# cn_http_head_ok <url> —— GET 一个字节范围并校验状态码 200
# 某些镜像（如华为云）对 HEAD 返回 403，对 GET 正常，因此一律用 GET 探测。
cn_http_get_ok() {
  _url="$1"
  [ "$(cn_http_code "$_url")" = "200" ]
}

# cn_sha256 <file> —— 计算 sha256
cn_sha256() {
  if cn_have sha256sum; then
    sha256sum "$1" | cut -d' ' -f1
  elif cn_have shasum; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

# cn_file_sha256 <file> —— 与 cn_sha256 相同，但找不到工具时返回空串而不是失败
cn_file_sha256() {
  cn_sha256 "$1" 2>/dev/null || echo ""
}

# cn_mktemp_dir —— 创建临时目录并打印路径
cn_mktemp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/hermes-cn.XXXXXX"
}

# cn_cleanup —— 注册临时目录清理
CN_TMP_DIRS=""
cn_cleanup() {
  [ -n "$CN_TMP_DIRS" ] || return 0
  for _d in $CN_TMP_DIRS; do
    [ -d "$_d" ] && rm -rf "$_d"
  done
  CN_TMP_DIRS=""
}
trap cn_cleanup EXIT INT TERM

# cn_new_tmp —— 新建临时目录并登记清理
cn_new_tmp() {
  _d=$(cn_mktemp_dir) || return 1
  CN_TMP_DIRS="$CN_TMP_DIRS $_d"
  printf '%s' "$_d"
}

# cn_new_tmp_file —— 新建临时文件路径（不创建文件本身），登记所在目录以便清理
cn_new_tmp_file() {
  _d=$(cn_new_tmp) || return 1
  printf '%s/env.sh' "$_d"
}

# cn_table_first <表> —— 取候选表的第一条非空记录
# 候选表是多行文本，每行一条记录。表变量通常以换行开头，
# 所以要跳过空行，不能直接用 sed -n '1p'。
cn_table_first() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n '1p'
}

# cn_table_field <表> <行号> <字段号>
# 行号按「非空记录」计数，与 cn_table_first 一致。
cn_table_field() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed -n "${2}p" | cut -d'|' -f"$3"
}

# cn_yes_no <question> —— 交互确认，默认否
cn_yes_no() {
  _q="$1"
  if [ ! -t 0 ]; then return 1; fi
  printf '%s [y/N] ' "$_q" >&2
  read -r _a
  case "$_a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# cn_trim —— 去掉首尾空白
cn_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# cn_abs_path <path> —— 取绝对路径（不要求路径存在）
cn_abs_path() {
  _p="$1"
  case "$_p" in
    /*) printf '%s' "$_p" ;;
    *)  printf '%s/%s' "$(pwd)" "$_p" ;;
  esac
}

# cn_contains <haystack> <needle>
cn_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *)      return 1 ;;
  esac
}

# cn_is_root / cn_can_write <dir>
cn_can_write() {
  [ -d "$1" ] && [ -w "$1" ]
}

# cn_git_available
cn_git_available() {
  cn_have git
}

# cn_tty_available —— 是否有终端可用于交互
cn_tty_available() {
  [ -t 0 ] && [ -t 1 ]
}
