#!/usr/bin/env bash
#
# hermes-cn.sh —— Hermes 大陆网络加速
#
# 用法：
#   ./hermes-cn.sh              进入加速环境（交互 shell）
#   ./hermes-cn.sh run <命令>   在加速环境里跑一条命令
#   ./hermes-cn.sh doctor       自检
#   ./hermes-cn.sh apply        改写 lock + 配置 git 传输层（持久生效）
#   ./hermes-cn.sh restore      撤销 apply 的改动
#   ./hermes-cn.sh install      用镜像安装 Hermes
#   ./hermes-cn.sh env          打印可 source 的环境变量
#
# 项目：https://github.com/Mofan2020/hermes-cn
# 许可证：MIT

set -u

CN_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/common.sh
. "$CN_SELF_DIR/lib/common.sh"
# shellcheck source=lib/sources.sh
. "$CN_SELF_DIR/lib/sources.sh"
# shellcheck source=lib/probe.sh
. "$CN_SELF_DIR/lib/probe.sh"
# shellcheck source=lib/pypi.sh
. "$CN_SELF_DIR/lib/pypi.sh"
# shellcheck source=lib/git.sh
. "$CN_SELF_DIR/lib/git.sh"
# shellcheck source=lib/env.sh
. "$CN_SELF_DIR/lib/env.sh"
# shellcheck source=lib/doctor.sh
. "$CN_SELF_DIR/lib/doctor.sh"

CN_VERSION="1.0.0"

cn_usage() {
  cat <<'EOF'
hermes-cn —— Hermes 大陆网络加速

用法：
  hermes-cn.sh [命令] [参数...]

命令：
  (无)              进入加速环境（交互 shell），退出即恢复
  run <命令>        在加速环境里执行一条命令并原样返回退出码
  env               打印可 source 的环境变量（eval "$(hermes-cn.sh env)"）
  doctor            自检：检查各镜像可用性、lock 完整性、origin 语义
  apply             改写 uv.lock 指向镜像 + 配置 git 传输层改写（持久）
  restore           撤销 apply 的所有改动，还原 uv.lock 与 git 配置
  install           用镜像全新安装 Hermes 到 ~/.hermes/hermes-agent
  help              显示本帮助

选项：
  --pypi-mirror <名>   跳过探测，强制使用指定 PyPI 镜像
  --git-mirror <前缀>  跳过探测，强制使用指定 Git 镜像
  --no-probe           不做探测，直接用默认首选源
  --yes, -y            不询问，直接执行
  --version, -v        显示版本

示例：
  ./hermes-cn.sh doctor
  ./hermes-cn.sh run hermes update
  ./hermes-cn.sh run bash scripts/install.sh
  eval "$(./hermes-cn.sh env)" && hermes update
EOF
}

# ---------- 参数解析 ----------
CN_FORCE_PYPI=""
CN_FORCE_GIT=""
CN_NO_PROBE=0
CN_ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pypi-mirror) CN_FORCE_PYPI="${2:-}"; shift 2 ;;
    --git-mirror)  CN_FORCE_GIT="${2:-}"; shift 2 ;;
    --no-probe)    CN_NO_PROBE=1; shift ;;
    --yes|-y)      CN_ASSUME_YES=1; shift ;;
    --version|-v)  echo "hermes-cn ${CN_VERSION}"; exit 0 ;;
    help|-h|--help) cn_usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "未知选项：$1" >&2; cn_usage >&2; exit 2 ;;
    *) break ;;
  esac
done

CN_CMD="${1:-shell}"
[ $# -gt 0 ] && shift

# ---------- 选源 ----------
CN_PYPI_NAME=""; CN_PYPI_INDEX=""; CN_PYPI_PKG=""
CN_GIT_NAME=""; CN_GIT_URL=""
CN_RAW_NAME=""; CN_RAW_PREFIX=""
CN_GH_PROXY_NAME=""; CN_GH_PROXY_PREFIX=""

cn_resolve_sources() {
  # ---- PyPI ----
  if [ -n "$CN_FORCE_PYPI" ]; then
    local line
    line=$(printf '%s\n%s\n' "$CN_PYPI_CANDIDATES" "$CN_PYPI_CANDIDATES_EXTRA" |
           grep "|$CN_FORCE_PYPI|" | head -1)
    if [ -n "$line" ]; then
      CN_PYPI_NAME=$(printf '%s' "$line" | cut -d'|' -f1)
      CN_PYPI_INDEX=$(printf '%s' "$line" | cut -d'|' -f2)
      CN_PYPI_PKG=$(printf '%s' "$line" | cut -d'|' -f3)
      cn_log "强制使用 PyPI 镜像：${CN_PYPI_NAME}"
    else
      cn_die "未知的 PyPI 镜像名：${CN_FORCE_PYPI}"
    fi
  elif [ "$CN_NO_PROBE" -eq 1 ]; then
    CN_PYPI_NAME=$(cn_table_field "$CN_PYPI_CANDIDATES" 1 1)
    CN_PYPI_INDEX=$(cn_table_field "$CN_PYPI_CANDIDATES" 1 2)
    CN_PYPI_PKG=$(cn_table_field "$CN_PYPI_CANDIDATES" 1 3)
    cn_log "跳过探测，使用默认 PyPI 镜像：${CN_PYPI_NAME}"
  else
    cn_step "选择 PyPI 镜像"
    local sel
    sel=$(cn_select_pypi "$CN_PYPI_CANDIDATES" "$CN_PYPI_CANDIDATES_EXTRA") ||
      cn_die "没有可用的 PyPI 镜像，请检查网络"
    CN_PYPI_NAME=$(printf '%s' "$sel" | cut -d'|' -f1)
    CN_PYPI_INDEX=$(printf '%s' "$sel" | cut -d'|' -f2)
    CN_PYPI_PKG=$(printf '%s' "$sel" | cut -d'|' -f3)
  fi

  # ---- Git ----
  if [ -n "$CN_FORCE_GIT" ]; then
    CN_GIT_NAME="自定义"
    CN_GIT_URL="$CN_FORCE_GIT"
  elif [ "$CN_NO_PROBE" -eq 1 ]; then
    CN_GIT_NAME=$(cn_table_field "$CN_GIT_CANDIDATES" 1 1)
    CN_GIT_URL=$(cn_table_field "$CN_GIT_CANDIDATES" 1 2)
  else
    cn_step "选择 GitHub 镜像"
    local sel
    sel=$(cn_select_git "$CN_GIT_CANDIDATES") || {
      cn_warn "没有可用的 GitHub 镜像，Git 操作将走官方地址"
      CN_GIT_NAME=""; CN_GIT_URL=""
    }
    if [ -n "$sel" ]; then
      CN_GIT_NAME=$(printf '%s' "$sel" | cut -d'|' -f1)
      CN_GIT_URL=$(printf '%s' "$sel" | cut -d'|' -f2)
    fi
  fi

  # ---- GitHub release 直链代理 ----
  local sel
  sel=$(cn_select_gh_release "$CN_GH_PROXY_CANDIDATES") || sel=""
  if [ -n "$sel" ]; then
    CN_GH_PROXY_NAME=$(printf '%s' "$sel" | cut -d'|' -f1)
    CN_GH_PROXY_PREFIX=$(printf '%s' "$sel" | cut -d'|' -f2)
  else
    cn_warn "没有可用的 GitHub release 代理，lock 中的 GitHub 直链依赖可能拉取失败"
  fi

  # ---- raw ----
  if [ "$CN_NO_PROBE" -eq 1 ]; then
    CN_RAW_NAME=$(cn_table_field "$CN_RAW_CANDIDATES" 1 1)
    CN_RAW_PREFIX=$(cn_table_field "$CN_RAW_CANDIDATES" 1 2)
  else
    sel=$(cn_select_raw "$CN_RAW_CANDIDATES") || sel=""
    if [ -n "$sel" ]; then
      CN_RAW_NAME=$(printf '%s' "$sel" | cut -d'|' -f1)
      CN_RAW_PREFIX=$(printf '%s' "$sel" | cut -d'|' -f2)
    fi
  fi
}

# ---------- 环境组装 ----------
# 生成一段可 eval 的环境变量脚本
cn_build_env() {
  _out="$1"
  {
    if [ -n "$CN_PYPI_INDEX" ]; then
      cn_uv_index_env "$CN_PYPI_INDEX"
    fi
    if [ -n "$CN_RAW_PREFIX" ]; then
      cn_env_raw "$CN_RAW_PREFIX"
    fi
    cn_env_binaries
    if [ -n "$CN_GIT_URL" ]; then
      cn_git_env_snippet "$CN_OFFICIAL_ORIGIN" "$CN_GIT_URL"
    fi
    printf 'export HERMES_CN_ENABLED=1\n'
    printf 'export HERMES_CN_PYPI_MIRROR=%s\n' "$CN_PYPI_NAME"
    printf 'export HERMES_CN_GIT_MIRROR=%s\n' "$CN_GIT_NAME"
  } > "$_out"
}

# 在加速环境里执行命令
cn_run_in_env() {
  _script=$(cn_new_tmp_file) || return 1
  cn_build_env "$_script"
  # shellcheck disable=SC1090
  . "$_script"
  if [ -n "$CN_GIT_URL" ]; then
    export HERMES_CN_GIT_URL="$CN_GIT_URL"
  fi
  export HERMES_CN_OFFICIAL_ORIGIN="$CN_OFFICIAL_ORIGIN"
  "$@"
}

# ---------- 各子命令 ----------
cmd_shell() {
  cn_resolve_sources
  cn_step "加速环境已就绪"
  printf "  PyPI 镜像 : %s (%s)\n" "$CN_PYPI_NAME" "$CN_PYPI_INDEX"
  [ -n "$CN_GIT_NAME" ] && printf "  Git 镜像  : %s (%s)\n" "$CN_GIT_NAME" "$CN_GIT_URL"
  [ -n "$CN_RAW_NAME" ] && printf "  raw 代理  : %s\n" "$CN_RAW_NAME"
  printf "  ${CN_DIM}提示：直接运行 hermes update、bash scripts/install.sh 或任意联网命令即可。${CN_RST}\n\n"

  _script=$(cn_new_tmp_file) || return 1
  cn_build_env "$_script"
  # shellcheck disable=SC1090
  . "$_script"
  export HERMES_CN_OFFICIAL_ORIGIN="$CN_OFFICIAL_ORIGIN"
  export HERMES_CN_GIT_URL="${CN_GIT_URL:-}"

  ${SHELL:-/bin/bash} -i
}

cmd_run() {
  if [ $# -eq 0 ]; then
    cn_err "run 需要一条命令"
    return 2
  fi
  cn_resolve_sources
  cn_run_in_env "$@"
}

cmd_env() {
  cn_resolve_sources
  _script=$(cn_new_tmp_file) || return 1
  cn_build_env "$_script"
  cat "$_script"
}

cmd_doctor() {
  cn_doctor
}

cmd_apply() {
  cn_resolve_sources

  local hermes
  hermes=$(doctor_find_hermes) || hermes=""
  if [ -z "$hermes" ]; then
    cn_die "未找到 Hermes 安装目录。请先安装 Hermes，或用 HERMES_HOME 指定路径。"
  fi

  cn_step "改写 uv.lock → ${CN_PYPI_NAME}"
  local lock
  for lock in "$hermes/uv.lock" "$hermes/pm/uv.lock"; do
    [ -f "$lock" ] || continue
    if cn_rewrite_lock "$lock" "$CN_PYPI_PKG" "$CN_PYPI_INDEX" "$CN_GH_PROXY_PREFIX"; then
      cn_ok "已改写：${lock}"
    else
      cn_die "改写失败：${lock}"
    fi
  done

  # pyproject.toml 里也声明了 GitHub 地址，必须与 lock 一起改写，
  # 否则 uv lock --check 会报「lockfile needs to be updated」。
  cn_step "改写 pyproject.toml 中的 GitHub 地址"
  for pp in "$hermes/pyproject.toml" "$hermes/pm/pyproject.toml"; do
    [ -f "$pp" ] || continue
    if cn_rewrite_pyproject "$pp" "$CN_GH_PROXY_PREFIX"; then
      cn_ok "已改写：${pp}"
    else
      cn_warn "改写失败：${pp}"
    fi
  done

  # 校验自洽
  cn_log "校验 uv lock --check ..."
  if cn_uv_lock_check "$hermes"; then
    cn_ok "uv lock --check 通过"
  else
    cn_warn "uv lock --check 未通过，请执行 hermes-cn.sh doctor 查看详情"
  fi

  cn_step "配置 Git 传输层改写 → ${CN_GIT_NAME}"
  if [ -n "$CN_GIT_URL" ]; then
    # repo-local insteadOf：Hermes 内部 git 会丢弃环境变量注入，
    # 但 repo-local config 仍然生效。
    if cn_git_local_instead_of "$hermes" "$CN_OFFICIAL_ORIGIN" "$CN_GIT_URL"; then
      cn_ok "已写入 repo-local insteadOf（仅影响本仓库）"
    else
      cn_warn "写入 repo-local insteadOf 失败"
    fi
    # 全局 config：仅改写 Hermes 官方仓库这一条精确地址，
    # 不做站点级改写，避免影响用户自己的其它 GitHub 仓库。
    cn_git_global_instead_of "$CN_OFFICIAL_ORIGIN" "$CN_GIT_URL" &&
      cn_ok "已写入全局 insteadOf（仅 Hermes 官方仓库）"
  fi

  cn_step "校验 origin 语义"
  if cn_git_origin_is_official "$hermes"; then
    cn_ok "remote.origin.url 保持官方地址（更新通道不受影响）"
  else
    cn_warn "remote.origin.url 不是官方地址：$(git -C "$hermes" config --get remote.origin.url 2>/dev/null)"
  fi

  printf "\n${CN_GRN}加速配置已生效。${CN_RST}\n"
  printf "  现在可以直接运行： hermes update\n"
  printf "  撤销请执行： hermes-cn.sh restore\n"
}

cmd_restore() {
  local hermes
  hermes=$(doctor_find_hermes) || hermes=""
  if [ -z "$hermes" ]; then
    cn_die "未找到 Hermes 安装目录。"
  fi

  cn_step "还原 uv.lock"
  local lock restored=0
  for lock in "$hermes/uv.lock" "$hermes/pm/uv.lock"; do
    if [ -f "${lock}${CN_LOCK_BACKUP_SUFFIX}" ]; then
      if cn_restore_lock "$lock"; then
        cn_ok "已还原：${lock}"
        restored=1
      fi
    fi
  done
  local pp
  for pp in "$hermes/pyproject.toml" "$hermes/pm/pyproject.toml"; do
    if [ -f "${pp}${CN_LOCK_BACKUP_SUFFIX}" ]; then
      cn_restore_pyproject "$pp" && cn_ok "已还原：${pp}" && restored=1
    fi
  done
  [ "$restored" -eq 1 ] || cn_warn "没有需要还原的 lock 备份"

  cn_step "移除 Git 传输层改写"
  git -C "$hermes" config --local --unset-all "url.${CN_GIT_URL}.insteadOf" 2>/dev/null || true
  git config --global --unset-all "url.${CN_GIT_URL}.insteadOf" 2>/dev/null || true
  cn_ok "已移除 insteadOf 配置"

  printf "\n${CN_GRN}已恢复到官方直连状态。${CN_RST}\n"
}

cmd_install() {
  cn_resolve_sources
  local target="${1:-$HOME/.hermes/hermes-agent}"
  cn_step "从 ${CN_GIT_NAME} 安装 Hermes → ${target}"
  if [ -e "$target" ]; then
    cn_warn "目标目录已存在：${target}"
    if [ "$CN_ASSUME_YES" -eq 0 ] && ! cn_yes_no "是否继续？（会覆盖）"; then
      cn_die "已取消"
    fi
  fi
  local parent
  parent=$(dirname "$target")
  mkdir -p "$parent" || cn_die "无法创建目录：$parent"

  if ! cn_git_clone_mirror "$CN_GIT_URL" "$target"; then
    cn_die "clone 失败：${CN_GIT_URL}"
  fi
  cn_ok "已 clone 到 ${target}"

  # 关键：origin 必须保持官方地址，否则更新通道掉成非官方
  git -C "$target" remote set-url origin "$CN_OFFICIAL_ORIGIN" &&
    cn_ok "origin 已设为官方地址（更新通道保持官方）"

  # 传输层改写
  if [ -n "$CN_GIT_URL" ]; then
    cn_git_local_instead_of "$target" "$CN_OFFICIAL_ORIGIN" "$CN_GIT_URL" &&
      cn_ok "已写入 repo-local insteadOf（仅影响本仓库）"
  fi

  # lock 改写
  cn_step "改写 uv.lock → ${CN_PYPI_NAME}"
  local lock
  for lock in "$target/uv.lock" "$target/pm/uv.lock"; do
    [ -f "$lock" ] || continue
    cn_rewrite_lock "$lock" "$CN_PYPI_PKG" "$CN_PYPI_INDEX" "$CN_GH_PROXY_PREFIX" && cn_ok "已改写：${lock}"
  done
  local pp
  for pp in "$target/pyproject.toml" "$target/pm/pyproject.toml"; do
    [ -f "$pp" ] || continue
    cn_rewrite_pyproject "$pp" "$CN_GH_PROXY_PREFIX" && cn_ok "已改写：${pp}"
  done

  printf "\n${CN_GRN}安装完成。${CN_RST}\n"
  printf "  下一步： cd %s && hermes update\n" "$target"
}

# ---------- 入口 ----------
case "$CN_CMD" in
  shell)  cmd_shell ;;
  run)    cmd_run "$@" ;;
  env)    cmd_env ;;
  doctor) cmd_doctor ;;
  apply)  cmd_apply ;;
  restore) cmd_restore ;;
  install) cmd_install "$@" ;;
  *)
    cn_err "未知命令：${CN_CMD}"
    cn_usage >&2
    exit 2
    ;;
esac
