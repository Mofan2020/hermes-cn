#!/usr/bin/env bash
# doctor：自检。逐项检查加速链路是否真的可用，并给出可执行的修复建议。
#
# 检查项：
#   1. 基础环境（curl / git / uv 是否存在）
#   2. PyPI 镜像：连通性 + 是否携带 Hermes 所需的具体制品 + 哈希一致性
#   3. lock 改写状态 + uv lock --check 是否自洽
#   4. Git 镜像：真 ls-remote 拿到 refs
#   5. origin 语义：remote.origin.url 是否仍是官方地址
#   6. insteadOf 在 Hermes 的 git 隔离下是否生效
#   7. raw / release / 二进制镜像
#
# 退出码：0 全部通过；1 存在失败项。

CN_DOCTOR_FAIL=0

doctor_ok()   { printf "  ${CN_GRN}✓${CN_RST} %s\n" "$*"; }
doctor_warn() { printf "  ${CN_YEL}!${CN_RST} %s\n" "$*"; }
doctor_fail() { printf "  ${CN_RED}✗${CN_RST} %s\n" "$*"; CN_DOCTOR_FAIL=1; }
doctor_head() { printf "\n${CN_BLD}%s${CN_RST}\n" "$*"; }

# 找出 Hermes 的安装目录
doctor_find_hermes() {
  for c in "${HERMES_HOME:-}" "$HOME/.hermes/hermes-agent" "$HOME/.hermes/hermes" \
           "/usr/local/lib/hermes-agent" "/opt/hermes-agent"; do
    [ -n "$c" ] || continue
    if [ -f "$c/uv.lock" ] || [ -d "$c/.git" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

doctor_basic() {
  doctor_head "基础环境"
  if cn_have curl; then doctor_ok "curl 可用 ($(curl --version 2>/dev/null | head -1 | cut -d' ' -f1-2))"; else doctor_fail "缺少 curl"; fi
  if cn_have git;  then doctor_ok "git 可用 ($(git --version 2>/dev/null | cut -d' ' -f3))"; else doctor_fail "缺少 git"; fi
  if cn_have uv;   then doctor_ok "uv 可用 ($(uv --version 2>/dev/null | cut -d' ' -f2))"; else doctor_warn "未找到 uv（Hermes 自带托管的 uv，不一定在 PATH）"; fi
  case "$(cn_platform)" in
    linux)  doctor_ok "平台 linux/$(cn_arch)" ;;
    darwin) doctor_ok "平台 darwin/$(cn_arch)" ;;
    *)      doctor_warn "平台未适配：$(uname -s 2>/dev/null)" ;;
  esac
}

doctor_pypi() {
  doctor_head "PyPI 镜像"
  local sel name index pkg
  sel=$(cn_select_pypi "$CN_PYPI_CANDIDATES" "$CN_PYPI_CANDIDATES_EXTRA")
  if [ -z "$sel" ]; then
    doctor_fail "没有可用的 PyPI 镜像"
    return 1
  fi
  name=$(printf '%s' "$sel" | cut -d'|' -f1)
  index=$(printf '%s' "$sel" | cut -d'|' -f2)
  pkg=$(printf '%s' "$sel" | cut -d'|' -f3)
  doctor_ok "可用镜像：${name}  (${index})"

  # 是否携带 Hermes 真正需要的包
  local hermes rel
  hermes=$(doctor_find_hermes)
  if [ -n "$hermes" ] && [ -f "$hermes/uv.lock" ]; then
    rel=$(cn_lock_sample_artifact "$hermes/uv.lock")
    if [ -n "$rel" ]; then
      if cn_probe_pypi_artifact "$pkg" "$rel"; then
        doctor_ok "携带 Hermes 所需制品：$(basename "$rel")"
        # 哈希一致性
        if cn_verify_lock_hash "$hermes/uv.lock" "$pkg" "$rel"; then
          doctor_ok "哈希一致（镜像产物与官方逐字节相同）"
        else
          doctor_warn "哈希校验未通过：镜像产物可能与官方不一致"
          CN_DOCTOR_FAIL=1
        fi
      else
        doctor_fail "该镜像缺少 Hermes 所需的制品：$(basename "$rel")"
      fi
    fi
  else
    doctor_warn "未找到 Hermes 安装目录，跳过制品完整性检查"
  fi
  return 0
}

doctor_lock() {
  doctor_head "uv.lock 改写状态"
  local hermes
  hermes=$(doctor_find_hermes)
  if [ -z "$hermes" ]; then
    doctor_warn "未找到 Hermes 安装目录，跳过"
    return 0
  fi
  local lock="$hermes/uv.lock"
  if [ ! -f "$lock" ]; then
    doctor_warn "未找到 $lock"
    return 0
  fi
  if cn_lock_is_rewritten "$lock"; then
    doctor_ok "uv.lock 已改写到镜像"
    local registry
    registry=$(grep -o 'registry = "[^"]*"' "$lock" 2>/dev/null | head -1 | sed 's/registry = "//; s/"//')
    doctor_ok "lock 内 registry：${registry}"
  else
    doctor_warn "uv.lock 仍是官方地址（执行 hermes-cn.sh apply 可改写）"
  fi

  # uv lock --check 是否自洽
  if cn_have uv; then
    if cn_uv_lock_check "$hermes"; then
      doctor_ok "uv lock --check 通过"
    else
      doctor_fail "uv lock --check 失败"
    fi
  fi
  return 0
}

doctor_git() {
  doctor_head "GitHub 镜像"
  local sel name url
  sel=$(cn_select_git "$CN_GIT_CANDIDATES")
  if [ -z "$sel" ]; then
    doctor_fail "没有可用的 GitHub 镜像"
    return 1
  fi
  name=$(printf '%s' "$sel" | cut -d'|' -f1)
  url=$(printf '%s' "$sel" | cut -d'|' -f2)
  doctor_ok "可用镜像：${name}  (${url})"

  # Gitee 回退状态
  if [ -n "${CN_GITEE_CANDIDATE:-}" ]; then
    if cn_probe_git "${CN_GITEE_CANDIDATE}"; then
      doctor_ok "Gitee 自建镜像可用：${CN_GITEE_CANDIDATE}"
    else
      doctor_warn "Gitee 自建镜像不可用：${CN_GITEE_CANDIDATE}"
    fi
  else
    doctor_warn "未配置 Gitee 自建镜像（Gitee 匿名拉取不可用，需自建后设置 CN_GITEE_CANDIDATE）"
  fi
  return 0
}

doctor_origin() {
  doctor_head "更新通道（origin 语义）"
  local hermes
  hermes=$(doctor_find_hermes)
  if [ -z "$hermes" ]; then
    doctor_warn "未找到 Hermes 安装目录，跳过"
    return 0
  fi
  if cn_git_origin_is_official "$hermes"; then
    doctor_ok "remote.origin.url 仍是官方地址（更新通道保持官方）"
  else
    local origin
    origin=$(git -C "$hermes" config --get remote.origin.url 2>/dev/null)
    if [ -z "$origin" ]; then
      doctor_warn "该目录不是 git 仓库或没有 origin"
    else
      doctor_fail "remote.origin.url 已非官方：${origin}"
    fi
  fi
  return 0
}

doctor_instead_of() {
  doctor_head "Git 传输层改写"
  local hermes sel url
  hermes=$(doctor_find_hermes)
  if [ -z "$hermes" ]; then
    doctor_warn "未找到 Hermes 安装目录，跳过"
    return 0
  fi
  sel=$(cn_select_git "$CN_GIT_CANDIDATES")
  [ -n "$sel" ] || return 0
  url=$(printf '%s' "$sel" | cut -d'|' -f2)
  if cn_git_verify_instead_of "$hermes" "$url"; then
    doctor_ok "insteadOf 在 Hermes 的 git 隔离下生效"
  else
    doctor_warn "insteadOf 未生效或尚未配置（执行 hermes-cn.sh apply 可配置）"
  fi
  return 0
}

doctor_raw() {
  doctor_head "raw / release / 二进制"
  local sel name prefix
  sel=$(cn_select_raw "$CN_RAW_CANDIDATES")
  if [ -n "$sel" ]; then
    name=$(printf '%s' "$sel" | cut -d'|' -f1)
    doctor_ok "raw 代理可用：${name}"
  else
    doctor_fail "没有可用的 raw 代理"
  fi

  # GitHub 代理（lock 里 4 处 GitHub 依赖要走它）
  sel=$(cn_select_gh_release "$CN_GH_PROXY_CANDIDATES") || sel=""
  if [ -n "$sel" ]; then
    name=$(printf '%s' "$sel" | cut -d'|' -f1)
    doctor_ok "GitHub 代理可用：${name}（release 字节与 git 协议均已校验）"
  else
    doctor_fail "没有可用的 GitHub 代理，lock 里的 GitHub 依赖会拉取失败"
  fi

  if [ "$(cn_http_code "${CN_OFFICIAL_ASSETS}/releases/stable/release-candidates.json")" = "200" ]; then
    doctor_ok "官方 release 指针可用（hermes-assets 兜底）"
  else
    doctor_warn "官方 release 指针不可达"
  fi

  if [ "$(cn_http_code "${CN_BIN_NPM_REGISTRY}/")" = "200" ]; then
    doctor_ok "npm 镜像可用（npmmirror）"
  else
    doctor_warn "npm 镜像不可达"
  fi
  if [ "$(cn_http_code "${CN_BIN_UV_MIRRORS_HUAWEI}/0.13.5/uv-aarch64-apple-darwin.tar.gz")" = "200" ]; then
    doctor_ok "uv 二进制镜像可用（华为云）"
  else
    doctor_warn "uv 二进制镜像不可达（install.sh 自带 hermes-assets 兜底）"
  fi
  return 0
}

# cn_doctor —— 跑完整自检
cn_doctor() {
  CN_DOCTOR_FAIL=0
  printf "${CN_BLD}hermes-cn 自检${CN_RST}\n"
  doctor_basic
  doctor_pypi
  doctor_lock
  doctor_git
  doctor_origin
  doctor_instead_of
  doctor_raw
  printf "\n"
  if [ "$CN_DOCTOR_FAIL" -eq 0 ]; then
    printf "${CN_GRN}全部检查通过。${CN_RST}\n"
    return 0
  fi
  printf "${CN_YEL}存在失败项，见上方 ✗ 标记。${CN_RST}\n"
  return 1
}
