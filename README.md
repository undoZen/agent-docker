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
| 内容 | Debian 13、工具链、chromium、Go、Rust、claude-code、非 root 用户 | Mirasim 的二进制、entrypoint、compose |
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
make url             # 打开本地网页（地址必须带 token，见「网页 401」一节）
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

容器内的 uid/gid 默认跟随构建镜像时执行 `make` 的那个人（`AGENT_UID ?= $(shell id -u)`），
所以宿主机目录**天然可写**，产物属主也是你自己，不需要 chown。

只有镜像在别的机器上构建、uid 对不上时才需要：

```bash
sudo chown -R $(id -u):$(id -g) ~/code/myproj
```

要改 uid 只能在**构建时**改，改完重建（运行时改不生效，见下一节）：

```bash
make base AGENT_UID=1000 AGENT_GID=1000 && make mirasim
```

产物也可以直接从命名卷取出来：

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
| `AGENT_UID` / `AGENT_GID` | 构建机的 `id -u` / `id -g` | 容器内用户的 uid/gid，见「uid 的单一来源」 |

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

# base 以非 root 用户收尾，装系统目录要切回 root
USER root
RUN curl -fsSL https://example.com/install.sh -o /tmp/i.sh \
 && sh /tmp/i.sh

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
# 切回去只写名字：agent 这个用户的 uid 是 base 建它时定的，
# 写数字就得两边对齐，写变量又得指望 ENV 展开 —— 写名字两条都省了。
USER agent
WORKDIR /home/agent/work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
```

然后在 Makefile 里复制一份 `mirasim` target 改名字即可。
compose 那边把 `image:` 和 hardening 块照抄——硬化参数是跟着**运行方式**走的，不跟着镜像走。

## 关键约束（写死在 base 里的）

- **用户名固定 `agent`，号跟随构建机**：`whoami` 永远是 `agent`，但 uid/gid 取构建者的 `id -u`/`id -g`。
  名字是给人看的，号才是决定权限的——两者解耦，所以换个人 clone 下来 `make base`，号自动就是他的
- **agent CLI 装 `/opt/agents`**，不装家目录——家目录一旦挂成卷，卷初始化后就再也不会随镜像更新
- **Go 的 GOPATH 在 `/home/agent/go`**，在卷里，`go mod` 缓存能跨重建保留
- **Rust 在 `/opt/rust`** 且属主是该 uid，容器内能自己 `rustup component add` / `rustup update`
- **`EXTERNALLY-MANAGED` 已删**，否则 Debian 的 PEP 668 会拒绝 `pip install --user`
- **`NPM_CONFIG_PREFIX=/opt/agents`**，`npm install -g` 免 sudo
- **`fd-find` 已软链成 `fd`**（Debian 里的命令名是 `fdfind`）

## uid 的单一来源

uid/gid 只在一个地方决定，然后一路继承下去，**运行时不需要也不能再写一次**：

```
Makefile  AGENT_UID ?= $(shell id -u)        ← 唯一入口，默认就是当前用户
   ↓ --build-arg
base      ARG AGENT_UID → useradd --uid     ← 固化进 /etc/passwd
   ↓ USER ${AGENT_UID}:${AGENT_GID}         ← 写进镜像配置
变体      USER agent                        ← 按名字回指，不碰数字
   ↓
运行      compose 里没有 user:              ← 容器直接继承镜像身份
```

这样设计是因为「构建时定一个、运行时再指定一个相同的」必然会在某天错位：
镜像换了、`id -u` 在另一台机器上变了，或者只是复制 compose 时漏改一行。

所以：

- `make base` 默认就用你的 `id -u` / `id -g`，什么都不用传（构建前会打印一行提示，顺手核对）
- 想换就只在构建时换：`make base AGENT_UID=1000 AGENT_GID=1000 && make mirasim`
- 确认两边对不对得上：`make who` —— 一次列出宿主 uid/gid、两个镜像的构建时间和 `Config.User`、以及容器里 `id` 的实际输出

`make who` 还有一个用处：判断某个 tag 下的镜像是不是本仓库构建的。镜像被别人的同名项目占了、
或者残留了旧版本时，`User` 和构建时间会立刻露馅。

### 两个边界情况（已处理）

换个 uid 不是「改个数字」那么简单，基础镜像里已经有一批账号占着号：

- **gid 已被占用** → 复用那个组，不再硬建。Debian 的 `100` 是 `users`、`20` 是 `dialout`、
  `50` 是 `staff`。所以 gid=100 的人构建后 `id` 会显示 `gid=100(users)`，
  组名不如 `agent` 好看，但**号是对的**，权限对齐不受影响。
- **uid 已被占用**（基础镜像的系统账号，比如 `0`、`42`）→ 不复用，直接失败并提示换号。
  复用会让镜像里某个系统账号忽然变成你的主身份，牵连的东西太多，不如早点报错。

用户名则永远是 `agent`，不受这两条影响——`useradd` 里那个名字是写死的。

换来的是：bind mount 的目录天然可写，不用 `chown`；容器里产生的文件在宿主机上属主就是你，
不会出现「root 所有的文件删不掉」。

代价只有一条，但得知道：**默认 Docker 下容器 uid 就是宿主机 uid，中间没有映射**。
所以万一真的发生内核层面的容器逃逸（极罕见），逃出来的进程直接拥有你这个 uid 的权限；
如果用的是宿主机上不存在的 uid（比如 10001），它逃出来什么都碰不到。

但主要防线始终是 `cap_drop: ALL` + 一个 bind mount 都没有 + 非 root，而不是 uid 的数值大小。
想两头都要，就开 daemon 级 `userns-remap`，让 uid 在宿主侧再错位一次。

## 一台机器两个用户（或者说：拿别人的镜像用）

镜像里的 uid 是**构建时**烘焙的，所以「a 构建、b 使用」有两种坏法，症状完全不同：

| 做法 | 容器里 | 挂载的目录 |
|---|---|---|
| b 直接跑 a 构建的镜像 | 完全正常（两边都是 a 的 uid） | `WORKSPACE=~/proj` **写不了**——目录属主是 b，容器内是 a |
| b 用自己的 uid 重建 | 正常 | `~/proj` 正常，但 `/home/agent` 报 EACCES——`agent-home` 卷里是 a 留下的文件 |

`make claude` / `make claude-shell` 现在会先跑 `check-uid`，两边 uid 不一致时打一行警告，
不用等到几十个 EACCES 再去猜。

按场景挑解法：

1. **各自机器**（最常见）：什么都不用做，`make base` 自动用各自的 uid。
2. **共用一个 daemon、互不干扰**：把卷名和 tag 都分开。卷名写在仓库根的 `.env` 里
   （已被 gitignore，compose 会自动读）：
   ```bash
   AGENT_HOME_VOLUME=agent-home-b
   AGENT_WORK_VOLUME=agent-work-b
   ```
   但 `.env` 只作用于 compose，`make base` 的 tag 还得从命令行传：
   ```bash
   make base BASE_TAG=agent-docker:b
   ```
   这样两边的家目录、登录态、镜像都不互相踩，`make purge` 也只删自己的。
3. **偶尔借用一次**：强行覆盖运行身份，不重建
   ```bash
   docker compose -f compose.agent.yml run --rm --user $(id -u):$(id -g) claude
   ```
   代价是 `/home/agent` 仍然属于 a，`.claude` 配置和 npm 缓存可能报 EACCES。

一句话原则：**构建者的 uid 必须等于使用者的 uid**，对不上就换卷名，或者干脆重建。

## 网页 401：`missing/bad access token`

**不是转发或权限问题，是服务端自己的回环判定。** 请求确实到了服务端（日志里 server 收到了、然后主动拒绝）。

`mirasim serve` 只信任两类请求：同一用户的 unix socket，以及带了 access token 的请求。
Docker 的端口映射会把来源 IP 换成网桥网关（`172.x.0.1`），于是浏览器被当成远程访问，
每个请求都要 `?token=`，不带就满屏 `missing/bad access token`。

token 是持久的，存在容器的 `~/.mirasim/run/local-4939.token`（在 `mirasim-home` 卷里，重启不变）：

```bash
make url      # → http://127.0.0.1:4939/?token=xxxxxxxx
```

拿到的地址直接贴浏览器。服务端三种投递方式都认：`?token=`、`Authorization: Bearer …`、
`x-mirasim-token` 头。前端读到 `?token=` 后会存进 sessionStorage 并把地址栏里的 token 抹掉，
所以同一标签页内刷新无感；**关掉标签页再打开就要重新 `make url` 一次**。

两个别走错方向的猜测：

- **改成 `network_mode: host` 没用**。回环来源走的是另一条分支，同样校验 local token，一样要带。
- **不要为了省事把端口绑到 `0.0.0.0`**。token 在 URL 里，等于凭据；现在绑 `127.0.0.1` 才是安全的。

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
`apt install` 注定失败（非 root 用户）。要装系统包改 `EXTRA_APT` 重建；
`pip install` 要带 `--user` 或用 venv；`npm install -g` 正常可用。

## 和旧的 `mirasim-docker/` 的关系

`mirasim-docker/` 是单层版，功能与当前 `variants/mirasim` 等价，只是没把 base 抽出来。
新版跑通后可以直接删掉旧的。
