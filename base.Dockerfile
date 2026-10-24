# 通用 agent 沙箱基础镜像
#
# Debian 13 + 完整开发工具链 + 一个 agent CLI + 固定非 root 用户。
# 刻意不含任何特定产品的东西（Mirasim 那部分在 variants/ 里叠加），
# 所以换个宿主、换个 agent 都从这里起步。
#
#   docker build -f base.Dockerfile -t agent-docker:1 .
#   docker run --rm -it agent-docker:1            # 直接进去当普通 Linux 用
FROM --platform=linux/amd64 debian:trixie-slim

ARG AGENT_CLIS="@anthropic-ai/claude-code"
ARG EXTRA_APT=""
# 三个可选工具链，瘦身就设 0
ARG WITH_BROWSER=1
ARG WITH_GO=1
ARG WITH_RUST=1
# latest = 从 go.dev 的 JSON feed 取当前 stable；也可写死 1.27.3
ARG GO_VERSION=latest
ARG DEBIAN_FRONTEND=noninteractive

# PATH 写死而不用 ${PATH} 拼，避免上游镜像改基础 PATH 时这里悄悄变化。
# /opt/agents、/usr/local/go、/opt/rust 都是本文件后面装进去的。
ENV HOME=/home/agent \
    GOPATH=/home/agent/go \
    RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_PREFIX=/opt/agents \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    PATH="/opt/agents/bin:/usr/local/go/bin:/opt/rust/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 预装工具链。容器内是 uid 10001，apt install 用不了，所以「能自由干活」全靠这一层。
# 要再加东西优先用 EXTRA_APT，不用改下面的列表。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config autoconf automake libtool \
      python3 python3-pip python3-venv python3-dev \
      git openssh-client curl wget ca-certificates \
      xz-utils tar zip unzip rsync file coreutils \
      jq less procps tree sqlite3 \
      ripgrep fd-find \
      bind9-dnsutils iproute2 netcat-openbsd \
      libssl-dev zlib1g-dev libffi-dev libbz2-dev liblzma-dev \
      libreadline-dev libyaml-dev libsqlite3-dev \
      libxml2-dev libxslt1-dev libjpeg-dev libpng-dev libpq-dev \
      nodejs npm \
      ${EXTRA_APT} \
 && if [ "$WITH_BROWSER" = "1" ]; then \
      echo "==> chromium + CJK 字体"; \
      apt-get install -y --no-install-recommends \
        chromium fonts-noto-cjk fonts-noto-color-emoji fonts-liberation fonts-wqy-zenhei \
        libasound2t64 libgbm1 libxkbcommon0 libxshmfence1 libnss3 \
        libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 libcairo2 libx11-xcb1; \
    fi \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && rm -f /usr/lib/python3*/EXTERNALLY-MANAGED \
 && rm -rf /var/lib/apt/lists/*

# 固定非 root uid。10001 不和宿主机任何真实用户对应，也不在 1000-9999 的常见区间里。
RUN groupadd --gid 10001 agent \
 && useradd --uid 10001 --gid 10001 --create-home --home-dir /home/agent \
           --shell /bin/bash agent \
 && mkdir -p /home/agent/work \
 && chown -R 10001:10001 /home/agent

# agent CLI 装在 /opt/agents（家目录之外）。
# 放进家目录的话，一旦该目录被挂成卷，卷初始化之后就不会再随镜像更新。
# 目录对 agent 可写，所以容器里也能 `npm install -g <pkg>` 自由加 CLI。
RUN mkdir -p /opt/agents \
 && if [ -n "$AGENT_CLIS" ]; then \
      echo "==> install agent CLIs: $AGENT_CLIS"; \
      npm install -g --prefix /opt/agents --no-fund --no-audit $AGENT_CLIS; \
    else \
      echo "==> 未指定 AGENT_CLIS：镜像里不会有任何 agent CLI" >&2; \
    fi \
 && chown -R 10001:10001 /opt/agents

# ── Go：官方静态 tarball，版本与 sha256 都从 go.dev 的 JSON feed 取 ──
RUN if [ "$WITH_GO" = "1" ]; then \
      set -eu; \
      json="$(curl -fsSL 'https://go.dev/dl/?mode=json')"; \
      if [ "$GO_VERSION" = "latest" ]; then \
        ver="$(printf '%s' "$json" | jq -r '[.[] | select(.stable == true)][0].version')"; \
      else \
        ver="v${GO_VERSION#v}"; \
      fi; \
      file="$(printf '%s' "$json" | jq -r --arg v "$ver" \
        '.[] | select(.version == $v) | .files[] | select(.os == "linux" and .arch == "amd64" and .kind == "archive") | .filename' | head -n1)"; \
      sum="$(printf '%s' "$json" | jq -r --arg v "$ver" --arg f "$file" \
        '.[] | select(.version == $v) | .files[] | select(.filename == $f) | .sha256' | head -n1)"; \
      test -n "$file" && test -n "$sum"; \
      echo "==> Go $ver ($file)"; \
      curl -fL --retry 3 -o /tmp/go.tgz "https://go.dev/dl/$file"; \
      printf '%s  %s\n' "$sum" /tmp/go.tgz | sha256sum -c -; \
      tar -C /usr/local -xzf /tmp/go.tgz; \
      rm -f /tmp/go.tgz; \
      /usr/local/go/bin/go version; \
    fi

# ── Rust：官方 rustup，装到 /opt/rust（家卷会挡住后续更新）──
# minimal profile 只带 rustc / cargo / rust-std；要 clippy、rustfmt 就在容器里 rustup component add。
RUN if [ "$WITH_RUST" = "1" ]; then \
      set -eu; \
      mkdir -p /opt/rust; \
      curl -fsSL --retry 3 -o /tmp/rustup-init \
        https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init; \
      chmod +x /tmp/rustup-init; \
      /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain stable; \
      rm -f /tmp/rustup-init; \
      chown -R 10001:10001 /opt/rust; \
      /opt/rust/cargo/bin/cargo --version; \
    fi

# 故意不设 ENTRYPOINT：docker run -it 进来就是 bash，当普通 Linux 用。
# 各变体自己定义 ENTRYPOINT 覆盖这个 CMD。
USER 10001:10001
WORKDIR /home/agent/work
CMD ["bash"]
