#!/usr/bin/env bash
# 加速源候选表。
#
# 每个候选都必须满足：
#   1. 匿名可用（不需要登录、不需要 token）
#   2. 完整覆盖 Hermes 依赖树里全部 3525 个制品
#   3. 路径结构与 https://files.pythonhosted.org/packages/ 完全一致
#
# 第 3 条是硬性要求：Hermes 的 uv.lock 里固化了 3525 处
# https://files.pythonhosted.org/packages/... 绝对地址，只有镜像逐字节保持
# 同样的 /packages/<2位>/<2位>/<60位十六进制>/<文件名> 结构，
# 才能直接把 lock 里的 URL 前缀换掉。
#
# 实测覆盖度（对 Hermes uv.lock 全量 3525 个制品逐个 GET 校验）：
#   清华 TUNA  3525/3525
#   阿里云      3525/3525
#   腾讯云      3525/3525
#   北京外国语  3525/3525
#   中科大 USTC 3239/3525（并发探测被限流导致的 000；串行复测全部 200）
#
# 优先级：清华 > 中科大 > 阿里云 > 腾讯云 > 北京外国语。
# 清华/中科大/阿里云 属于用户明确要求的主力源。

# ---------- PyPI 镜像 ----------
# 格式：<名称>|<simple 索引 URL>|<packages 制品 URL 前缀>
# packages 前缀必须以 /packages/ 结尾，替换时直接顶掉
# https://files.pythonhosted.org/packages/ 这一段。
CN_PYPI_CANDIDATES="
清华|https://pypi.tuna.tsinghua.edu.cn/simple|https://pypi.tuna.tsinghua.edu.cn/packages/
中科大|https://mirrors.ustc.edu.cn/pypi/simple|https://mirrors.ustc.edu.cn/pypi/packages/
阿里云|https://mirrors.aliyun.com/pypi/simple|https://mirrors.aliyun.com/pypi/packages/
腾讯云|https://mirrors.cloud.tencent.com/pypi/simple|https://mirrors.cloud.tencent.com/pypi/packages/
北京外国语|https://mirrors.bfsu.edu.cn/pypi/web/simple|https://mirrors.bfsu.edu.cn/pypi/web/packages/
"

# 备用候选：华为云路径不同（repository/pypi 而非 pypi），且对 HEAD 返回 403，
# 只能走 GET；放在最后作为兜底。
CN_PYPI_CANDIDATES_EXTRA="
华为云|https://mirrors.huaweicloud.com/repository/pypi/simple|https://mirrors.huaweicloud.com/repository/pypi/packages/
"

# ---------- GitHub 仓库镜像 ----------
# 格式：<名称>|<镜像上的完整仓库 URL>[|探测用的地址]
#
# 第三列是探测地址：用一个很小的公开仓库去测节点通不通。
# 节点是现拉的，拿大仓库探测会等很久（有的节点要现建镜像），
# 小仓库几秒就能出结果。
#
# 2026-11-03 实测：
#   gh-proxy.cc   git 协议可用
#   gh-proxy.com  git 协议可用
#   GitCode       现在要登录了，匿名拉不了（会提示输入用户名）
#   gitclone      502
#   hub.gitmirror 域名解析失败
CN_GIT_CANDIDATES="
gh-proxy.cc|https://gh-proxy.cc/https://github.com/NousResearch/hermes-agent.git|https://gh-proxy.cc/https://github.com/octocat/Hello-World.git
gh-proxy.com|https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git|https://gh-proxy.com/https://github.com/octocat/Hello-World.git
www.gh-proxy.cc|https://www.gh-proxy.cc/https://github.com/NousResearch/hermes-agent.git|https://www.gh-proxy.cc/https://github.com/octocat/Hello-World.git
"

# 想用 GitCode 的话得有账号，可以自己指定：
#   ./hermes-cn.sh --git-mirror https://gitcode.com/GitHub_Trending/he/hermes-agent.git run hermes update

# 可选的 Gitee 自建镜像回退。
# 硬结论：Gitee 匿名不可用 —— gitee.com/mirrors/hermes-agent.git 需要登录，
# 公开搜索接口也查不到现成镜像。所以这里只支持用户自建镜像后填入，
# 没有凭据时自动跳过，不做任何假装成功的探测。
CN_GITEE_CANDIDATE=""

# ---------- GitHub raw / release 代理 ----------
# 格式：<名称>|<URL 前缀>
# raw 实测：
#   fastly.jsdelivr.net  200
#   gh-proxy.net         200
#   cdn.jsdelivr.net     000
#   raw.gitmirror.com    000
CN_RAW_CANDIDATES="
jsDelivr|https://fastly.jsdelivr.net/gh/NousResearch/hermes-agent@main
gh-proxy|https://gh-proxy.net/https://raw.githubusercontent.com/NousResearch/hermes-agent/main
"

# GitHub API 代理。hermes_cli/github_api.py 没有 base URL 环境变量入口，
# 所以只作为脚本自身调用 API 时的可选前缀，不改 Hermes 源码。
CN_GH_API_CANDIDATES="
gh-proxy|https://gh-proxy.net/https://api.github.com
"

# GitHub release 直链代理 + git 源代理。
#
# Hermes 的 uv.lock 里有 4 处来自 GitHub 的依赖：
#   kittentts  release 直链（.whl 下载）
#   misaki      git 源（NousResearch/misaki.git）
#   psutil      git 源（giampaolo/psutil.git，android 分支）
# PyPI 改写覆盖不到它们，必须单独走 GitHub 代理。
#
# 候选必须同时满足两个条件（实测）：
#   1. release 直链返回真实的 zip 字节，且 sha256 与 lock 里记录的一致
#      —— gh-proxy.net 对 release 直链返回 HTML 反爬页，uv 会报
#         "Invalid zip file structure"，不可用
#   2. 支持 git 协议并能返回非空 refs
#      —— 很多代理对 info/refs 返回 JS 挑战页，git clone 得到空仓库
#
# 实测：
#   gh-proxy.cc   release HASH-OK，git 协议 OK     <- 采用
#   ghproxy.net   release HASH-OK（直连），git OK；经隧道不通
#   gh-proxy.net  release 返回 HTML，git 返回空仓库  <- 不可用
CN_GH_PROXY_CANDIDATES="
gh-proxy.cc|https://gh-proxy.cc/https://github.com
ghproxy.net|https://ghproxy.net/https://github.com
"

# ---------- 二进制镜像 ----------
# Node / npm / Python standalone：npmmirror（淘宝源）
# uv：华为云 uv 路径（清华/中科大的 github-release 路径实测 404）
CN_BIN_NODE_MIRRORS="
npmmirror|https://cdn.npmmirror.com/binaries/node
"

CN_BIN_NPM_REGISTRY="https://registry.npmmirror.com"

CN_BIN_PYTHON_MIRRORS="
npmmirror|https://registry.npmmirror.com/-/binary/python-build-standalone
"

CN_BIN_UV_MIRRORS="
华为云|https://mirrors.huaweicloud.com/uv
"

# ---------- 官方兜底 ----------
# 官方内容寻址资源站。install.sh 的 uv 二进制自带 UV_PIN_MIRROR 回退，
# release 指针 stable/release-candidates.json 也在这里，全程 200。
CN_OFFICIAL_ASSETS="https://hermes-assets.nousresearch.com"

# ---------- 解析后的便捷变量（供 lib/env.sh 使用） ----------
CN_BIN_NODE_MIRRORS_NPMMIRROR="https://cdn.npmmirror.com/binaries/node"
CN_BIN_PYTHON_MIRRORS_NPMMIRROR="https://registry.npmmirror.com/-/binary/python-build-standalone"
CN_BIN_UV_MIRRORS_HUAWEI="https://mirrors.huaweicloud.com/uv"

# 上游官方仓库地址。改写只发生在传输层，remote.origin.url 必须保持这个值，
# 否则 hermes_cli/update_channel.py:_tracks_official_origin 会判定为非官方，
# 更新通道随之降级。
CN_OFFICIAL_ORIGIN="https://github.com/NousResearch/hermes-agent.git"
