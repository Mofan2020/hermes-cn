#!/usr/bin/env bash
# 浏览器用的 GitHub 加速。
#
# 浏览器不读 git 配置，git 那套改写对它没用。
# 这里起一个本地的小服务：浏览器访问它，它把请求转给加速节点，
# 再把响应送回来。整个过程走普通 HTTP，不装证书、不改系统设置，
# 关掉服务就恢复原样。
#
# 为什么需要它：
#   加速节点各有各的本事。有的能代理网页但不管样式文件，
#   有的能代理样式文件但网页只给一张自己的首页。
#   这个服务把请求按类型分给不同的节点，
#   哪个节点临时抽风了，就换一个顶上。
#
# 用法：
#   hermes-cn.sh web              启动服务并打开浏览器
#   hermes-cn.sh web serve        只启动服务
#   hermes-cn.sh web stop         停掉服务
#   hermes-cn.sh web status       看服务状态
#   hermes-cn.sh web test         自检
#
# 只面向 macOS / Linux。

CN_WEB_DIR="${CN_WEB_DIR:-$HOME/.hermes-cn/web}"
CN_WEB_PID_FILE="$CN_WEB_DIR/web.pid"
CN_WEB_PORT_FILE="$CN_WEB_DIR/web.port"
CN_WEB_LOG_FILE="$CN_WEB_DIR/web.log"
CN_WEB_HOST="127.0.0.1"

# 浏览器打开页面时，这些域名上的内容也要走加速，
# 否则页面能出来，样式和图标却是空的。
CN_WEB_ASSET_DOMAINS="github.githubassets.com avatars.githubusercontent.com user-images.githubusercontent.com"

# 服务默认端口。端口被占就往后找。
CN_WEB_PORT_DEFAULT="${CN_WEB_PORT_DEFAULT:-8765}"

# ---------- 节点能力 ----------

# 节点表里单独记一份「会代理网页」的节点。
# 这类节点和普通下载节点不一样：普通节点取网页只会返回一张自己的首页，
# 只有这里记的节点才能真的把 GitHub 页面取回来。
#
# 格式：<名称>|<前缀>|<形态>
#   形态 prefix —— 前缀形态，原始地址整段接在后面
#        site   —— 整站形态，地址里去掉 github.com/ 这段
#
# 2026-11-04 实测：
#   ghproxy.vip     前缀形态，网页可用（探测地址 https://ghproxy.vip/https://github.com/octocat/Hello-World）
#   githubfast.com  整站形态，网页可用（探测地址 https://githubfast.com/octocat/Hello-World）
#   其它候选节点取网页只会返回自己的首页，不算数。
#
# 注意：githubfast.com 会反过来拦浏览器的 UA，对普通命令行工具放行，
# 所以探测和转发都统一用 curl 风格的 UA。
CN_WEB_CAP_TABLE="
ghproxy.vip|https://ghproxy.vip/https://|prefix
githubfast.com|https://githubfast.com/|site
"

# 找出能代理网页的节点。
# 输出：<名称>|<前缀>|<形态>
cn_web_web_nodes() {
  printf '%s\n' "$CN_WEB_CAP_TABLE" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=$(printf '%s' "$line" | cut -d'|' -f1)
    prefix=$(printf '%s' "$line" | cut -d'|' -f2)
    mode=$(printf '%s' "$line" | cut -d'|' -f3)
    case "$mode" in
      prefix|site) ;;
      *) continue ;;
    esac
    [ -n "$name" ] && [ -n "$prefix" ] || continue
    printf '%s|%s|%s\n' "$name" "$prefix" "$mode"
  done
}

# 拼出节点的完整前缀。
# 整站形态要把 github.com/ 这段去掉，剩下的是原始路径。
cn_web_build_prefix() {
  local mode="$1" prefix="$2"
  if [ "$mode" = "site" ]; then
    printf '%s' "$prefix"
  else
    printf '%s' "$prefix"
  fi
}

# 找一个还在用的普通节点，用来跑样式文件、图片这些。
# 输出：<名称>|<前缀>
cn_web_asset_nodes() {
  cn_accel_all_nodes | while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    name=$(printf '%s' "$line" | cut -d'|' -f1)
    gh_base=$(printf '%s' "$line" | cut -d'|' -f2)
    dl_prefix=$(printf '%s' "$line" | cut -d'|' -f3)
    probe=$(printf '%s' "$line" | cut -d'|' -f4)
    [ -n "$dl_prefix" ] || continue
    [ -n "$probe" ] || continue
    printf '%s|%s|%s\n' "$name" "$dl_prefix" "$probe"
  done
}

# 收集备选节点，一行一个「前缀|形态」。
# 这些是「抽风时顶上用」的，按顺序试。
cn_web_fallback_prefixes() {
  cn_web_web_nodes | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s|%s\n' \
      "$(printf '%s' "$line" | cut -d'|' -f2)" \
      "$(printf '%s' "$line" | cut -d'|' -f3)"
  done
}

cn_web_asset_fallback_prefixes() {
  cn_web_asset_nodes | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s|%s\n' \
      "$(printf '%s' "$line" | cut -d'|' -f2)" \
      "prefix"
  done
}

# 节点能不能代理网页。
# 判据：抓一个 GitHub 仓库页面回来，内容里要能看到仓库名。
# 只看状态码不行，有些节点会返回一张自己的首页，状态码也是 200；
# 必须出现被请求的那个仓库名才算真页面。
#
# 前缀形态：原始地址整段接在节点后面。
# 整站形态：地址里去掉 github.com/ 这段。
cn_web_probe_web() {
  local prefix="$1" mode="${2:-prefix}"
  [ -n "$prefix" ] || return 1
  local url
  if [ "$mode" = "site" ]; then
    url="${prefix}octocat/Hello-World"
  else
    url="${prefix}github.com/octocat/Hello-World"
  fi
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-cn-web.XXXXXX") || return 1
  local code
  # 用 curl 的 UA，和服务实际转发时保持一致。
  # 有些节点会反过来拦浏览器的 UA，两边不一致会误判。
  code=$(curl -sSL --connect-timeout 8 --max-time 40 -A "curl/8.7.1" \
    -o "$tmp/p.html" -w '%{http_code}' "$url" 2>/dev/null)
  local ok=1
  if [ "$code" = "200" ] && grep -q 'octocat/Hello-World' "$tmp/p.html" 2>/dev/null; then
    ok=0
  fi
  find "$tmp" -mindepth 1 -delete 2>/dev/null
  rmdir "$tmp" 2>/dev/null
  return $ok
}

# 节点能不能代理样式文件。
# 判据：抓一个真实存在的 js 文件回来，内容不能是错误页。
cn_web_probe_asset() {
  local prefix="$1"
  [ -n "$prefix" ] || return 1
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-cn-web.XXXXXX") || return 1
  curl -sSL --connect-timeout 8 --max-time 30 -o "$tmp/a.js" \
    "${prefix}github.githubassets.com/assets/high-contrast-cookie-e033406c222180ad.js" 2>/dev/null
  local size
  size=$(wc -c < "$tmp/a.js" 2>/dev/null | tr -d ' ')
  find "$tmp" -mindepth 1 -delete 2>/dev/null
  rmdir "$tmp" 2>/dev/null
  [ "${size:-0}" -gt 500 ] 2>/dev/null
}

# ---------- 挑选节点 ----------

# 挑出一个能代理网页的节点。
# 输出：<名称>|<前缀>|<形态>
cn_web_pick_web_node() {
  local line name prefix mode
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=$(printf '%s' "$line" | cut -d'|' -f1)
    prefix=$(printf '%s' "$line" | cut -d'|' -f2)
    mode=$(printf '%s' "$line" | cut -d'|' -f3)
    if cn_web_probe_web "$prefix" "$mode"; then
      printf '%s|%s|%s\n' "$name" "$prefix" "$mode"
      return 0
    fi
  done <<EOF
$(cn_web_web_nodes)
EOF
  return 1
}

# 挑出一个能代理样式文件的节点。
# 输出：<名称>|<前缀>
cn_web_pick_asset_node() {
  local line name prefix probe
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=$(printf '%s' "$line" | cut -d'|' -f1)
    prefix=$(printf '%s' "$line" | cut -d'|' -f2)
    probe=$(printf '%s' "$line" | cut -d'|' -f3)
    if cn_web_probe_asset "$prefix"; then
      printf '%s|%s\n' "$name" "$prefix"
      return 0
    fi
  done <<EOF
$(cn_web_asset_nodes)
EOF
  return 1
}

# ---------- 转发服务 ----------

# 服务本体在 lib/web_server.py（用系统自带的 python3 跑）。
# 这里只负责把参数凑好、把进程看住。

cn_web_python() {
  if [ -x /usr/bin/python3 ]; then
    printf '/usr/bin/python3'
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    return 1
  fi
}

# 服务程序在不在
cn_web_server_file() {
  printf '%s' "$CN_SELF_DIR/lib/web_server.py"
}

cn_web_check_files() {
  local missing=""
  [ -f "$CN_SELF_DIR/lib/web.sh" ] || missing="$missing lib/web.sh"
  [ -f "$(cn_web_server_file)" ] || missing="$missing lib/web_server.py"
  if [ -n "$missing" ]; then
    cn_err "缺少配套文件，跑不起来。"
    printf '  缺少：%s\n' "$missing" >&2
    printf '  请把整个目录一起下载。\n' >&2
    printf '  下载地址：https://github.com/Mofan2020/hermes-cn/releases/latest\n' >&2
    return 1
  fi
  return 0
}

# ---------- 进程管理 ----------

cn_web_is_running() {
  local pid
  pid=$(cat "$CN_WEB_PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

cn_web_port() {
  cat "$CN_WEB_PORT_FILE" 2>/dev/null
}

# 找一个没人占的端口
cn_web_free_port() {
  local p="$CN_WEB_PORT_DEFAULT"
  while [ "$p" -lt 8800 ]; do
    if ! nc -z 127.0.0.1 "$p" 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
    p=$((p + 1))
  done
  return 1
}

cn_web_stop() {
  if cn_web_is_running; then
    local pid
    pid=$(cat "$CN_WEB_PID_FILE" 2>/dev/null)
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    cn_ok "已停掉浏览器加速服务"
  else
    cn_warn "服务本来就没在跑"
  fi
  find "$CN_WEB_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$CN_WEB_DIR" 2>/dev/null || true
}

cn_web_start() {
  mkdir -p "$CN_WEB_DIR" 2>/dev/null || true

  if cn_web_is_running; then
    cn_warn "服务已经在跑了"
    cn_web_status
    return 0
  fi

  local py
  py=$(cn_web_python) || {
    cn_err "找不到 python3，服务起不来"
    cn_warn "装一下命令行工具即可： xcode-select --install"
    return 1
  }

  cn_step "挑选能代理网页的节点"
  local web_node web_prefix web_mode asset_node asset_prefix
  web_node=$(cn_web_pick_web_node) || {
    cn_err "暂时找不到能代理网页的节点"
    cn_warn "过一会儿再试，或者自己加节点"
    return 1
  }
  web_name=$(printf '%s' "$web_node" | cut -d'|' -f1)
  web_prefix=$(printf '%s' "$web_node" | cut -d'|' -f2)
  web_mode=$(printf '%s' "$web_node" | cut -d'|' -f3)
  cn_ok "网页节点：${web_name}"

  cn_step "挑选能代理样式文件的节点"
  asset_node=$(cn_web_pick_asset_node) || {
    cn_err "暂时找不到能代理样式文件的节点"
    cn_warn "页面能打开，但没有样式"
    asset_name="$web_name"
    asset_prefix="$web_prefix"
  }
  if [ -n "$asset_node" ]; then
    asset_name=$(printf '%s' "$asset_node" | cut -d'|' -f1)
    asset_prefix=$(printf '%s' "$asset_node" | cut -d'|' -f2)
    cn_ok "样式文件节点：${asset_name}"
  fi

  local port
  port=$(cn_web_free_port) || {
    cn_err "找不到空闲端口"
    return 1
  }

  cn_step "启动服务"
  # 备选节点一起传进去：一个抽风了自动换下一个。
  # 参数写进配置文件再读，避免 bash 数组（macOS 自带 bash 3.2 不支持）。
  local args_file="$CN_WEB_DIR/args.txt"
  {
    printf 'port %s\n' "$port"
    printf 'cachedir %s\n' "$CN_WEB_DIR"
    # 主节点放第一个，后面跟备选
    printf 'web %s|%s\n' "$web_prefix" "$web_mode"
    cn_web_fallback_prefixes | while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf 'web %s\n' "$p"
    done
    if [ -n "$asset_prefix" ]; then
      printf 'asset %s|prefix\n' "$asset_prefix"
    fi
    cn_web_asset_fallback_prefixes | while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf 'asset %s\n' "$p"
    done
  } > "$args_file"

  "$py" "$CN_SELF_DIR/lib/web_server.py" --args "$args_file" \
    > "$CN_WEB_LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$CN_WEB_PID_FILE"
  echo "$port" > "$CN_WEB_PORT_FILE"

  sleep 1.5
  if ! cn_web_is_running; then
    cn_err "服务起不来，看日志：$CN_WEB_LOG_FILE"
    return 1
  fi

  cn_ok "服务已启动，端口 ${port}"
  printf '%s' "$port"
}

cn_web_status() {
  if cn_web_is_running; then
    local port
    port=$(cn_web_port)
    printf "服务状态 : 运行中\n"
    printf "端口     : %s\n" "$port"
    printf "访问地址 : http://%s:%s/gh/github.com/\n" "$CN_WEB_HOST" "$port"
  else
    printf "服务状态 : 未运行\n"
  fi
}

# 打开浏览器
cn_web_open() {
  local port="$1"
  local url="http://${CN_WEB_HOST}:${port}/gh/github.com/"
  cn_ok "在浏览器里打开：${url}"
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi
  cn_warn "没找到能打开浏览器的命令，手动访问上面的地址就行"
  return 1
}

# ---------- 自检 ----------

cn_web_selftest() {
  local fail=0
  cn_step "检查运行条件"

  if ! cn_web_python >/dev/null 2>&1; then
    cn_err "找不到 python3，服务起不来"
    cn_warn "装一下命令行工具即可： xcode-select --install"
    return 1
  fi
  cn_ok "python3 可用"

  cn_step "检查节点能力"
  local web_node
  if web_node=$(cn_web_pick_web_node); then
    cn_ok "有节点能代理网页：$(printf '%s' "$web_node" | cut -d'|' -f1)"
  else
    cn_warn "暂时没有节点能代理网页，网页加速会开不起来"
  fi

  local asset_node
  if asset_node=$(cn_web_pick_asset_node); then
    cn_ok "有节点能代理样式文件：$(printf '%s' "$asset_node" | cut -d'|' -f1)"
  else
    cn_warn "暂时没有节点能代理样式文件，页面会没有样式"
  fi

  cn_step "检查服务能不能起"
  local port
  port=$(cn_web_free_port) || {
    cn_err "找不到空闲端口"
    return 1
  }

  local py
  py=$(cn_web_python)
  local args_file="${TMPDIR:-/tmp}/hermes-cn-web-test-args.txt"
  {
    printf 'port %s\n' "$port"
    printf 'cachedir %s\n' "${TMPDIR:-/tmp}/hermes-cn-web-test-cache"
    printf 'web https://ghproxy.vip/https://|prefix\n'
    printf 'web https://githubfast.com/|site\n'
    printf 'asset https://gh-proxy.com/https://|prefix\n'
  } > "$args_file"
  "$py" "$CN_SELF_DIR/lib/web_server.py" --args "$args_file" \
    > "${TMPDIR:-/tmp}/hermes-cn-web-test.log" 2>&1 &
  local pid=$!

  sleep 1.5
  if kill -0 "$pid" 2>/dev/null; then
    cn_ok "服务能启动"
    # 取一个仓库页面回来。页面不小，节点慢的时候要多给点时间，
    # 超时和「服务没起来」是两回事，要分开报。
    local got
    got=$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:$port/gh/github.com/octocat/Hello-World" 2>/dev/null)
    case "$got" in
      200) cn_ok "转发链路通，页面能取回来" ;;
      000)
        # 再试一次，区分是服务没监听还是节点慢
        sleep 1
        got=$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' \
          "http://127.0.0.1:$port/gh/github.com/octocat/Hello-World" 2>/dev/null)
        if [ "$got" = "200" ]; then
          cn_ok "转发链路通，页面能取回来"
        elif [ "$got" = "000" ]; then
          cn_err "服务收不到请求"
          fail=1
        else
          cn_warn "节点返回 $got，页面可能取不回来"
        fi
        ;;
      *)   cn_warn "节点返回 $got，页面可能取不回来" ;;
    esac
  else
    cn_err "服务起不来"
    cn_warn "看日志： ${TMPDIR:-/tmp}/hermes-cn-web-test.log"
    fail=1
  fi

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  if [ "$fail" != "0" ]; then
    printf "\\n${CN_YEL}有检查项没通过。${CN_RST}\\n"
    return 1
  fi
  printf "\\n${CN_GRN}浏览器加速自检通过。${CN_RST}\\n"
}

# 判断某个命令在不在
cn_web_have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 子命令 ----------

cn_web_cmd() {
  local sub="${1:-start}"
  shift 2>/dev/null || true
  case "$sub" in
    start)
      cn_web_check_files || return 1
      local port
      port=$(cn_web_start | tail -1)
      [ -n "$port" ] || return 1
      cn_web_open "$port"
      ;;
    serve)
      cn_web_check_files || return 1
      cn_web_start > /dev/null
      ;;
    stop)
      cn_web_stop
      ;;
    clean)
      if [ -d "$CN_WEB_DIR/cache" ]; then
        find "$CN_WEB_DIR/cache" -mindepth 1 -delete 2>/dev/null || true
        rmdir "$CN_WEB_DIR/cache" 2>/dev/null || true
        cn_ok "已清掉缓存"
      else
        cn_warn "没有缓存可清"
      fi
      ;;
    status)
      cn_web_status
      ;;
    test)
      cn_web_check_files || return 1
      cn_web_selftest
      ;;
    *)
      cn_err "未知的 web 子命令：$sub"
      printf '可用：start / serve / stop / clean / status / test\n'
      return 2
      ;;
  esac
}
