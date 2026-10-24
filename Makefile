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

.DEFAULT_GOAL := help
.PHONY: help base mirasim all claude claude-shell up stop logs shell login attach status config down purge egress

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
	@echo "  make login       交互登录，要 -it，会问邮箱和邮件验证码"
	@echo "  make attach      打开「接入云端」"
	@echo "  make status      看接入状态"
	@echo ""
	@echo "维护"
	@echo "  make down        删容器、保卷（登录态还在）"
	@echo "  make purge       连卷一起删（登录态会丢）"
	@echo "  make egress      挡容器访问内网和云元数据地址"

base:
	docker build -f base.Dockerfile -t $(BASE_TAG) --build-arg AGENT_CLIS="$(AGENT_CLIS)" --build-arg EXTRA_APT="$(EXTRA_APT)" --build-arg WITH_BROWSER=$(WITH_BROWSER) --build-arg WITH_GO=$(WITH_GO) --build-arg WITH_RUST=$(WITH_RUST) --build-arg GO_VERSION=$(GO_VERSION) .

mirasim: base
	docker build -f $(VARIANT)/Dockerfile --build-arg BASE_IMAGE=$(BASE_TAG) --build-arg MIRASIM_VERSION=$(MIRASIM_VERSION) -t $(MIRASIM_TAG) $(VARIANT)

all: mirasim
	@echo "完成：$(BASE_TAG) + $(MIRASIM_TAG)"

# 用 base 直接跑 claude code。这里的 --rm 只删掉这次会话结束后退出的临时容器，
# 登录态和配置都在 agent-home 卷里，删容器不影响。别跟服务容器的 restart 策略混为一谈。
claude:
	docker compose -f compose.agent.yml run --rm claude

claude-shell:
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

down:
	cd $(VARIANT) && docker compose down

purge:
	cd $(VARIANT) && docker compose down -v

egress:
	sudo bash $(VARIANT)/egress-lockdown.sh
