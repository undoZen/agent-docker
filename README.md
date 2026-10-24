# agent-docker

一个通用的 **agent 沙箱基础镜像**，加上按产品叠加的**变体**。
base 里什么具体的宿主软件都没有，只解决「给别人一个能自由干活、但碰不到宿主机的 Linux 环境」；
Mirasim 这类东西全部放在 `variants/` 里，一层 `FROM` 叠上去。

```
agent-docker/
├── Makefile                    所有操作的入口（构建、启停、登录、排错）
├── base.Dockerfile             通用沙箱：工具链 + 浏览器 + Go/Rust + 一个 agent CLI
└── variants/
    └── mirasim/                在 base 上叠加 Mirasim 宿主
        ├── Dockerfile          只做「下载校验装 mirasim + 定义 ENTRYPOINT」
        ├── entrypoint.sh       serve 托管 / 未登录时等待
        ├── docker-compose.yml  硬化参数都在这里
        ├── .env.example
        └── egress-lockdown.sh  挡容器访问内网
```

## 为什么分成两层

| | 放在 base | 放在变体 |
|---|---|---|
| 内容 | Debian 13、工具链、chromium、Go、Rust、claude-code、uid 10001 | Mirasim 的二进制、entrypoint、compose |
| 换个宿主要不要重做 | 不用 | 新加一个目录 |
| 换 agent CLI 要不要重做 | 不用（`make base AGENT_CLIS=...`） | 无关 |

硬化和工具链只维护一份，这是分层的实际收益。

## 快速开始

```bash
cd agent-docker

make base            # 首次构建，下载量约 2.5GB，慢
make mirasim         # 在 base 上叠 Mirasim

make config          # 校验 compose
make up              # 起容器（还没登录，会停在等待状态）
make login           # 另开一个终端，交互登录
make attach          # 登录后：打开「接入云端」
make status          # 看状态
```

`make login` 需要交互终端（要敲邮箱和邮件验证码）。登录完成后不用重启容器——
entrypoint 每 5 秒轮询一次登录态，看到就自己开始 serve。

升级 Mirasim 版本：

```bash
make mirasim MIRASIM_VERSION=0.0.622 && make up
```

## base 单独用：直接跑 claude code

`compose.agent.yml` 把 base 起成一个「装机即用」的 claude code 容器，硬化参数和变体那套一致：

```bash
make claude          # 进 claude code
make claude-shell    # 只要一个带工具链的 bash
```

第一次会走登录：它打印一个链接，你在宿主机浏览器里打开授权，把回来的码贴进去。
登录态存在 `agent-home` 卷里，之后每次 `make claude` 直接进，不用再登。

想让它在**你自己的项目**上干活：

```bash
WORKSPACE=~/code/myproj make claude
```

⚠️ 容器里是 uid 10001。宿主机目录的属主如果是你（uid 1000），它只能读、不能写：

```bash
sudo chown -R 10001:10001 ~/code/myproj   # 代价：之后你在宿主机上编辑也得用 sudo
```

所以更省事的做法是用默认的命名卷，产物用 `docker cp` 取出来：

```bash
docker compose -f compose.agent.yml cp claude:/home/agent/work/out.zip ./out.zip
```

不想走交互登录就塞 API key（`.env` 已经在 `.gitignore` 里）：

```bash
echo 'ANTHROPIC_API_KEY=sk-ant-...' > .env
```

也可以完全绕开 compose：

```bash
docker run --rm -it agent-docker:1 bash
```

但那条路没有 `cap_drop: ALL`、资源限额、`no-new-privileges`，只适合调试，别拿它跑不受信的代码。

> 关于 `--rm`：这里它只删掉会话结束后退出的那个临时容器。登录态、`.claude` 配置都在 `agent-home`
> 卷里，删容器不影响，也没有需要自动重启的服务。

## base 的构建参数

| 参数 | 默认 | 作用 |
|---|---|---|
| `AGENT_CLIS` | `@anthropic-ai/claude-code` | 装哪些 agent CLI，多个空格分隔 |
| `EXTRA_APT` | 空 | 额外 apt 包，例：`imagemagick ffmpeg` |
| `WITH_BROWSER` | 1 | chromium + CJK 字体 + Playwright 运行库（~580MB） |
| `WITH_GO` | 1 | 官方 Go tarball，装到 `/usr/local/go` |
| `WITH_RUST` | 1 | 官方 rustup，装到 `/opt/rust` |
| `GO_VERSION` | latest | `latest` 从 go.dev 的 JSON feed 取并校验 sha256 |

```bash
make base WITH_RUST=0 WITH_BROWSER=0     # 瘦身版，约 1.2GB
make base AGENT_CLIS="@anthropic-ai/claude-code @openai/codex"
```

## 加一个新变体

比如想再挂一个别的宿主，或者只想起一个纯 codex 的：

```bash
mkdir -p variants/mine
```

`variants/mine/Dockerfile` 最小形态：

```dockerfile
ARG BASE_IMAGE=agent-docker:1
FROM ${BASE_IMAGE}

# base 以 USER 10001 收尾，装系统目录要切回 root
USER root
RUN curl -fsSL https://example.com/install.sh -o /tmp/i.sh \
 && sh /tmp/i.sh

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
USER 10001:10001
WORKDIR /home/agent/work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
```

然后在 Makefile 里复制一份 `mirasim` target 改名字即可。
compose 那边把 `image:` 和 hardening 块照抄——硬化参数是跟着**运行方式**走的，不跟着镜像走。

## 关键约束（写死在 base 里的）

- **uid 10001**，非 root、非 1000，和宿主机任何真实用户都不对应
- **agent CLI 装 `/opt/agents`**，不装家目录——家目录一旦挂成卷，卷初始化后就再也不会随镜像更新
- **Go 的 GOPATH 在 `/home/agent/go`**，在卷里，`go mod` 缓存能跨重建保留
- **Rust 在 `/opt/rust`** 且属主 10001，容器内能自己 `rustup component add` / `rustup update`
- **`EXTERNALLY-MANAGED` 已删**，否则 Debian 的 PEP 668 会拒绝 `pip install --user`
- **`NPM_CONFIG_PREFIX=/opt/agents`**，`npm install -g` 免 sudo
- **`fd-find` 已软链成 `fd`**（Debian 里的命令名是 `fdfind`）

## 三个必须记住的坑

**1. `bash -lc` 会丢掉 PATH（已被 profile.d 兜住）。**
Debian 的 `/etc/profile` 把 `PATH` 重置成系统默认值，login shell 一定读它。
所以 `ENV PATH` 里那三条自定义路径会被冲掉，症状是 `claude`、`go`、`cargo` 全部
`command not found`，而 `python3`、`node`、`chromium` 正常——因为它们本来就在 `/usr/bin`。
镜像里写了 `/etc/profile.d/10-agent-paths.sh` 补回来；如果你自建变体又要加新路径，也往那里加，
不要只改 `ENV PATH`。

**2. 容器里 Chromium 必须 `--no-sandbox`。**
`no-new-privileges` 让 `chrome-sandbox` 的 setuid 通道失效，Docker 默认 seccomp 又不给非特权
user namespace，Chrome 自带的沙箱起不来。它已经在容器里了，关掉浏览器沙箱是可接受的位置。

**3. 容器内写不了系统目录。**
`apt install` 注定失败（uid 10001）。要装系统包改 `EXTRA_APT` 重建；
`pip install` 要带 `--user` 或用 venv；`npm install -g` 正常可用。

## 和旧的 `mirasim-docker/` 的关系

`mirasim-docker/` 是单层版，功能与当前 `variants/mirasim` 等价，只是没把 base 抽出来。
新版跑通后可以直接删掉旧的。
