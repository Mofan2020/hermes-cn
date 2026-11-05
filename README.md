# hermes-cn

hermes-cn 是给大陆网络环境用的 Hermes Agent 加速工具。

GitHub 拉不动、pip 装不上、`hermes update` 卡在半路——这类问题装上这个工具就能绕过去。它会在每次启动时挨个连一遍内置的国内镜像，挑一个当前真正能用的用上，然后你可以直接跑 `hermes update`、官方的 `bash scripts/install.sh`，或者任何需要联网的命令。

macOS 和 Linux 是主力平台，更新最快。Windows 版功能一样，但会在 macOS / Linux 版稳定之后才跟进。Windows 的用法见下面「Windows」一节。

除了给终端里的命令加速，这个工具还能给 `git clone`、文件下载，以及浏览器访问 GitHub 准备一套加速环境，浏览器那部分见下面「浏览器访问 GitHub」。

## 什么时候用得上

- `hermes update` 卡住不动，或者中途报网络错误，版本停在半路上。
- 官方安装脚本跑到一半失败，依赖下载速度只有几 KB/s，甚至直接超时。
- `pip install` 装不上依赖，`git clone` 官方仓库连不上，只能干等。
- 手动配过镜像，但换了网络环境、或者镜像临时抽风之后，之前配的全白费。

## 快速开始

### 第一步：下载

从 Releases 页面下载整个压缩包：

https://github.com/Mofan2020/hermes-cn/releases/latest

在页面里选「Source code (zip)」或者「Source code (tar.gz)」下载。GitHub 会把整个仓库打包好，不用自己挑文件。

不想用压缩包、习惯用 git 的话，也可以克隆：

```bash
git clone https://github.com/Mofan2020/hermes-cn.git
cd hermes-cn
```

### 第二步：进入目录

解压后进入目录（压缩包里的目录名带版本号，比如 `hermes-cn-1.0.0`）：

```bash
cd hermes-cn-1.0.0
```

万一提示 Permission denied，给脚本加上执行权限就行：

```bash
chmod +x hermes-cn.sh
```

注意 `lib` 目录要和 `hermes-cn.sh` 放在同一个目录里，缺了它脚本跑不起来。

### 第三步：先自检一遍

看看当前网络下各镜像通不通：

```bash
./hermes-cn.sh doctor
```

### 第四步：开始用

最常见的用法，是给一条命令加速。更新 Hermes：

```bash
./hermes-cn.sh run hermes update
```

跑官方安装脚本：

```bash
./hermes-cn.sh run bash scripts/install.sh
```

想让加速一直生效：

```bash
./hermes-cn.sh apply
```

`apply` 之后，直接在终端里跑 `hermes update` 就行，不用再带前缀。

只想临时用一下，就进入一个加速过的 shell，退出后一切恢复原样：

```bash
./hermes-cn.sh
```

## Windows

Windows 版单独提供，命令跟 macOS / Linux 版完全一样。

不需要装任何额外东西，用 Windows 自带的 PowerShell 5.1 或更高版本就行（Win10 / Win11 都自带）。

### 下载和运行

1. 从 Releases 页面下载 Source code (zip)，解压。
2. 进入解压出来的目录。
3. 在命令提示符或 PowerShell 里运行：

```bat
hermes-cn.cmd doctor
hermes-cn.cmd run hermes update
hermes-cn.cmd apply
```

`hermes-cn.cmd` 会自动把控制台切到 UTF-8，脚本文件本身也是按 UTF-8 保存的，中文提示不会乱码。

### 两个小提醒

指定镜像时建议用英文别名，中文名在 Windows PowerShell 5.1 里传参可能变成乱码：

```bat
hermes-cn.cmd --pypi-mirror tuna run hermes update
```

可用的英文别名：tuna（清华）、ustc（中科大）、aliyun（阿里云）、tencent（腾讯云）、bfsu（北京外国语）、huawei（华为云）。

如果安全软件拦下了脚本，在 PowerShell 里这样跑：

```powershell
powershell -ExecutionPolicy Bypass -File .\hermes-cn.ps1 doctor
```

### 版本节奏

macOS / Linux 版先更新，Windows 版等 macOS / Linux 版跑稳了再同步。Windows 上遇到怪问题，先按 macOS / Linux 版的行为对照着看。

## GitHub 加速环境

除了给 Hermes 加速，这个工具还能给整台机器准备一个 GitHub 加速环境：`git clone` 会自动走国内的中转节点，下载 release 文件也有专门的命令。

这些节点有两种玩法：有的把地址换成 `https://<节点>/https://github.com/owner/repo`，有的换成 `https://<节点>/github.com/owner/repo`。不管哪种，文件都是节点替你取回来的。节点用的是自己的正规证书，不涉及自签证书，所以不会出现「证书不受信任」；万一哪个节点的证书有问题，探测时就会直接把它剔掉。

目前只有 macOS 和 Linux 有这个功能，Windows 版暂时没有。

### 开启

```bash
./hermes-cn.sh accel setup
```

它会挨个探测候选节点，三件事都过才算数：能不能连上、返回的是不是真文件（比对哈希，防止拿到反爬网页）、git 协议能不能用。挑中一个当前真正能用的之后，把 GitHub 地址写进全局 git 配置。

### 常用命令

- `./hermes-cn.sh accel probe`：把所有候选节点挨个测一遍，看谁还能用
- `./hermes-cn.sh accel status`：看当前用的是哪个节点
- `./hermes-cn.sh accel download <GitHub 地址>`：下载一个 GitHub 文件，走当前节点
- `./hermes-cn.sh accel env`：打印环境变量，给不读 git 配置的工具用
- `./hermes-cn.sh accel uninstall`：撤销全部改动

### 几点说明

- **私有仓库不受影响。** 访问私有仓库必须带凭据，地址形如 `https://user@github.com/...`，和这里改写的 `https://github.com/` 对不上。
- **节点有快有慢，也会时好时坏。** 内置十几个候选，每次开启都会重新探测，节点坏了会自动换下一个。
- **只能下载的节点不会去改写 clone 的地址。** 万一挑到的节点只能下载，工具会明确告诉你，clone 仍然直连，免得 clone 直接失败。
- **大仓库可能还是会慢。** 节点是现拉的，小仓库几秒就好，大仓库要等它把仓库拉下来。
- **curl 这类工具不读 git 配置**，所以它们不会自动加速。用 `./hermes-cn.sh accel download <地址>` 下载，或者自己拿 `accel env` 里的地址去拼。
- **想加自己的节点**：在 `~/.hermes-cn/accel/nodes.txt` 里写一行「名称|替换地址|下载前缀|探测地址」，会和内置的一起被探测。

## 浏览器访问 GitHub

浏览器不读 Git 的配置，所以上面那套对浏览器没用。这个工具另外起了一个本地服务，浏览器通过它访问 GitHub，页面和图片、样式都走加速节点。

只需要 macOS 和 Linux，Windows 版暂时没有这个功能。

想看地址栏里显示真正的 `github.com`，用 Steam++（Watt Toolkit）那类工具更省事：它接管系统设置，浏览器完全感觉不到区别。代价是要装证书、改 hosts，而且会接管的不止 GitHub。这里做的是不用动系统的那一版。

### 开启

```bash
./hermes-cn.sh web
```

它会挑好节点、启动服务，然后自动打开浏览器。以后直接用这个窗口访问 GitHub 就行。

### 常用命令

- `./hermes-cn.sh web`：启动服务并打开浏览器
- `./hermes-cn.sh web serve`：只启动服务，不打开浏览器
- `./hermes-cn.sh web stop`：停掉服务
- `./hermes-cn.sh web clean`：清掉缓存
- `./hermes-cn.sh web status`：看服务状态和访问地址
- `./hermes-cn.sh web test`：自检

### 几点说明

- **不用装证书，也不用改系统设置。** 浏览器访问的是本机的一个普通网页地址，服务再帮你转到节点。停掉服务就完全恢复原样。
- **地址栏显示的是本机地址。** 用起来像访问 `127.0.0.1:8765`，不是 `github.com`。想看到真正的 GitHub 地址栏，得用 Steam++（Watt Toolkit）那类会接管系统 hosts 的工具——那个要装证书、要改系统设置，所以这里没做。
- **不要在这个窗口里登录 GitHub。** 登录要提交账号密码，而请求会经过第三方节点。查看代码、下载文件这些都没问题，涉及自己账号的操作请回到官方网址。
- **页面里的链接会自动跟着走。** 点仓库、翻页、下载文件，都还在加速通道里，不用手动改地址。
- **节点抽风会自动换一个。** 加速节点时好时坏，某个节点取不回内容时会自动试下一个，全都试不通才会显示提示页。
- **网页和样式可能走的是不同节点。** 各有所长，分开用反而更稳。
- **第一次打开会慢一点。** 页面里的样式和图片会先存到本地，之后再打开就快了。想清掉重来，用 `web clean`。

## 命令一览

- `./hermes-cn.sh`：进入加速环境交互 shell，退出即恢复原样。
- `./hermes-cn.sh run <命令>`：在加速环境里执行一条命令，原样返回它的退出码。
- `./hermes-cn.sh env`：打印可以导出的环境变量，用法是 `eval "$(./hermes-cn.sh env)"`。
- `./hermes-cn.sh doctor`：自检，检查镜像通不通、依赖清单是否正常、更新通道是否完好。
- `./hermes-cn.sh apply`：把依赖清单指向国内镜像，并让 Git 下载走镜像，长期生效。
- `./hermes-cn.sh restore`：撤销 `apply` 做过的全部改动。
- `./hermes-cn.sh install`：通过镜像全新安装 Hermes 到 `~/.hermes/hermes-agent`。
- `./hermes-cn.sh accel <子命令>`：GitHub 加速环境。
- `./hermes-cn.sh web <子命令>`：浏览器访问 GitHub 的加速。
- `./hermes-cn.sh help`：查看用法。

Windows 上把 `hermes-cn.sh` 换成 `hermes-cn.cmd` 即可，命令名完全相同。

选项：

- `--pypi-mirror <名称>`：跳过探测，强制使用指定的 PyPI 镜像。可选名称：清华、中科大、阿里云、腾讯云、北京外国语、华为云。
- `--git-mirror <地址>`：跳过探测，强制使用指定的 Git 镜像地址，默认是 GitCode。
- `--no-probe`：不做探测，直接用默认的首选源。
- `--yes, -y`：不询问，直接执行。
- `--version, -v`：显示版本。

## 它具体做了什么

**每次都重新挑一个能用的镜像。** 内置了清华、中科大、阿里云等几个国内镜像，启动时会挨个实际连一遍，用第一个连通的。某个镜像临时抽风或者限流了，下次启动自动换下一个，不用你手动改配置，也不会有「配好一次就过期」的问题。

**装 Python 依赖走国内镜像。** 安装和更新过程里需要的 Python 包，都从上面挑出来的镜像下载。

**拉 GitHub 仓库走镜像。** 下载代码、获取更新时用镜像地址，取到的仍然是同一个官方项目。

**仓库来源地址保持官方地址不变。** Hermes 是靠仓库地址判断这是不是官方渠道，如果把地址换成镜像，更新就可能被当成第三方来源而中断。所以这个工具只改「从哪儿下载」，不改「这是谁的仓库」。

**装不上的时候会说清楚。** 如果所有国内镜像都连不上，工具会直接报错，不会随便挑一个连不通的地址继续往下跑。

## 常见问题

**只下载 hermes-cn.sh 一个文件行不行？**

不行。这个脚本要配合同目录下的 `lib` 目录一起用，少一个文件都跑不起来（脚本会直接告诉你缺了哪几个）。下载整个压缩包最省事。

**解压之后提示 Permission denied 怎么办？**

加上执行权限再运行：`chmod +x hermes-cn.sh`。

**Windows 上中文参数乱码怎么办？**

指定镜像时改用英文别名（tuna、ustc、aliyun、tencent、bfsu、huawei），例如 `hermes-cn.cmd --pypi-mirror tuna run hermes update`。Windows PowerShell 5.1 传中文参数时容易变成乱码，英文别名没这个问题。

**怎么撤销？**

```bash
./hermes-cn.sh restore
```

依赖清单和 Git 配置都会还原成原样，回到完全直连的状态。

**某个镜像突然挂了怎么办？**

不用管。下次启动时会重新探测，自动换到下一个能用的镜像。想跳过探测、直接指定一个：

```bash
./hermes-cn.sh --pypi-mirror 阿里云 run hermes update
```

**它会改动我自己的 Hermes 程序文件吗？**

不会。它只动两样东西：依赖清单和 Git 配置。而且改动前都会先备份，一条 `restore` 就能全部还原。

**需要我的账号密码或者令牌吗？**

不需要。这个工具只处理网络通道，不涉及任何登录凭据，下载的也都是公开内容。

**我手改过仓库来源地址，怎么恢复？**

Hermes 是靠仓库来源地址判断这是不是官方渠道。如果地址被换成了别的（哪怕是本机路径），更新就可能被当成非官方来源而中断。恢复成官方地址：

```bash
cd ~/.hermes/hermes-agent
git remote set-url origin https://github.com/NousResearch/hermes-agent.git
```

**为什么仓库来源还保留着官方 GitHub 地址？**

因为 Hermes 会根据来源判断这是不是官方渠道。如果把来源换成镜像地址，更新就可能被当成非官方来源而中断。保留官方地址、只用镜像负责下载，两者不冲突。

**我已经装好 Hermes 了，还需要重新安装吗？**

不需要。直接 `./hermes-cn.sh run hermes update` 或者 `./hermes-cn.sh apply` 就能让已有的安装用上加速。只有想换到全新环境时，才需要 `./hermes-cn.sh install`。

## 许可证

本项目采用 MIT 许可证开源，欢迎提 Issue 和 Pull Request 一起把它做得更好用。

项目地址：https://github.com/Mofan2020/hermes-cn
