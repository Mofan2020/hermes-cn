#!/usr/bin/env bash
# PyPI / uv 加速。
#
# ===== 为什么必须改写 lock 文件 =====
#
# Hermes 的 uv.lock 里固化了 3525 处
#   https://files.pythonhosted.org/packages/<2>/<2>/<60位hex>/<文件名>
# 以及 335 处
#   source = { registry = "https://pypi.org/simple" }
#
# uv 在 `sync --frozen` / `sync --locked` 下直接按 lock 里的绝对 URL 拉制品，
# 完全不看 UV_DEFAULT_INDEX。所以只设环境变量（UV_DEFAULT_INDEX /
# UV_INDEX_URL）改不动已锁定的制品地址 —— 实测：设置阿里云索引 + 原 lock +
# 全新缓存，下载仍然全部走 files.pythonhosted.org，缓存里阿里云命中 0、
# pythonhosted 命中 1。
#
# ===== 改写方式（两种，实测只有一种能同时通过所有检查）=====
#
# 变体 A：只改 URL，registry 仍留 pypi.org
#   uv lock --check（无环境索引）  exit=0
#   uv lock --check（有环境索引）  exit=1  <-- 失败
#
# 变体 B：URL 与 registry 一起改成镜像（推荐，脚本采用）
#   uv lock --check（无环境索引）  exit=0
#   uv lock --check（有环境索引）  exit=0  <-- 通过
#
# 注意一个反直觉的点：变体 B 的 registry 必须和环境里的索引指向**同一个镜像**。
# lock 写清华、环境索引指阿里云时，uv lock --check 依然 exit=1
# （报 browser-harness 之类不可满足）。所以改写和设索引必须用同一个源。
#
# ===== 完整性 =====
# 只替换 URL 前缀，lock 里的 hash = "sha256:..." 原样保留，
# uv 下载后仍按 lock 里的哈希校验。实测 addict-2.4.0 在 pythonhosted 与
# 清华/阿里云/腾讯/华为/中科大/北外 六个源上 SHA-256 完全一致
# （249bb56bbfd3cdc2a004ea0ff4c2b6ddc84d53bc2194761636eb314d5cfa5dfc）。
# 改写不破坏哈希校验。

CN_LOCK_BACKUP_SUFFIX=".hermes-cn.bak"

# cn_lock_sample_artifact <lock 文件>
# 从 lock 里取一个真实制品的相对路径（/packages/... 形式），用于验证
# 镜像是否带齐 Hermes 所需包。
#
# 必须同时匹配原始的 files.pythonhosted.org 和改写后的镜像地址，
# 否则在已经改写的 lock 上取不到样本。
cn_lock_sample_artifact() {
  _lock="$1"
  [ -f "$_lock" ] || return 1
  _rel=$(grep -o 'https://files\.pythonhosted\.org/packages/[^"]*\.whl' "$_lock" 2>/dev/null | head -1)
  if [ -z "$_rel" ]; then
    _rel=$(grep -o 'https://[^"]*/packages/[^"]*\.whl' "$_lock" 2>/dev/null | head -1)
  fi
  if [ -z "$_rel" ]; then
    _rel=$(grep -o 'https://files\.pythonhosted\.org/packages/[^"]*' "$_lock" 2>/dev/null | head -1)
  fi
  [ -n "$_rel" ] || return 1
  # 只返回 /packages/ 之后的部分。调用方用 <packages 前缀><这里> 拼出完整地址，
  # 前缀里已经含有 /packages/，所以这里不能再重复一遍。
  printf '%s' "${_rel#*/packages/}"
}

# cn_rewrite_lock <lock 文件> <packages 前缀> <simple 索引> [github 代理前缀]
# 就地改写 lock。幂等：已经改写过的文件再次调用不会二次破坏。
# 返回 0 表示改写完成（无论是否本来就已改写）。
#
# 除了 PyPI 制品，Hermes 的 lock 里还有 4 处来自 GitHub 的依赖
# （psutil / misaki 的 git 源，以及 kittentts 的 release 直链），
# 它们同样需要走代理，否则 uv 在解析这些包时会直接卡在 GitHub 上。
cn_rewrite_lock() {
  _lock="$1"; _pkg_prefix="$2"; _index="$3"; _gh_prefix="${4:-}"
  [ -f "$_lock" ] || return 1

  # 备份原始 lock（只备份一次，保留最初的原版）
  _bak="${_lock}${CN_LOCK_BACKUP_SUFFIX}"
  if [ ! -f "$_bak" ]; then
    cp "$_lock" "$_bak" || return 1
  fi

  _tmpdir=$(cn_new_tmp) || return 1
  _tmp="$_tmpdir/lock.new"
  # URL 改写：files.pythonhosted.org/packages/ -> <镜像>/packages/
  sed "s|https://files\.pythonhosted\.org/packages/|${_pkg_prefix}|g" "$_lock" > "$_tmp" || return 1
  # registry 改写：pypi.org/simple -> <镜像 simple 索引>
  sed "s|https://pypi\.org/simple|${_index}|g" "$_tmp" > "$_tmp.2" || return 1
  # GitHub 改写：release 直链与 git 源都要走代理。
  # Hermes 的 pyproject.toml 里也直接声明了这些 GitHub 地址
  # （kittentts 的 release 直链、misaki / psutil 的 git 源），
  # 而 uv lock --check 会拿 lock 与 pyproject 互相校验：
  # 两边不一致时 uv 报「lockfile needs to be updated」。
  # 所以 pyproject.toml 必须与 lock 一起改写，保持一致。
  if [ -n "$_gh_prefix" ]; then
    sed "s|https://github\.com/|${_gh_prefix}/|g" "$_tmp.2" > "$_tmp.3" || return 1
    mv "$_tmp.3" "$_tmp.2" || return 1
  fi
  mv "$_tmp.2" "$_lock" || return 1

  # 校验：改写后不应再有 pythonhosted / pypi.org 残留
  if grep -q 'files\.pythonhosted\.org' "$_lock" 2>/dev/null; then
    cn_err "lock 改写后仍有 pythonhosted 残留：$_lock"
    return 1
  fi
  return 0
}

# cn_rewrite_pyproject <pyproject.toml> <gh 代理前缀>
# 与 cn_rewrite_lock 配套：pyproject.toml 里声明了 GitHub 地址，
# 必须和 lock 一起改写，否则 uv lock --check 报 lockfile 需要更新。
cn_rewrite_pyproject() {
  _pp="$1"; _gh_prefix="${2:-}"
  [ -f "$_pp" ] || return 1
  [ -n "$_gh_prefix" ] || return 0

  _bak="${_pp}${CN_LOCK_BACKUP_SUFFIX}"
  if [ ! -f "$_bak" ]; then
    cp "$_pp" "$_bak" || return 1
  fi

  _tmpdir=$(cn_new_tmp) || return 1
  _tmp="$_tmpdir/pp.new"
  sed "s|https://github\.com/|${_gh_prefix}/|g" "$_pp" > "$_tmp" || return 1
  cp "$_tmp" "$_pp" || return 1
  return 0
}

# cn_restore_pyproject <pyproject.toml>
cn_restore_pyproject() {
  _pp="$1"
  _bak="${_pp}${CN_LOCK_BACKUP_SUFFIX}"
  if [ ! -f "$_bak" ]; then
    return 1
  fi
  cp "$_bak" "$_pp" || return 1
  rm -f "$_bak"
  return 0
}

# cn_restore_lock <lock 文件> —— 从备份还原
cn_restore_lock() {
  _lock="$1"
  _bak="${_lock}${CN_LOCK_BACKUP_SUFFIX}"
  if [ ! -f "$_bak" ]; then
    return 1
  fi
  cp "$_bak" "$_lock" || return 1
  rm -f "$_bak"
  return 0
}

# cn_lock_is_rewritten <lock 文件> —— 是否已经指向某个镜像
cn_lock_is_rewritten() {
  _lock="$1"
  [ -f "$_lock" ] || return 1
  ! grep -q 'files\.pythonhosted\.org' "$_lock" 2>/dev/null
}

# cn_verify_lock_hash <lock 文件> <packages 前缀> <相对路径>
# 从镜像下载一个制品，比对 SHA-256 与 lock 里记录的哈希。
# 证明「改写后的镜像产物与官方逐字节一致」，即镜像确实带齐 Hermes 所需包，
# 且改写没有破坏完整性校验。
cn_verify_lock_hash() {
  _lock="$1"; _pkg_prefix="$2"; _rel="$3"
  [ -f "$_lock" ] || return 1

  # 从 lock 里读出该制品的期望哈希。
  # 用 awk 精确匹配「同一行里的 url 与 hash」，避免 sed 转义地狱。
  _base=$(basename "$_rel")
  _expected=$(awk -v base="$_base" '
    index($0, "url = \"") && index($0, base) {
      if (match($0, /hash = "sha256:[0-9a-f]+"/)) {
        # 去掉前缀 hash = "sha256:" 与结尾的引号
        s = substr($0, RSTART, RLENGTH)
        sub(/^hash = "sha256:/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    }
  ' "$_lock" 2>/dev/null)
  [ -n "$_expected" ] || return 1

  _tmpdir=$(cn_new_tmp) || return 1
  _f="$_tmpdir/artifact"
  if ! cn_http_get "${_pkg_prefix}${_rel}" -o "$_f" 2>/dev/null; then
    return 1
  fi
  _actual=$(cn_file_sha256 "$_f")
  [ -n "$_actual" ] || return 1
  [ "$_actual" = "$_expected" ]
}

# cn_uv_index_env —— 打印需要导出的 uv 索引环境变量
# UV_DEFAULT_INDEX / UV_INDEX_URL 必须与 lock 里写下的 registry 同一个源，
# 否则 uv lock --check 会失败（实测）。
cn_uv_index_env() {
  _index="$1"
  printf 'export UV_DEFAULT_INDEX=%s\n' "$_index"
  printf 'export UV_INDEX_URL=%s\n' "$_index"
  printf 'export UV_INDEX_STRATEGY=first-index\n'
  # 让 uv 信任系统证书库：部分镜像（如清华的 Let's Encrypt 新链 Root YR）
  # 在 uv 内置的 certifi 根证书里缺失，表现为
  #   error sending request ... invalid peer certificate: UnknownIssuer
  # 实测 UV_NATIVE_TLS=1 后无需 --system-certs 也能通过。
  printf 'export UV_NATIVE_TLS=1\n'
}

# cn_uv_lock_check <目录> —— 在指定目录跑 uv lock --check，验证 lock 自洽
# 需要 uv 在 PATH 里。
#
# 必须带上 UV_NATIVE_TLS=1：部分镜像（清华的 Let's Encrypt 新链 Root YR）
# 不在 uv 内置的根证书库里，表现为
#   error sending request ... invalid peer certificate: UnknownIssuer
# 让 uv 改用系统证书库即可通过（已实测）。
cn_uv_lock_check() {
  _dir="$1"
  cn_have uv || return 2
  [ -f "$_dir/uv.lock" ] || return 2
  ( cd "$_dir" && UV_NATIVE_TLS=1 timeout 600 uv lock --check >/dev/null 2>&1 )
}
