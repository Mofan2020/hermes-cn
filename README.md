# hermes-cn

hermes-cn 是给大陆网络环境用的 Hermes Agent 加速工具。

GitHub 拉不动、pip 装不上、`hermes update` 卡在半路——这类问题装上这个工具就能绕过去。它会在每次启动时挨个连一遍内置的国内镜像，挑一个当前真正能用的用上，然后你可以直接跑 `hermes update`、官方的 `bash scripts/install.sh`，或者任何需要联网的命令。

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

## 命令一览

- `./hermes-cn.sh`：进入加速环境交互 shell，退出即恢复原样。
- `./hermes-cn.sh run <命令>`：在加速环境里执行一条命令，原样返回它的退出码。
- `./hermes-cn.sh env`：打印可以导出的环境变量，用法是 `eval "$(./hermes-cn.sh env)"`。
- `./hermes-cn.sh doctor`：自检，检查镜像通不通、依赖清单是否正常、更新通道是否完好。
- `./hermes-cn.sh apply`：把依赖清单指向国内镜像，并让 Git 下载走镜像，长期生效。
- `./hermes-cn.sh restore`：撤销 `apply` 做过的全部改动。
- `./hermes-cn.sh install`：通过镜像全新安装 Hermes 到 `~/.hermes/hermes-agent`。
- `./hermes-cn.sh help`：查看用法。

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
