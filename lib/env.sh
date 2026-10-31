#!/usr/bin/env bash
# 运行环境组装：把选中的源翻译成一组环境变量 / git 配置，
# 让 hermes update、scripts/install.sh 以及任意联网命令都能走镜像。

# cn_env_raw <raw 前缀> —— 打印 raw 访问用的变量
# 官方 raw 在大陆常年不可达，hermes_cli/github_api.py 没有 base URL 入口，
# 所以这里提供 HERMES_RAW_BASE 供脚本自身使用。
cn_env_raw() {
  _prefix="$1"
  printf 'export HERMES_RAW_BASE=%s\n' "$_prefix"
}

# cn_env_binaries —— 二进制镜像（node / npm / python standalone / uv）
cn_env_binaries() {
  printf 'export NODEJS_ORG_MIRROR=%s\n' "$CN_BIN_NODE_MIRRORS_NPMMIRROR"
  printf 'export NVM_NODEJS_ORG_MIRROR=%s\n' "$CN_BIN_NODE_MIRRORS_NPMMIRROR"
  printf 'export NVM_DOWNLOAD_URL=%s\n' "$CN_BIN_NODE_MIRRORS_NPMMIRROR"
  printf 'export npm_config_registry=%s\n' "$CN_BIN_NPM_REGISTRY"
  printf 'export UV_PYTHON_INSTALL_MIRROR=%s\n' "$CN_BIN_PYTHON_MIRRORS_NPMMIRROR"
  printf 'export UV_INSTALL_MIRROR=%s\n' "$CN_BIN_UV_MIRRORS_HUAWEI"
  printf 'export PLAYWRIGHT_DOWNLOAD_HOST=%s\n' "$CN_BIN_NPM_REGISTRY"
}

# cn_env_proxy <http_proxy> <https_proxy>
# 用户自己有梯子/代理时可以传进来，与镜像叠加使用。
cn_env_proxy() {
  [ -n "${1:-}" ] && printf 'export HTTP_PROXY=%s\n' "$1"
  [ -n "${2:-}" ] && printf 'export HTTPS_PROXY=%s\n' "$2"
  [ -n "${1:-}" ] && printf 'export http_proxy=%s\n' "$1"
  [ -n "${2:-}" ] && printf 'export https_proxy=%s\n' "$2"
}

# cn_write_env_file <文件> —— 把当前环境写入一个可 source 的文件
# 供「一键加速」使用：source 之后当前 shell 即处于加速环境。
cn_write_env_file() {
  _out="$1"
  _pypi_index="$2"; _raw_prefix="$3"; _git_prefix="$4"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# 由 hermes-cn.sh 生成。请勿手工编辑。\n'
    if [ -n "$_pypi_index" ]; then
      cn_uv_index_env "$_pypi_index"
    fi
    if [ -n "$_raw_prefix" ]; then
      cn_env_raw "$_raw_prefix"
    fi
    cn_env_binaries
    printf 'export HERMES_CN_ENABLED=1\n'
  } > "$_out"
}

# cn_git_env_snippet —— 给外部脚本用的 git 传输层改写（环境变量版）
# 注意：这只对脚本自身发起的 git 有效，Hermes 内部 git 会丢弃这些注入，
# 所以内部路径靠 repo-local config（见 lib/git.sh）。
cn_git_env_snippet() {
  _upstream="$1"; _mirror="$2"
  printf 'export GIT_CONFIG_COUNT=1\n'
  printf 'export GIT_CONFIG_KEY_0=url.%s/.insteadOf\n' "$_mirror"
  printf 'export GIT_CONFIG_VALUE_0=%s\n' "$_upstream"
}
