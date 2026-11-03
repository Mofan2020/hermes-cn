#!/usr/bin/env bash
# 通用 GitHub 加速环境。
#
# 思路参考 Steam++（Watt Toolkit）这类工具用到的加速节点。
# 这些节点分两种玩法：
#
#   前缀代理 —— 地址变成 https://<节点>/https://github.com/owner/repo，
#               原始地址整段接在节点后面。gh-proxy.com、ghproxy.net 都是这种。
#   整站镜像 —— 地址变成 https://<节点>/github.com/owner/repo，
#               去掉协议头，整站镜像。gitclone.com 是这种。
#
# 流量走节点自己的服务器，证书也是节点自己的正规证书，
# 不涉及自签证书那套麻烦事；节点证书有问题，探测时会被剔掉。
#
# 每个节点都实测三件事，缺一不可：
#   1. 能不能连上，证书有没有问题
#   2. 取回来的东西是不是真文件（比对哈希，防止拿到反爬网页）
#   3. git 协议能不能用
#
# 只有 git 协议能用的节点，才会去改写 github.com 前缀，
# 否则 clone 会被带过去然后失败。
#
# 加速环境做三件事：
#   1. 挨个探测候选节点，选出当前真正能用的（带故障转移）
#   2. 写全局 git 配置，把 GitHub 地址换成节点地址
#   3. 给别的工具（curl、npm 等）准备一份环境变量
#
# 私有仓库不受影响：访问私有仓库必须带凭据，地址形如
# https://user@github.com/... ，跟这里改写的 https://github.com/ 对不上。

CN_ACCEL_DIR="${CN_ACCEL_DIR:-$HOME/.hermes-cn/accel}"
CN_ACCEL_STATE="$CN_ACCEL_DIR/node"
CN_ACCEL_ENV_FILE="$CN_ACCEL_DIR/env.sh"

# ---------- 候选节点 ----------
# 格式：<名称>|<github.com 的替换地址>|<下载域名的替换前缀>|<探测地址>
#
# github.com 的替换地址：把 https://github.com/ 换成它。
# 下载域名的替换前缀：把 <原始地址去掉 https://> 接在它后面，
#                     留空表示这个节点不代理下载域名（整站镜像一般不行）。
# 探测地址：拿一个很小的公开仓库测节点通不通。
#           节点是现拉的，用大仓库探测要等很久，小仓库几秒就出结果。
#
# 2026-11-03 实测：
#   gh-proxy.com   下载可用、git 可用
#   gh-proxy.cc    下载可用、git 可用
#   ghproxy.net    下载可用、git 时好时坏
#   gitclone.com   git 可用（整站镜像，下载域名不支持）
#   其余候选当天不通，但过段时间可能恢复，所以仍然留着，探测时自动跳过。
#
# 想加自己的节点，写进 ~/.hermes-cn/accel/nodes.txt，
# 一行一个「名称|替换地址|下载前缀|探测地址」，会和内置的一起探测。
CN_ACCEL_NODES="
gh-proxy.com|https://gh-proxy.com/https://github.com/|https://gh-proxy.com/https://|https://gh-proxy.com/https://github.com/octocat/Hello-World.git
gh-proxy.cc|https://gh-proxy.cc/https://github.com/|https://gh-proxy.cc/https://|https://gh-proxy.cc/https://github.com/octocat/Hello-World.git
ghproxy.net|https://ghproxy.net/https://github.com/|https://ghproxy.net/https://|https://ghproxy.net/https://github.com/octocat/Hello-World.git
www.gh-proxy.cc|https://www.gh-proxy.cc/https://github.com/|https://www.gh-proxy.cc/https://|https://www.gh-proxy.cc/https://github.com/octocat/Hello-World.git
gh-proxy.net|https://gh-proxy.net/https://github.com/|https://gh-proxy.net/https://|https://gh-proxy.net/https://github.com/octocat/Hello-World.git
ghfast.top|https://ghfast.top/https://github.com/|https://ghfast.top/https://|https://ghfast.top/https://github.com/octocat/Hello-World.git
gh.ddlc.top|https://gh.ddlc.top/https://github.com/|https://gh.ddlc.top/https://|https://gh.ddlc.top/https://github.com/octocat/Hello-World.git
github.moeyy.xyz|https://github.moeyy.xyz/https://github.com/|https://github.moeyy.xyz/https://|https://github.moeyy.xyz/https://github.com/octocat/Hello-World.git
gh.api.99988866.xyz|https://gh.api.99988866.xyz/https://github.com/|https://gh.api.99988866.xyz/https://|https://gh.api.99988866.xyz/https://github.com/octocat/Hello-World.git
ghproxy.cn|https://ghproxy.cn/https://github.com/|https://ghproxy.cn/https://|https://ghproxy.cn/https://github.com/octocat/Hello-World.git
ghp.ci|https://ghp.ci/https://github.com/|https://ghp.ci/https://|https://ghp.ci/https://github.com/octocat/Hello-World.git
ghproxy.homeboyc.cn|https://ghproxy.homeboyc.cn/https://github.com/|https://ghproxy.homeboyc.cn/https://|https://ghproxy.homeboyc.cn/https://github.com/octocat/Hello-World.git
gh.llkk.cc|https://gh.llkk.cc/https://github.com/|https://gh.llkk.cc/https://|https://gh.llkk.cc/https://github.com/octocat/Hello-World.git
gitclone.com|https://gitclone.com/github.com/||https://gitclone.com/github.com/octocat/Hello-World.git
"

# 会改写的地址。github.com 只在节点支持 git 时才改。
CN_ACCEL_TARGETS_GIT="https://github.com/"
CN_ACCEL_TARGETS_DOWNLOAD="https://raw.githubusercontent.com/ https://codeload.github.com/ https://objects.githubusercontent.com/ https://release-assets.githubusercontent.com/"

# 探测样本：一个已知哈希的 release 文件（确认返回的是真文件，不是反爬网页）
CN_ACCEL_SAMPLE_REL="https://github.com/KittenML/KittenTTS/releases/download/0.8.1/kittentts-0.8.1-py3-none-any.whl"
CN_ACCEL_SAMPLE_REL_SHA="482a436c4f1f3192153710376e459ff3689517ebcda7c2b051e2fd4187b41851"

# ---------- 小工具 ----------

cn_accel_have() { command -v "$1" >/dev/null 2>&1; }

cn_accel_state_dir() { mkdir -p "$CN_ACCEL_DIR" 2>/dev/null || true; }

cn_accel_user_nodes() {
  local f="$CN_ACCEL_DIR/nodes.txt"
  [ -f "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | grep '|'
}

cn_accel_all_nodes() {
  printf '%s\n%s\n' "$CN_ACCEL_NODES" "$(cn_accel_user_nodes)"
}

# 节点能不能下载文件：拿一个已知哈希的样本比对。
# 返回 0 能下载，1 不能。
cn_accel_probe_download() {
  _dl_prefix="$1"
  [ -n "$_dl_prefix" ] || return 1
  _tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-cn-node.XXXXXX") || return 1
  _url="${_dl_prefix}${CN_ACCEL_SAMPLE_REL#https://}"
  _code=$(curl -sSL --connect-timeout 8 --max-time 90 -o "$_tmp/rel.bin" -w '%{http_code}' "$_url" 2>/dev/null)
  if [ "$_code" != "200" ]; then
    find "$_tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$_tmp" 2>/dev/null
    return 1
  fi
  _got=$(shasum -a 256 "$_tmp/rel.bin" 2>/dev/null | cut -d' ' -f1)
  find "$_tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$_tmp" 2>/dev/null
  [ "$_got" = "$CN_ACCEL_SAMPLE_REL_SHA" ]
}

# 节点能不能用 git：ls-remote 必须拿到非空 refs。
cn_accel_probe_git() {
  _probe_url="$1"
  [ -n "$_probe_url" ] || return 1
  _out=$(GIT_TERMINAL_PROMPT=0 timeout 90 git ls-remote "$_probe_url" HEAD 2>/dev/null)
  printf '%s' "$_out" | grep -qE '^[0-9a-f]{40}'
}

# ---------- 节点探测 ----------

# 判断一个节点能不能用。
# 返回：0 完全可用；2 只能下载；1 不可用
# 原因写在 CN_ACCEL_PROBE_NOTE 里。
cn_accel_probe_node() {
  _name="$1"; _gh_base="$2"; _dl_prefix="$3"; _probe_url="$4"
  CN_ACCEL_PROBE_NOTE=""

  # 1) 连通性与证书
  _tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-cn-node.XXXXXX") || return 1
  # 从替换地址里取出节点主机名。
  # 去掉协议头，再去掉路径部分。
  _node_host="${_gh_base#*://}"
  _node_host="${_node_host%%/*}"
  curl -sS -o /dev/null --connect-timeout 8 --max-time 25 -v "https://${_node_host}/" 2>"$_tmp/tls.log"
  if grep -qiE 'SSL certificate problem|self.signed|certificate verify failed' "$_tmp/tls.log" 2>/dev/null; then
    CN_ACCEL_PROBE_NOTE="证书有问题"
    find "$_tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$_tmp" 2>/dev/null
    return 1
  fi
  if ! grep -qE 'Connected to|SSL connection using|Server certificate' "$_tmp/tls.log" 2>/dev/null &&
     ! grep -qE 'HTTP/[0-9.]+ [0-9]{3}' "$_tmp/tls.log" 2>/dev/null; then
    CN_ACCEL_PROBE_NOTE="连不上"
    find "$_tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$_tmp" 2>/dev/null
    return 1
  fi
  find "$_tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$_tmp" 2>/dev/null

  # 2) 下载是不是真的
  if ! cn_accel_probe_download "$_dl_prefix"; then
    CN_ACCEL_PROBE_NOTE="下载不通"
    return 1
  fi

  # 3) git 协议
  if cn_accel_probe_git "$_probe_url"; then
    CN_ACCEL_PROBE_NOTE="完全可用"
    return 0
  fi

  CN_ACCEL_PROBE_NOTE="只能下载，git 协议不通"
  return 2
}

# 挨个探测，选出一个能用的节点。
# 优先选完全可用的；都没有就退而选一个只能下载的，并如实说明。
cn_accel_select_node() {
  cn_accel_state_dir
  local fallback="" fb_gh="" fb_dl=""

  local line name gh_base dl_prefix probe rc
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    name=$(printf '%s' "$line" | cut -d'|' -f1)
    gh_base=$(printf '%s' "$line" | cut -d'|' -f2)
    dl_prefix=$(printf '%s' "$line" | cut -d'|' -f3)
    probe=$(printf '%s' "$line" | cut -d'|' -f4)
    [ -n "$name" ] && [ -n "$gh_base" ] || continue
    [ -n "$probe" ] || probe="${gh_base}octocat/Hello-World.git"
    cn_log "探测节点：${name}"
    cn_accel_probe_node "$name" "$gh_base" "$dl_prefix" "$probe"
    rc=$?
    case "$rc" in
      0)
        CN_ACCEL_NODE_NAME="$name"
        CN_ACCEL_NODE_GH="$gh_base"
        CN_ACCEL_NODE_DL="$dl_prefix"
        CN_ACCEL_NODE_FULL=1
        printf '%s|%s|%s|%s|full\n' "$name" "$gh_base" "$dl_prefix" "$probe" > "$CN_ACCEL_STATE"
        cn_ok "可用节点：${name}"
        return 0
        ;;
      2)
        cn_warn "${name} ${CN_ACCEL_PROBE_NOTE}"
        if [ -z "$fallback" ]; then
          fallback="$name"; fb_gh="$gh_base"; fb_dl="$dl_prefix"
        fi
        ;;
      *)
        cn_warn "${name} 不可用（${CN_ACCEL_PROBE_NOTE}）"
        ;;
    esac
  done <<EOF
$(cn_accel_all_nodes)
EOF

  if [ -n "$fallback" ]; then
    CN_ACCEL_NODE_NAME="$fallback"
    CN_ACCEL_NODE_GH="$fb_gh"
    CN_ACCEL_NODE_DL="$fb_dl"
    CN_ACCEL_NODE_FULL=0
    printf '%s|%s|%s||download\n' "$fallback" "$fb_gh" "$fb_dl" > "$CN_ACCEL_STATE"
    cn_ok "可用节点：${fallback}（只能加速下载）"
    return 0
  fi
  return 1
}

# ---------- 应用加速 ----------

# 写全局 git 配置：把 GitHub 地址换成节点地址。
# 必须用 --add：同一个 key 直接写会覆盖掉上一个，只剩最后一条规则。
#
# git 的改写规则是：键里的地址是「换成什么」，值是「拿什么去换」。
# 所以键写成 url.<替换地址>.insteadOf，值写被替换的前缀。
cn_accel_apply_git() {
  local gh_base="$1" dl_prefix="$2" full="$3"
  local target base

  if [ "$full" = "1" ]; then
    git config --global --add "url.${gh_base}.insteadOf" "$CN_ACCEL_TARGETS_GIT" 2>/dev/null || return 1
  fi
  if [ -n "$dl_prefix" ]; then
    for target in $CN_ACCEL_TARGETS_DOWNLOAD; do
      base="${dl_prefix}${target#https://}"
      git config --global --add "url.${base}.insteadOf" "$target" 2>/dev/null || return 1
    done
  fi
  return 0
}

cn_accel_unapply_git() {
  local gh_base="$1" dl_prefix="$2"
  local target base
  git config --global --unset-all "url.${gh_base}.insteadOf" 2>/dev/null || true
  if [ -n "$dl_prefix" ]; then
    for target in $CN_ACCEL_TARGETS_DOWNLOAD; do
      base="${dl_prefix}${target#https://}"
      git config --global --unset-all "url.${base}.insteadOf" 2>/dev/null || true
    done
  fi
  return 0
}

cn_accel_git_applied() {
  local gh_base="$1"
  # 用 --get 精确查这个键；--get-regexp 会被 git 把键名小写化，匹配不上。
  git config --global --get "url.${gh_base}.insteadOf" >/dev/null 2>&1
}

# 写一份可以 source 的环境变量，给 curl、npm 这类不读 git 配置的工具用。
cn_accel_write_env() {
  local name="$1" gh_base="$2" dl_prefix="$3" full="$4"
  cn_accel_state_dir
  CN_ACCEL_ENV_FILE="$CN_ACCEL_DIR/env.sh"
  cat > "$CN_ACCEL_ENV_FILE" <<EOF
# 由 hermes-cn 生成。source 之后生效。
export HERMES_CN_GH_NODE="${name}"
export HERMES_CN_GH_BASE="${gh_base}"
export HERMES_CN_GH_DOWNLOAD_PREFIX="${dl_prefix}"
export HERMES_CN_GH_FULL="${full}"
EOF
  cn_ok "环境变量已写入：$CN_ACCEL_ENV_FILE"
}

# ---------- 下载助手 ----------

# 把一个 GitHub 地址换成节点地址。
# git 读得了改写规则，curl 这些不读，所以下载走这个命令。
cn_accel_rewrite_url() {
  _url="$1"
  _state=$(cat "$CN_ACCEL_STATE" 2>/dev/null)
  _gh_base=$(printf '%s' "$_state" | cut -d'|' -f2)
  _dl_prefix=$(printf '%s' "$_state" | cut -d'|' -f3)
  if [ -z "$_gh_base" ]; then
    return 1
  fi
  case "$_url" in
    https://github.com/*)
      printf '%s%s' "$_gh_base" "${_url#https://github.com/}"
      ;;
    https://*)
      [ -n "$_dl_prefix" ] || return 1
      printf '%s%s' "$_dl_prefix" "${_url#https://}"
      ;;
    *)
      return 1
      ;;
  esac
}

# 下载一个 GitHub 文件，走当前选中的节点。
# 用法： hermes-cn.sh accel download <地址> [保存的文件名]
cn_accel_download() {
  local url="${1:-}"
  local out="${2:-}"
  if [ -z "$url" ]; then
    cn_err "要下载的地址是什么？"
    printf '用法： hermes-cn.sh accel download <GitHub 地址> [保存的文件名]\n'
    return 2
  fi
  local target
  target=$(cn_accel_rewrite_url "$url") || {
    cn_err "还没选好节点，请先执行： hermes-cn.sh accel setup"
    return 1
  }
  if [ -z "$out" ]; then
    out=$(basename "${target%%\?*}")
    [ -n "$out" ] || out="download.bin"
  fi
  cn_log "下载地址：${target}"
  if curl -sSL --connect-timeout 10 --max-time 1800 -o "$out" "$target"; then
    cn_ok "已下载：${out}（$(wc -c < "$out" | tr -d ' ') 字节）"
    return 0
  fi
  cn_err "下载失败"
  return 1
}

# ---------- 自检 ----------

# 用临时的 git 配置跑，不碰用户真实的全局配置。
cn_accel_selftest() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-cn-accel-test.XXXXXX") || return 1
  local fail=0

  cn_step "准备测试环境"
  export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"

  local gh_base="https://node.test/https://github.com/"
  local dl_prefix="https://node.test/https://"

  # 1) 完全可用的节点：github.com 和下载域名都改写
  cn_accel_apply_git "$gh_base" "$dl_prefix" 1
  local got
  got=$(git config --global --get-all "url.${gh_base}.insteadOf" 2>/dev/null)
  if printf '%s' "$got" | grep -qx "https://github.com/"; then
    cn_ok "github.com 的地址已改写"
  else
    cn_err "github.com 的地址没改写"
    fail=1
  fi
  got=$(git config --global --get-all "url.${dl_prefix}raw.githubusercontent.com/.insteadOf" 2>/dev/null)
  if printf '%s' "$got" | grep -qx "https://raw.githubusercontent.com/"; then
    cn_ok "下载域名的地址已改写"
  else
    cn_err "下载域名的地址没改写"
    fail=1
  fi

  # 2) 只能下载的节点：不动 github.com 前缀，免得 clone 被带崩
  cn_accel_unapply_git "$gh_base" "$dl_prefix"
  cn_accel_apply_git "$gh_base" "$dl_prefix" 0
  got=$(git config --global --get-all "url.${gh_base}.insteadOf" 2>/dev/null)
  if printf '%s' "$got" | grep -qx "https://github.com/"; then
    cn_err "只能下载的节点不该改写 github.com 前缀"
    fail=1
  else
    cn_ok "只能下载的节点不会改写 github.com 前缀"
  fi

  # 3) 能识别出「已生效」（重新按完全可用配置一遍）
  cn_accel_unapply_git "$gh_base" "$dl_prefix"
  cn_accel_apply_git "$gh_base" "$dl_prefix" 1
  if cn_accel_git_applied "$gh_base"; then
    cn_ok "能识别出配置已生效"
  else
    cn_err "识别不出配置已生效"
    fail=1
  fi

  # 4) 撤销后干净了
  cn_accel_unapply_git "$gh_base" "$dl_prefix"
  if cn_accel_git_applied "$gh_base"; then
    cn_err "撤销后还有残留"
    fail=1
  else
    cn_ok "撤销后没有残留"
  fi

  # 5) 环境变量文件内容正确
  CN_ACCEL_DIR="$tmp"
  cn_accel_write_env "测试节点" "$gh_base" "$dl_prefix" 1 >/dev/null
  if grep -q "HERMES_CN_GH_NODE" "$CN_ACCEL_ENV_FILE" &&
     grep -q "HERMES_CN_GH_BASE" "$CN_ACCEL_ENV_FILE"; then
    cn_ok "环境变量文件内容正确"
  else
    cn_err "环境变量文件内容不对"
    fail=1
  fi

  unset GIT_CONFIG_GLOBAL
  unset GIT_CONFIG_NOSYSTEM
  find "$tmp" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true

  if [ "$fail" -eq 0 ]; then
    printf "\\n${CN_GRN}加速环境自检通过。${CN_RST}\\n"
    return 0
  fi
  printf "\\n${CN_YEL}有检查项没通过。${CN_RST}\\n"
  return 1
}

# ---------- 子命令 ----------

cn_accel_cmd() {
  local sub="${1:-status}"
  shift 2>/dev/null || true
  case "$sub" in
    setup)
      cn_step "挑选可用的 GitHub 加速节点"
      if ! cn_accel_select_node; then
        cn_err "没有可用的加速节点，请检查网络，或者自己加节点"
        return 1
      fi
      cn_step "写入 git 配置"
      if cn_accel_apply_git "$CN_ACCEL_NODE_GH" "$CN_ACCEL_NODE_DL" "$CN_ACCEL_NODE_FULL"; then
        cn_ok "GitHub 地址已换成：${CN_ACCEL_NODE_NAME}"
      else
        cn_err "写 git 配置失败"
        return 1
      fi
      cn_accel_write_env "$CN_ACCEL_NODE_NAME" "$CN_ACCEL_NODE_GH" "$CN_ACCEL_NODE_DL" "$CN_ACCEL_NODE_FULL"
      printf "\n${CN_GRN}GitHub 加速环境已生效。${CN_RST}\n"
      if [ "$CN_ACCEL_NODE_FULL" = "1" ]; then
        printf "  现在 git clone 会自动走 ${CN_ACCEL_NODE_NAME}。\n"
      else
        printf "  这个节点只能加速下载，clone 仍走直连。\n"
      fi
      printf "  用 curl 这类工具下载，用： hermes-cn.sh accel download <GitHub 地址>\n"
      printf "  私有仓库不受影响（访问它们必须带凭据，地址对不上）。\n"
      printf "  撤销请执行： hermes-cn.sh accel uninstall\n"
      ;;
    probe)
      cn_step "挨个探测候选节点"
      local line name gh_base dl_prefix probe rc
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        name=$(printf '%s' "$line" | cut -d'|' -f1)
        gh_base=$(printf '%s' "$line" | cut -d'|' -f2)
        dl_prefix=$(printf '%s' "$line" | cut -d'|' -f3)
        probe=$(printf '%s' "$line" | cut -d'|' -f4)
        [ -n "$name" ] && [ -n "$gh_base" ] || continue
        [ -n "$probe" ] || probe="${gh_base}octocat/Hello-World.git"
        cn_accel_probe_node "$name" "$gh_base" "$dl_prefix" "$probe"
        rc=$?
        if [ "$rc" = "0" ]; then
          cn_ok "${name}：完全可用"
        elif [ "$rc" = "2" ]; then
          cn_warn "${name}：${CN_ACCEL_PROBE_NOTE}"
        else
          cn_warn "${name}：不可用（${CN_ACCEL_PROBE_NOTE}）"
        fi
      done <<EOF
$(cn_accel_all_nodes)
EOF
      ;;
    status)
      local state
      state=$(cat "$CN_ACCEL_STATE" 2>/dev/null)
      printf "当前节点 : %s\n" "${state:-未设置}"
      printf "候选数量 : %s 个\n" "$(cn_accel_all_nodes | grep -c '|')"
      local gh_base
      gh_base=$(printf '%s' "$state" | cut -d'|' -f2)
      if [ -n "$gh_base" ] && cn_accel_git_applied "$gh_base"; then
        printf "git 配置 : 已生效\n"
      else
        printf "git 配置 : 未生效\n"
      fi
      if [ -f "$CN_ACCEL_ENV_FILE" ]; then
        printf "环境变量 : %s\n" "$CN_ACCEL_ENV_FILE"
      else
        printf "环境变量 : 未生成\n"
      fi
      ;;
    env)
      if [ -f "$CN_ACCEL_ENV_FILE" ]; then
        cat "$CN_ACCEL_ENV_FILE"
      else
        cn_err "还没生成环境变量，请先执行： hermes-cn.sh accel setup"
        return 1
      fi
      ;;
    download)
      cn_accel_download "$@"
      ;;
    test)
      cn_accel_selftest
      ;;
    uninstall)
      local state gh_base dl_prefix
      state=$(cat "$CN_ACCEL_STATE" 2>/dev/null)
      gh_base=$(printf '%s' "$state" | cut -d'|' -f2)
      dl_prefix=$(printf '%s' "$state" | cut -d'|' -f3)
      if [ -n "$gh_base" ]; then
        cn_accel_unapply_git "$gh_base" "$dl_prefix"
        cn_ok "已移除 git 配置"
      fi
      find "$CN_ACCEL_DIR" -mindepth 1 -delete 2>/dev/null || true
      rmdir "$CN_ACCEL_DIR" 2>/dev/null || true
      cn_ok "已撤销加速环境"
      ;;
    *)
      cn_err "未知的 accel 子命令：$sub"
      printf "可用：setup / probe / status / env / download / test / uninstall\n"
      return 2
      ;;
  esac
}
