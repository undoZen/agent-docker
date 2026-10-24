BASE_TAG ?= agent-docker:1
MIRASIM_TAG ?= agent-docker-mirasim:1
VARIANT := variants/mirasim

# base 的构建参数，命令行可覆盖，例如： make base WITH_RUST=0
AGENT_CLIS ?= @anthropic-ai/claude-code
EXTRA_APT ?=
WITH_BROWSER ?= 1
WITH_GO ?= 1
WITH_RUST ?= 1
GO_VERSION ?= latest
MIRASIM_VERSION ?= stable
# 容器内 uid/gid 默认跟随构建机上执行 make 的人，解决 bind mount 权限问题。
# 这是身份的唯一来源：值被固化进镜像，运行时（compose / docker run）自动继承，
# 不需要在两处写同一个数字。要固定或给别的机器复现：
#    make base AGENT_UID=1000 AGENT_GID=1000
AGENT_UID ?= $(shell id -u)
AGENT_GID ?= $(shell id -g)

.DEFAULT_GOAL := help
.PHONY: help base mirasim all claude claude-shell up stop logs shell login attach status config down purge egress who check-uid url

help:
	@echo "构建"
	@echo "  make base        通用 agent 沙箱镜像  ($(BASE_TAG))"
	@echo "  make mirasim     mirasim 变体        ($(MIRASIM_TAG))，会先确保 base 存在"
	@echo "  make all         两个都构建"
	@echo ""
	@echo "直接用 base（不需要 mirasim）"
	@echo "  make claude      进 claude code 交互界面"
	@echo "  make claude-shell 只要一个带工具链的 bash"
	@echo "  WORKSPACE=~/proj make claude   让它在你自己的目录里干活"
	@echo ""
	@echo "运行 mirasim 变体"
	@echo "  make up / stop / logs / shell / config"
	@echo ""
	@echo "Mirasim"
	@echo "  make url         打印带 token 的本地 Web UI 地址（网页 401 就是这个）"
	@echo "  make login       交互登录，要 -it，会问邮箱和邮件验证码"
	@echo "  make attach      打开「接入云端」"
	@echo "  make status      看接入状态"
	@echo ""
	@echo "维护"
	@echo "  make who         看镜像内 uid 和宿主 uid 是否对齐（权限问题先看这个）"
	@echo "  make down        删容器、保卷（登录态还在）"
	@echo "  make purge       连卷一起删（登录态会丢）"
	@echo "  make egress      挡容器访问内网和云元数据地址"

base:
	@echo "→ 容器内用户 uid=$(AGENT_UID) gid=$(AGENT_GID)（宿主是 $$(id -u):$$(id -g)）"
	docker build -f base.Dockerfile -t $(BASE_TAG) --build-arg AGENT_CLIS="$(AGENT_CLIS)" --build-arg EXTRA_APT="$(EXTRA_APT)" --build-arg WITH_BROWSER=$(WITH_BROWSER) --build-arg WITH_GO=$(WITH_GO) --build-arg WITH_RUST=$(WITH_RUST) --build-arg GO_VERSION=$(GO_VERSION) --build-arg AGENT_UID=$(AGENT_UID) --build-arg AGENT_GID=$(AGENT_GID) .

mirasim: base
	docker build -f $(VARIANT)/Dockerfile --build-arg BASE_IMAGE=$(BASE_TAG) --build-arg MIRASIM_VERSION=$(MIRASIM_VERSION) -t $(MIRASIM_TAG) $(VARIANT)

all: mirasim
	@echo "完成：$(BASE_TAG) + $(MIRASIM_TAG)"

# 镜像里的 uid 是构建时烘焙进去的：拿别人构建的镜像、又要挂自己的目录，就会撞权限。
# 这里在运行前比对一次，省得在一堆 EACCES 里猜原因。
# 只看 BASE_TAG：base 的 Config.User 一定是数字（USER uid:gid 收尾），
# 而变体是 `USER agent`，Config.User 是字符串，得另外解析 —— 见 README。
#
# 写法注意（踩过一次）：macOS 自带的 GNU Make 3.81 在 `$$var` 后面紧跟中文时会算错
# 字节数、吞掉几个字符（`uid=1000，` 变成 `uid=，`）。必须写 `$${var}`。
# 构建机上的 4.x 没这毛病，但别指望它一定是 4.x。
check-uid:
	@img=$$(docker image inspect $(BASE_TAG) --format '{{.Config.User}}' 2>/dev/null | cut -d: -f1); \
	if [ -n "$$img" ] && [ "$$img" != "$$(id -u)" ]; then \
	  echo "⚠ $(BASE_TAG) 里的 uid=$${img}，而你当前是 uid=$$(id -u)"; \
	  echo "  → WORKSPACE 挂进来的目录在容器里会写不了（容器内身份是别的人）"; \
	  echo "  → 用你自己的 uid 重建：make base"; \
	fi

# 用 base 直接跑 claude code。这里的 --rm 只删掉这次会话结束后退出的临时容器，
# 登录态和配置都在 agent-home 卷里，删容器不影响。别跟服务容器的 restart 策略混为一谈。
# 不再往这里传 AGENT_UID/GID：身份在镜像里，传了也不会被消费（buildx 还会报警告）。
claude: check-uid
	docker compose -f compose.agent.yml run --rm claude

claude-shell: check-uid
	docker compose -f compose.agent.yml run --rm claude bash

up:
	cd $(VARIANT) && docker compose up -d

config:
	cd $(VARIANT) && docker compose config --quiet && echo "compose 配置 OK"

stop:
	cd $(VARIANT) && docker compose stop

logs:
	cd $(VARIANT) && docker compose logs -f mirasim

shell:
	cd $(VARIANT) && docker compose exec mirasim bash

login:
	cd $(VARIANT) && docker compose exec -it mirasim mirasim login email

attach:
	cd $(VARIANT) && docker compose exec mirasim mirasim ui-cli --port 4939 machines attach on

status:
	cd $(VARIANT) && docker compose exec mirasim mirasim ui-cli --port 4939 machines attach status

# 打印带 token 的本地 Web UI 地址。
# 为什么必须带：docker 的端口映射会把来源 IP 变成网桥网关（172.x.0.1），服务端把它
# 当远程请求，一律要求 access token；不带就是满屏 "missing/bad access token"。
# token 是持久的，存在容器的 ~/.mirasim/run/local-<端口>.token，随卷保留、重启不变。
# 前端拿到 ?token= 后存进 sessionStorage 并把地址栏里的 token 抹掉，所以同一标签页
# 内刷新不用重贴；关掉标签页再打开就得重新来一次。
url:
	@tok=$$(cd $(VARIANT) && docker compose exec -T mirasim cat /home/agent/.mirasim/run/local-4939.token 2>/dev/null | tr -d '\r\n'); \
	if [ -z "$$tok" ]; then \
	  echo "拿不到 token：容器没在跑，或 serve 还没起来（先 make up，等日志出现「开始 serve」）"; \
	  exit 1; \
	fi; \
	printf 'http://127.0.0.1:%s/?token=%s\n' "$${MIRASIM_HOST_PORT:-4939}" "$$tok"

down:
	cd $(VARIANT) && docker compose down

purge:
	cd $(VARIANT) && docker compose down -v

egress:
	sudo bash $(VARIANT)/egress-lockdown.sh

# 排查文件权限问题的第一步：镜像里的 uid 和宿主 uid 是不是同一个。
# 不一致的典型症状：bind mount 进来的目录在容器里写不了；或者容器产出的文件
# 在你这边显示成别人的、删不掉。
# 顺带也能确认 tag 下的镜像到底是不是本仓库构建的（构建时间 + Config.User）。
who:
	@printf '宿主     uid=%s gid=%s\n' "$$(id -u)" "$$(id -g)"
	@docker image inspect $(BASE_TAG) --format 'base     构建于 {{.Created}}  User={{.Config.User}}' 2>/dev/null \
	  || echo 'base     镜像不存在 —— 还没 make base，或 tag 被改过'
	@docker run --rm --network none $(BASE_TAG) id 2>/dev/null | sed 's/^/base     /' || true
	@docker image inspect $(MIRASIM_TAG) --format 'mirasim  构建于 {{.Created}}  User={{.Config.User}}' 2>/dev/null \
	  || echo 'mirasim  镜像不存在 —— 还没 make mirasim'
	@docker run --rm --network none --entrypoint id $(MIRASIM_TAG) 2>/dev/null | sed 's/^/mirasim  /' || true
