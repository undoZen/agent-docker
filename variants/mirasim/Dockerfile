# Mirasim 变体：在通用 agent 沙箱上叠一层 Mirasim 宿主
#
#   make base && make mirasim        # 推荐，从仓库根目录用 Makefile
#   docker build -f variants/mirasim/Dockerfile \
#     --build-arg BASE_IMAGE=agent-docker:1 -t agent-docker-mirasim:1 variants/mirasim
ARG BASE_IMAGE=agent-docker:1
FROM ${BASE_IMAGE}

ARG MIRASIM_VERSION=stable

ENV CDN="https://cdn-assets.mirasim.ai/mirasim/releases" \
    ARTIFACT="mirasim-linux-x64.tar.xz" \
    MIRASIM_INSTALL_DIR=/opt/mirasim \
    MIRASIM_HOME=/home/agent/.mirasim \
    MIRASIM_PORT=4939

# 这里刻意不写 `ENV MIRASIM_SECRET_STORE=off`。
# 它只是 mirasim 的一个开关（值就是 off），但变量名会被 BuildKit 的
# SecretsUsedInArgOrEnv 检查当成疑似凭据而报警 —— 那是按名字猜的启发式，误报。
# 这个变量由 entrypoint.sh 兜底（export ...:-off），compose 里也显式设了，功能不受影响。

# base 以非 root 用户收尾，装系统目录要切回 root
USER root

# 复刻 install.sh 的下载 / 校验 / 解包，但不跑它的登录和服务步骤：
#   登录强制要 /dev/tty，构建期不可能有；
#   服务在容器里由 entrypoint 直接托管，不该走脚本的 systemd / setsid 分支。
# 版本解析与脚本里的 stable 通道一致 —— 注意不能用 latest.json 顶层的 version，
# 那是 macOS dmg 那条线的版本号。
RUN set -eu; \
    ver="$MIRASIM_VERSION"; \
    if [ "$ver" = "stable" ]; then \
      feed="$(curl -fsSL "$CDN/latest.json")"; \
      ver="$(printf '%s' "$feed" | tr ',{}' '\n\n\n' \
        | awk '/"stable"[[:space:]]*:/ { s=1; next } s && /"version"/ { gsub(/.*"version"[[:space:]]*:[[:space:]]*"|".*/, ""); print; exit }')"; \
      if [ -z "$ver" ]; then \
        ver="$(printf '%s' "$feed" | tr ',{}' '\n\n\n' \
          | awk '/"version"/ { gsub(/.*"version"[[:space:]]*:[[:space:]]*"|".*/, ""); print; exit }')"; \
      fi; \
    fi; \
    case "$ver" in ''|*[!0-9.]*) echo "版本号无法解析: '$ver'" >&2; exit 1 ;; esac; \
    echo "==> Mirasim $ver"; \
    url="$CDN/v$ver/$ARTIFACT"; \
    curl -fL --retry 3 --retry-delay 2 -o /tmp/mirasim.tar.xz "$url"; \
    want="$(curl -fsSL "$url.sha256" | awk '{print $1}')"; \
    got="$(sha256sum /tmp/mirasim.tar.xz | awk '{print $1}')"; \
    if [ -z "$want" ] || [ "$want" != "$got" ]; then \
      echo "sha256 校验失败 want=$want got=$got" >&2; exit 1; \
    fi; \
    mkdir -p /tmp/unpack; \
    tar --no-same-owner -xJf /tmp/mirasim.tar.xz -C /tmp/unpack; \
    test -f /tmp/unpack/mirasim; \
    mkdir -p "$MIRASIM_INSTALL_DIR"; \
    for e in mirasim web ccm ccm-runtime.json; do \
      if [ -e "/tmp/unpack/$e" ]; then cp -a "/tmp/unpack/$e" "$MIRASIM_INSTALL_DIR/"; fi; \
    done; \
    printf '%s\n' "$ver" > "$MIRASIM_INSTALL_DIR/VERSION"; \
    chmod -R a-w,a+rX "$MIRASIM_INSTALL_DIR"; \
    chmod a+rx "$MIRASIM_INSTALL_DIR/mirasim"; \
    ln -sf "$MIRASIM_INSTALL_DIR/mirasim" /usr/local/bin/mirasim; \
    rm -rf /tmp/mirasim.tar.xz /tmp/unpack

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0644 forward-proxy.js /usr/local/lib/mirasim-forward-proxy.js

# 身份按「名字」回指，不写数字、也不引变量：
# `agent` 这个用户在 base 里是用 AGENT_UID/AGENT_GID 建出来的，
# 所以 USER agent 解析出来的 uid/gid 天然就是构建时那一个，
# 变体完全不需要知道具体数字，也就不存在两处对不齐的可能。
USER agent
WORKDIR /home/agent/work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
