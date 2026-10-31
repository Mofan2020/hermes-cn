#!/usr/bin/env bash
# 源探测与选择。
#
# 设计要点（全部来自实测教训）：
#
# 1. 探测必须串行。
#    之前对多个 Git 镜像并发 clone，结果把可用源误判为不可用；
#    而另一轮并发 ls-remote 又把不可用源误判为可用。
#    根因是并发争抢带宽/连接数，慢源在超时窗口内拿不到资源。
#    串行探测的结果才稳定。
#
# 2. Git 源必须用真 clone / 有 refs 的 ls-remote 判定，不能只看 HTTP 200。
#    gh-proxy.net 对 info/refs 返回 200，但响应体是 JS 反爬挑战页，
#    git clone 会得到空仓库。这种源必须判为不可用。
#
# 3. 判定标准要分层：连通性 -> 语义正确性（真的拿到 refs）-> 完整性。
#    只做第一层会误判。

# 探测超时（秒）。GitCode 的 ls-remote 实测需要 55 秒，所以给足时间。
CN_PROBE_TIMEOUT="${CN_PROBE_TIMEOUT:-25}"
CN_PROBE_GIT_TIMEOUT="${CN_PROBE_GIT_TIMEOUT:-120}"
CN_PROBE_CONNECT_TIMEOUT="${CN_PROBE_CONNECT_TIMEOUT:-8}"

# 探测一个 PyPI 镜像是否可用。
# 判定方式：GET 该镜像的 simple 索引下任意一个包页面。
# 不用 HEAD（华为云对 HEAD 返回 403），不用索引根路径
# （华为云根路径返回 429、中科大返回 403）。
cn_probe_pypi() {
  _name="$1"; _index="$2"
  _pkg_url="${_index%/}/requests/"
  _code=$(cn_http_code "$_pkg_url")
  if [ "$_code" = "200" ]; then
    return 0
  fi
  # 索引根路径可用也算通过（部分镜像根路径才响应）
  _code=$(cn_http_code "${_index%/}/")
  [ "$_code" = "200" ]
}

# 探测 PyPI 镜像是否真的携带 Hermes 需要的包。
# 传入的是 Hermes uv.lock 里一个真实制品的相对路径。
cn_probe_pypi_artifact() {
  _packages_prefix="$1"; _rel_path="$2"
  _code=$(cn_http_code "${_packages_prefix}${_rel_path}")
  [ "$_code" = "200" ]
}

# 探测一个 Git 镜像。
# 判定方式：git ls-remote 必须返回非空 refs。
# 空输出（即使退出码为 0）判为不可用 —— 这正是 gh-proxy.net 的失败形态。
cn_probe_git() {
  _url="$1"
  _out=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=echo GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
    timeout "$CN_PROBE_GIT_TIMEOUT" git ls-remote "$_url" HEAD 2>/dev/null)
  _rc=$?
  if [ $_rc -ne 0 ]; then
    return 1
  fi
  # 必须有非空 ref
  [ -n "$_out" ] || return 1
  # 反爬挑战页会返回 HTML，这里做一次内容合理性检查
  case "$_out" in
    *"<html"*|*"<!DOCTYPE"*|*"window.location"*) return 1 ;;
  esac
  return 0
}

# 探测结果缓存。
# Git 镜像的 ls-remote 实测要 40~55 秒，重复探测会让 doctor 慢到不可用。
# 同一个 URL 只探一次，之后直接复用结论。
CN_GIT_PROBE_CACHE=""

_cn_probe_git_cached() {
  _url="$1"
  case " ${CN_GIT_PROBE_CACHE} " in
    *" ${_url} "*) return 0 ;;   # 已判定为可用
  esac
  if cn_probe_git "$_url"; then
    CN_GIT_PROBE_CACHE="${CN_GIT_PROBE_CACHE} ${_url}"
    return 0
  fi
  return 1
}

# 探测一个 raw 代理是否可用。
cn_probe_raw() {
  _prefix="$1"
  _code=$(cn_http_code "${_prefix%/}/scripts/install.sh")
  [ "$_code" = "200" ]
}

# 从候选表里选出第一个可用源。
# 用法：cn_select_pypi "$CN_PYPI_CANDIDATES" "$CN_PYPI_CANDIDATES_EXTRA"
# 输出：<名称>|<simple 索引>|<packages 前缀>
# 找不到时返回 1。
cn_select_pypi() {
  for _table in "$@"; do
    [ -n "$_table" ] || continue
    _oldifs="$IFS"
    IFS='
'
    for _line in $_table; do
      IFS="$_oldifs"
      [ -n "$_line" ] || continue
      case "$_line" in \#*) continue ;; esac
      _name=$(printf '%s' "$_line" | cut -d'|' -f1)
      _index=$(printf '%s' "$_line" | cut -d'|' -f2)
      _pkg=$(printf '%s' "$_line" | cut -d'|' -f3)
      [ -n "$_name" ] && [ -n "$_index" ] || continue
      cn_log "探测 PyPI 镜像：${_name}"
      if cn_probe_pypi "$_name" "$_index"; then
        printf '%s|%s|%s' "$_name" "$_index" "$_pkg"
        IFS="$_oldifs"
        return 0
      fi
      cn_warn "${_name} 不可用"
      IFS='
'
    done
    IFS="$_oldifs"
  done
  return 1
}

# 选出第一个可用的 Git 镜像。
# 输出：<名称>|<clone URL 前缀>
cn_select_git() {
  for _table in "$@"; do
    [ -n "$_table" ] || continue
    _oldifs="$IFS"
    IFS='
'
    for _line in $_table; do
      IFS="$_oldifs"
      [ -n "$_line" ] || continue
      case "$_line" in \#*) continue ;; esac
      _name=$(printf '%s' "$_line" | cut -d'|' -f1)
      _url=$(printf '%s' "$_line" | cut -d'|' -f2)
      [ -n "$_name" ] && [ -n "$_url" ] || continue
      cn_log "探测 Git 镜像：${_name}"
      if _cn_probe_git_cached "$_url"; then
        printf '%s|%s' "$_name" "$_url"
        IFS="$_oldifs"
        return 0
      fi
      cn_warn "${_name} 不可用"
      IFS='
'
    done
    IFS="$_oldifs"
  done
  return 1
}

# 选出第一个可用的 raw 代理。
# 输出：<名称>|<URL 前缀>
cn_select_raw() {
  _table="$1"
  _oldifs="$IFS"
  IFS='
'
  for _line in $_table; do
    IFS="$_oldifs"
    [ -n "$_line" ] || continue
    case "$_line" in \#*) continue ;; esac
    _name=$(printf '%s' "$_line" | cut -d'|' -f1)
    _prefix=$(printf '%s' "$_line" | cut -d'|' -f2)
    [ -n "$_name" ] && [ -n "$_prefix" ] || continue
    cn_log "探测文件下载代理：${_name}"
    if cn_probe_raw "$_prefix"; then
      printf '%s|%s' "$_name" "$_prefix"
      IFS="$_oldifs"
      return 0
    fi
    cn_warn "${_name} 不可用"
    IFS='
'
  done
  IFS="$_oldifs"
  return 1
}

# 探测一个 GitHub release / git 源代理是否可用。
#
# 判定分两层，都必须过：
#   1. release 直链必须返回真实的 zip 字节，且 sha256 与 Hermes lock 里
#      记录的哈希一致。只看 HTTP 200 会被反爬 HTML 页骗过去。
#   2. git 源必须能通过该代理拿到非空 refs。
#
# 任何一层不过，该代理就不能用于改写 lock 里的 GitHub 依赖。
cn_probe_gh_proxy() {
  _prefix="$1"
  _rel="/KittenML/KittenTTS/releases/download/0.8.1/kittentts-0.8.1-py3-none-any.whl"
  _expected="482a436c4f1f3192153710376e459ff3689517ebcda7c2b051e2fd4187b41851"

  _tmpdir=$(cn_new_tmp) || return 1
  _f="$_tmpdir/rel.bin"
  if ! cn_http_get "${_prefix}${_rel}" -o "$_f" 2>/dev/null; then
    return 1
  fi
  _actual=$(cn_file_sha256 "$_f")
  [ "$_actual" = "$_expected" ] || return 1

  # git 协议也要能用
  _out=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=echo \
    timeout "$CN_PROBE_GIT_TIMEOUT" git ls-remote "${_prefix}/giampaolo/psutil.git" HEAD 2>/dev/null)
  [ -n "$_out" ] || return 1
  case "$_out" in
    *"<html"*|*"<!DOCTYPE"*|*"window.location"*) return 1 ;;
  esac
  return 0
}

# 选出第一个可用的 GitHub 代理。
# 输出：<名称>|<URL 前缀>
cn_select_gh_release() {
  _table="$1"
  _oldifs="$IFS"
  IFS='
'
  for _line in $_table; do
    IFS="$_oldifs"
    [ -n "$_line" ] || continue
    case "$_line" in \#*) continue ;; esac
    _name=$(printf '%s' "$_line" | cut -d'|' -f1)
    _prefix=$(printf '%s' "$_line" | cut -d'|' -f2)
    [ -n "$_name" ] && [ -n "$_prefix" ] || continue
    cn_log "探测 GitHub 代理：${_name}"
    if cn_probe_gh_proxy "$_prefix"; then
      printf '%s|%s' "$_name" "$_prefix"
      IFS="$_oldifs"
      return 0
    fi
    cn_warn "${_name} 不可用"
    IFS='
'
  done
  IFS="$_oldifs"
  return 1
}
