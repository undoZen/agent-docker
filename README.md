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
make token           # 生成固定的 local token → variants/mirasim/.env（make up 也会自动做）
make up              # 起容器（还没登录，会停在等待状态）
make login           # 另开一个终端，交互登录
make attach          # 登录后：打开「接入云端」
make status          # 看状态
make url             # 打印带 token 的网页地址，开新标签页贴进去
```

`make token` 不能省。serve 的 local token 默认每次启动随机生成，而前端把它缓存在
sessionStorage 里；不固定的话每次重建容器，旧标签页就永久 401。机制见「网页 401 / 403」一节。

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

## 网页 401 / 403：token 到底怎么传（有源码结论）

这一节是从 `v0.0.622` 的发布包里读出来的，不是猜的。发布包同时带二进制和前端产物：
`web/app/assets/index-*.js` 是前端，`mirasim` 里内嵌了打包后的服务端 JS（明文可读）。

先把结论放前面：

> **服务端只认 `?token=` 和 `Authorization: Bearer`，不读 cookie；
> 而前端只给 `/ws` 拼 token，其余请求一个都不带。**
>
> 所以单靠改 mirasim 的配置，`/api/*` 的 401 和网页配对的 403 都去不掉。
> 本仓库的解法是容器入口的 `forward-proxy.js`：用 `?token=` 换一个 HttpOnly cookie，
> 之后每个请求由它补上 `x-mirasim-token`（见「容器里那个转发器」一节）。

### 服务端怎么判定一个请求

`DTs(req, peerTunnelNonce, sameUserTransport)` 返回四种来源之一：

| 来源 | 条件 | 后果 |
|---|---|---|
| `local` | 没有 `env.incoming`（非 HTTP 通道），或 `sameUserTransport` 为真 | **直接放行** |
| `peer-tunnel` | 带了正确的 peer tunnel nonce 头 | 直接放行 |
| `loopback` | 对端是 `127.x` / `::1`（`RD()` 判定） | 要求 **local token** |
| `network` | 其他 | 要求 **access token** |

关键一行：

```js
let f8 = !!c4.socketPath;          // 这就是 sameUserTransport
R = f8 ? null : BTs();             // localToken 只在 TCP 模式下存在
```

也就是说 `sameUserTransport` 等价于「监听的是 unix domain socket」。而 `mirasim serve`
的 CLI 只解析 `--port/-p`、`--host`、`--workdir`、`--no-open`、`--no-im` —— **没有 `--socket`**：

```js
function ROu(b3){ /* …只认上面五个… */ return {kind:"serve", port:c4, bindHost:d5, workdir:f8, open:g5, im:h5} }
```

结论：**从 CLI 起的 serve 永远是 TCP 模式，永远走 token 校验**，没有「本机就免检」这个捷径。
`local` 那条分支只对桌面 App 内部调用有意义。

### token 本身

```js
function BTs(){ return Ns("LOCAL_TOKEN")?.trim() || randomBytes(32).toString("base64url") }
// Ns(x) === process.env["MIRASIM_" + x]
```

**不设 `MIRASIM_LOCAL_TOKEN` 就每次启动重新随机一把。** 这是本仓库所有 401 的总根源。
所以 `docker-compose.yml` 里有这个变量，值由 `make token` 生成到 `variants/mirasim/.env`
（compose 自动读，已 gitignore），`make up` 会先确保它存在。

三个投递位置服务端都认，但**没有一个走 cookie**：

```js
req.query("token") ?? req.header("x-mirasim-token")       // pair 等 TRUSTED 接口
req.query("token") / Authorization: Bearer <t>            // /api/* 中间件
```

### 前端做了什么

打开 `http://127.0.0.1:4939/?token=xxx` 时：

```js
const gee = "mirasim.localToken";
function MJt(){
  const t = new URL(location.href).searchParams.get("token");
  return t ? (sessionStorage.setItem(gee,t),
              /* 把地址栏里的 ?token= 删掉 */ history.replaceState(null,"",…), t)
           : sessionStorage.getItem(gee);
}
```

- 存进 **sessionStorage**（不是 localStorage，所以每个标签页各一份）
- 地址栏里的 token 被 `replaceState` **抹掉**
- WebSocket 地址是 `${ws|wss}://${host}/ws${token ? "?token="+… : ""}` —— **只有它会带**

普通请求走的是：

```js
function fV(e,t){ if(t?.mode!=="direct"||!t.host) return e; … }
//  本地模式 → 原样返回 "/api/state"，一个 token 都不加
```

`fetch(fV("/api/state", t))`、`fetch("/mirachannel/pair")` 都是这一路。
**你在 DevTools 里找不到 token 是正常的 —— 代码里就没有。**

页面主体数据走 WebSocket。没有转发器补 token 时：

- `/ws` 连上 → 网页正常用
- `/api/state` 401 → 顶栏版本号取不到，附带弹一个连接提示，不影响干活
- `/mirachannel/pair` 403 → 见下面

经过 `forward-proxy.js` 之后这两个都是 200。

### 所以正确的用法是

```bash
make token          # 首次；生成固定的 local token 到 variants/mirasim/.env
make up             # 会自动补上这一步
make url            # → http://127.0.0.1:4939/?token=xxxx
```

拿到地址**开一个新标签页**贴进去。注意 sessionStorage 是 per-tab 且不会自己清：

- 同一个标签页刷新 → 用里面的缓存，没问题
- **换了 token / 重建过容器之后，旧标签页刷多少次都是 401**，必须关掉重开
- 直接翻浏览器历史里那个地址也不行 —— token 早被 `replaceState` 删了

### `/mirachannel/pair` 为什么 403（前端的问题）

```js
ax = req => {
  let addr = QTn(req)?.remote?.address;
  if (!RD(addr)) return false;                          // ① 对端必须是回环
  let expect = localToken();
  let got = req.query("token") ?? req.header("x-mirasim-token");
  return rUe(got, expect);                              // ② 任一为空 → false
}
```

`rUe` 第一行就是 `if(!a2||!b3) return false`。前端那行是裸的 `fetch("/mirachannel/pair")`，
**query 和 header 都不带** → `got` 恒为 `undefined` → 恒 false。

所以直连 serve 时，网页上那个「把设备加到这台机器」的按钮**从来就不可能成功** ——
不是网络、不是 token 没设对。它大概是给桌面壳用的（那里能注入 header）。
经过 `forward-proxy.js` 就能用了，因为 header 由转发器补上。

也可以绕开网页，在容器内发请求，源地址天然是 127.0.0.1，token 我们补上：

```bash
make pair     # → {"ok":true, "code":"…", "hint":"paste the connection code into a client"}
```

把 `code` 粘到客户端。

### 容器里那个转发器是干什么的

serve 直接用 `--port` 监听时，**没有** `--host` 的话还会额外起一个「局域网直连」监听器，
绑到容器自己的 eth0（`172.x.0.2`）上。compose 给了 `MIRASIM_SERVER_HOST=127.0.0.1`，
那个监听器整个不启动，容器里只剩回环。

拓扑：

```
宿主机 127.0.0.1:4939 ──► 容器 :4938 (forward-proxy.js) ──► 127.0.0.1:4939 (serve)
                                                  对端恒为 127.0.0.1
```

**为什么必须转这一道**：docker 的端口映射会重写对端地址，serve 看到的是网桥网关
（`172.x.0.1`）→ `RD()` 为 false → 判成 `network` → 要 **access token**。
那时你拿 local token 去访问，报的是 `missing/bad access token`，方向就全错了。
转一道之后对端恒为 `127.0.0.1`，服务端才按 `loopback` 处理，你要的那把 local token 才是对的。

转发器（`variants/mirasim/forward-proxy.js`，镜像里有 node 就用它，否则退回 socat）
同时补 token：

1. 请求带了正确的 `?token=`（就是 `make url` 打开的那一下）→ 种 HttpOnly cookie `mirasim_local_token`
2. 带这个 cookie 的请求 → 补上 `x-mirasim-token` 头；WebSocket 只认 query，就补 `?token=`
3. 两者都没有 → 原样转发，serve 照常拒绝

没有 token 的人拿不到 cookie，所以认证强度没变。cookie 不像 sessionStorage 那样分标签页，
同一浏览器里重开标签页也能用；换了 token 之后重新打开一次 `make url` 即可。

代价：**任何能连到这个 docker 网络的人，请求都被当成「本机」**。token 仍然校验，
但「来自本机」这层信任没有了，所以别把不受信的容器塞进 `mirasim-net`。

不想要转发器：删掉 `MIRASIM_FORWARD_PORT`，`ports` 改回 `…:4939`，
然后 `?token=` 要换成 access token（从 `make pair` 的返回里拿），而不是 local token。

两个别走错方向的做法：

- **别改成 `network_mode: host`**。serve 是逐个地址监听的（`127.0.0.1`、`::1`、容器 eth0），
  换 host 网络会让清单里多出宿主机 `192.168.x.x`，等于把一个靠 token 保护的界面摆到局域网上。
- **别把端口绑到 `0.0.0.0`**。token 在 URL 里，URL 会进历史记录、会被截图，它就是凭据。

体检命令（容器里有 iproute2）：

```bash
docker compose -f variants/mirasim/docker-compose.yml exec mirasim ss -ltnp
# LISTEN 0.0.0.0:4938        ← 转发器 node（容器唯一的对外入口）
# LISTEN 127.0.0.1:4939      ← serve 本体
# LISTEN 127.0.0.11:xxxxx    ← docker 内嵌 DNS，无关
```

看到 `172.x.x.x:4939` 就说明 `MIRASIM_SERVER_HOST` 没生效，回去检查 compose。

## 五个必须记住的坑

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

**4. 家目录是卷，镜像里 root 留下的东西会被卷就地固化。**
`/home/agent` 挂成命名卷时，**卷第一次创建**会把镜像里该目录的内容复制进去，
之后镜像怎么改都不再影响这个卷。所以构建期一旦以 root 往家目录写过东西，毒就留住了。

真实踩过的例子：`ENV HOME=/home/agent` 之后、还没有 `USER` 切换时跑 `npm install`，
npm 的缓存落进 `/home/agent/.npm`（root 所有）；这个目录随卷固化，容器里的 agent 从此
写不了自己的 npm 缓存——

```
npm ERR! code EACCES
npm ERR! path /home/agent/.npm/_cacache/tmp/xxxxx
npm ERR! Your cache folder contains root-owned files, due to a bug in
npm ERR! previous versions of npm which has since been addressed.
```

最后那两行是 npm 的通用文案，会把人带偏；真实原因在这里。镜像做了两处修正：

- `NPM_CONFIG_CACHE=/var/tmp/npm-cache`（镜像层里，不在任何卷里），运行期 npm 根本不碰 `$HOME`；
- 构建期 npm `--cache /tmp/...` 用完即删，加上最后一层 `chown -R` 兜底。

**新卷**不会有这问题。**已有的卷**（毒已经固化进去了）要修一次，登录态会保留：

```bash
make fixperm
```

**5. `cap_drop: ALL` 之下，uid 0 不是 root。**

这条专门讲为什么上面那一步**不能**写成 `docker compose exec -u root mirasim chown -R ...`：

```bash
chown: cannot read directory '/home/agent': Permission denied
```

看着像「root 都没权限？」，其实是权限模型在正常运作。compose 里写了
`cap_drop: ALL`，容器的 uid 0 手上没有任何 capability，尤其是没有
`CAP_DAC_OVERRIDE` —— 那个才是「无视文件权限位」的能力。没有它，root 跟普通用户
一样受 mode bit 约束，连别人 700 的目录都 `readdir` 不了。

所以修卷属主必须**新起一个临时容器**：`docker run` 默认给完整 capability 集合，
那里的 root 才是真的 root。`make fixperm` 做的就是这件事：

```make
docker run --rm --user root \
  -v mirasim-home:/home/agent \
  -v mirasim-work:/home/agent/work \
  --entrypoint chown agent-docker-mirasim:1 \
  -R 1000:1000 /home/agent
```

（卷名如果被 `.env` 里的 `MIRASIM_HOME_VOLUME` 改过，Makefile 里同名变量也要跟着改。）

一句话：**硬化过的容器里，`-u root` 不等于能改任何人的文件；要特权就得开新容器。**

一句话：家目录凡是会挂卷的，构建期就别以 root 往里写；写了必须在最后一层 chown 回来。

## 和旧的 `mirasim-docker/` 的关系

`mirasim-docker/` 是单层版，功能与当前 `variants/mirasim` 等价，只是没把 base 抽出来。
新版跑通后可以直接删掉旧的。
