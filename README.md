# hermes-cn

hermes-cn 是给大陆网络环境用的 Hermes Agent 加速工具。GitHub 拉不动、pip 装不上、`hermes update` 卡在半路——把这些麻烦一次性解决：运行时自动挑一个能用的国内镜像，把 Hermes 的安装和更新通道准备好，让你直接跑 `hermes update`、官方的 `bash scripts/install.sh`，以及任何需要联网的命令。

只做一件事：让 Hermes 在大陆网络下能顺利装上、更新、跑起来。

## 为什么需要它

- `hermes update` 卡住不动，或者中途报网络错误，版本停在半路上。
- 官方安装脚本跑一半失败，依赖下载速度只有几 KB/s，甚至直接超时。
- `pip install` 依赖装不上，`git clone` 官方仓库连不上，只能干等。
- 手动配镜像很快就会失效：换一个镜像、换个网络环境，之前配的全白费。

## 快速开始

先把仓库拉下来并进入目录：

```bash
git clone https://github.com/Mofan2020/hermes-cn.git
cd hermes-cn
```

先自检一下，看当前网络下各镜像通不通：

```bash
./hermes-cn.sh doctor
```

最常见的用法，是在一个命令上加速。更新 Hermes：

```bash
./hermes-cn.sh run hermes update
```

跑官方安装脚本：

```bash
./hermes-cn.sh run bash scripts/install.sh
```

想长期用下去，让加速配置一直生效：

```bash
./hermes-cn.sh apply
```

`apply` 之后，直接在终端里跑 `hermes update` 就行，不用再带前缀。

如果只想临时用，进入一个加速过的 shell，退出后一切恢复正常：

```bash
./hermes-cn.sh
```

## 命令一览

- `./hermes-cn.sh`：进入加速环境交互 shell，退出即恢复原样。
- `./hermes-cn.sh run <命令>`：在加速环境里执行一条命令，原样返回该命令的退出码。
- `./hermes-cn.sh env`：打印可导出的环境变量，用于 `eval "$(./hermes-cn.sh env)"`。
- `./hermes-cn.sh doctor`：自检，检查镜像可用性、依赖清单完整性、更新通道状态。
- `./hermes-cn.sh apply`：改写依赖清单指向镜像并配置 Git 传输层，持久生效。
- `./hermes-cn.sh restore`：撤销 `apply` 做过的全部改动。
- `./hermes-cn.sh install`：通过镜像全新安装 Hermes 到 `~/.hermes/hermes-agent`。
- `./hermes-cn.sh help`：查看用法。

选项：

- `--pypi-mirror <名称>`：跳过探测，强制使用指定 PyPI 镜像。可选名称：清华、中科大、阿里云、腾讯云、北京外国语、华为云。
- `--git-mirror <地址>`：跳过探测，强制使用指定的 Git 镜像地址，默认是 GitCode。
- `--no-probe`：不做探测，直接用默认首选源。
- `--yes, -y`：不询问，直接执行。
- `--version, -v`：显示版本。

## 它做了什么

**自动挑选当前能用的镜像。** 内置了多个候选源，每次启动都实际连一遍，挑出真正响应最快的那个。这是最关键的一点：如果某个镜像临时抽风、限流或者挂了，下次启动会自动换到下一个可用的镜像，不需要你手动去改配置。也因此不存在「配好一次就一直用」的过期配置。

**Python 依赖走国内镜像。** 安装和更新过程中需要的 Python 包，都从探测出来的国内镜像下载，速度和稳定性都远好于直连。

**GitHub 走镜像通道。** 拉取仓库、获取更新时使用镜像地址，代码仍然来自同一个官方项目。

**官方地址作为兜底。** 如果所有镜像都连不上，会退回官方直连，至少不会卡死在半路。

**原始 GitHub 地址保持不变。** Hermes 记录的仓库来源始终是官方地址，所以更新通道不会被判定成第三方来源，后续的版本更新照常被识别和接受。

## 常见问题

**怎么撤销？**

```bash
./hermes-cn.sh restore
```

会把依赖清单和 Git 配置都还原成原样，回到完全直连的状态。

**某个镜像突然挂了怎么办？**

不用管。下次启动时它会重新探测，自动切到下一个可用的镜像。如果你想跳过探测、强制指定一个，可以这样：

```bash
./hermes-cn.sh --pypi-mirror 阿里云 run hermes update
```

**它会改动我自己的 Hermes 程序文件吗？**

不会。它只动两样东西：依赖清单和 Git 配置。而且这些改动都有备份，一条 `restore` 就能全部还原。

**需要我的账号密码或者令牌吗？**

不需要。这个工具只处理网络通道，不涉及任何登录凭据，下载的也都是公开内容。

**为什么仓库来源还保留着官方 GitHub 地址？**

因为 Hermes 会根据来源判断这是不是官方渠道。如果把来源换成镜像地址，更新就可能被当成非官方来源而中断。保留官方地址、用镜像只负责传输，两者互不冲突。

**我已经装好 Hermes 了，还需要重新安装吗？**

不需要。直接 `./hermes-cn.sh run hermes update` 或者 `./hermes-cn.sh apply` 就能让已有的安装用上加速。只有想换到全新环境时，才需要 `./hermes-cn.sh install`。

## 许可证

本项目采用 MIT 许可证开源，欢迎提 Issue 和 Pull Request 一起把它做得更好用。

项目地址：https://github.com/Mofan2020/hermes-cn
