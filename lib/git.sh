#!/usr/bin/env bash
# GitHub 加速。
#
# ===== 关键约束：不能改 remote.origin.url =====
#
# Hermes 内部有两处判定「这是不是官方仓库」：
#   hermes_cli/update_channel.py:167  _tracks_official_origin()
#       直接读 git config 文件里的 remote.origin.url
#   hermes_cli/source_releases.py:25  source_repository()
#       用 git config --get remote.origin.url 匹配 _GITHUB_ORIGIN
#
# 一旦 remote.origin.url 被换成镜像地址，更新通道会掉成非官方，
# release 解析随之降级。所以镜像改写只能发生在传输层。
#
# ===== 为什么不能用环境变量注入 insteadOf =====
#
# hermes_cli/_subprocess_compat.py:429 的 noninteractive_git_env() 会：
#   - 把 GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM 指向 /dev/null
#   - 设置 GIT_CONFIG_NOSYSTEM=1
#   - 在 460-465 行丢掉 caller 注入的 GIT_CONFIG_COUNT / GIT_CONFIG_KEY_*
#
# 所以纯环境变量的 insteadOf 对 Hermes 内部 git 无效。
#
# 但 repo-local config 仍然会被读：git config --local url."...".insteadOf
# 在同样的隔离下依然生效（已实测）。
#
# ===== 本模块的做法 =====
# 1. 在目标仓库里写 repo-local 的 insteadOf，把 GitHub 地址重写到镜像。
#    remote.origin.url 保持官方地址不动。
# 2. 提供 --global 模式，给脚本自身和用户直接跑的 git 命令用
#    （写全局 config，但同样不改任何仓库的 origin）。

# cn_git_local_instead_of <仓库目录> <上游地址> <镜像地址>
# 只写 repo-local config，不碰 remote.origin.url。
#
# insteadOf 是「前缀」规则：命中的前缀会被替换成镜像地址 + 剩余部分。
# 因为上游地址和镜像地址在这里都是完整仓库地址、长度一致，
# 剩余部分为空，替换结果就是镜像地址本身。
cn_git_local_instead_of() {
  _repo="$1"; _upstream="$2"; _mirror="$3"
  [ -d "$_repo/.git" ] || return 1
  git -C "$_repo" config --local "url.${_mirror}".insteadOf "${_upstream}" || return 1
  return 0
}

# cn_git_global_instead_of <上游前缀> <镜像前缀>
# 写全局 config。用于脚本自身发起的 git、以及用户在加速环境里手敲的 git。
#
# 注意：前缀必须是「仓库级」而不是「https://github.com/」这种站点级。
# 站点级改写会把用户所有 GitHub 仓库（包括私有的、别的项目的）统统
# 重定向到同一个镜像路径上，导致大量仓库 404。
# 所以这里只改写 Hermes 官方仓库这一条精确地址。
cn_git_global_instead_of() {
  _upstream="$1"; _mirror="$2"
  git config --global "url.${_mirror}".insteadOf "${_upstream}" || return 1
  return 0
}

# cn_git_unset_global_instead_of <上游前缀> <镜像前缀>
cn_git_unset_global_instead_of() {
  _upstream="$1"; _mirror="$2"
  git config --global --unset-all "url.${_mirror}.insteadOf" 2>/dev/null || true
  return 0
}

# cn_git_origin_is_official <仓库目录>
# 检查 remote.origin.url 是否仍是官方 GitHub 地址。
# 这是更新通道能否保持「官方」的关键，doctor 必须检查这一项。
cn_git_origin_is_official() {
  _repo="$1"
  _origin=$(git -C "$_repo" config --get remote.origin.url 2>/dev/null)
  [ -n "$_origin" ] || return 1
  case "$_origin" in
    https://github.com/NousResearch/hermes-agent.git) return 0 ;;
    https://github.com/NousResearch/hermes-agent)     return 0 ;;
    git@github.com:NousResearch/hermes-agent.git)      return 0 ;;
    ssh://git@github.com/NousResearch/hermes-agent.git) return 0 ;;
  esac
  return 1
}

# cn_git_verify_instead_of <仓库目录>
# 验证 repo-local insteadOf 生效：在 Hermes 那样的 git 隔离环境下
# （GIT_CONFIG_GLOBAL=/dev/null、GIT_CONFIG_NOSYSTEM=1），
# ls-remote 必须仍然走到镜像并返回非空 refs。
cn_git_verify_instead_of() {
  _repo="$1"; _mirror_url="$2"
  _out=$( cd "$_repo" && \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    timeout "$CN_PROBE_GIT_TIMEOUT" \
    git ls-remote origin HEAD 2>/dev/null )
  [ -n "$_out" ] || return 1
  case "$_out" in
    *"<html"*|*"<!DOCTYPE"*) return 1 ;;
  esac
  return 0
}

# cn_git_clone_mirror <镜像前缀> <目标目录> —— 用镜像 clone 官方仓库
# 用于首次安装（install.sh 场景）。
cn_git_clone_mirror() {
  _mirror_url="$1"; _dest="$2"
  GIT_TERMINAL_PROMPT=0 timeout 1800 \
    git clone --filter=blob:none "$_mirror_url" "$_dest"
}

# cn_git_fetch_origin <仓库目录> —— 在镜像改写下 fetch origin
cn_git_fetch_origin() {
  _repo="$1"
  git -C "$_repo" fetch --quiet origin 2>/dev/null
}
