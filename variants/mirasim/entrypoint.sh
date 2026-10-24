#!/bin/sh
# Mirasim 变体入口：把 `mirasim serve` 托管成容器主进程。
# 容器里没有 systemd，也不该用 install.sh 里的 setsid 后台模式。
set -eu

export HOME="${HOME:-/home/agent}"
export MIRASIM_HOME="${MIRASIM_HOME:-$HOME/.mirasim}"
export MIRASIM_PORT="${MIRASIM_PORT:-4939}"
export MIRASIM_SECRET_STORE="${MIRASIM_SECRET_STORE:-off}"
# base 镜像已经把 /opt/agents、/usr/local/go、/opt/rust 都放进 PATH 了，
# 这里只做前置加固，不要整体覆盖 —— 否则 go / cargo 会消失。
export PATH="/opt/agents/bin:$PATH"

# 家目录是命名卷，镜像里任何以 root 留下的痕迹都会跟着卷固化，之后 agent 就写不了。
# 最典型的是构建期 npm 缓存（root 所有的 ~/.npm）——表现为 npm ERR! EACCES
# .../_cacache。这里提前点出来，并给出可以直接复制的修法。
if [ -e "$HOME/.npm" ] && [ ! -w "$HOME/.npm" ]; then
  echo "⚠ $HOME/.npm 不可写（属主 $(ls -ld "$HOME/.npm" | awk '{print $3}')，当前 uid $(id -u)）：npm 会报 EACCES" >&2
  # 注意不要写成 `docker compose exec -u root mirasim chown ...`：
  # 本容器是 cap_drop: ALL 起来的，uid 0 没有 CAP_DAC_OVERRIDE，
  # 连别人 700 的目录都 readdir 不了，会直接 Permission denied。
  # 得在宿主上另起一个临时容器（带完整 capability）来做。
  echo "  修：在宿主机仓库目录执行 make fixperm" >&2
fi

MIRASIM_BIN="/opt/mirasim/mirasim"

# ── local access token ──────────────────────────────────────────────
# 源码事实（v0.0.622）：
#   BTs() => env.MIRASIM_LOCAL_TOKEN?.trim() || randomBytes(32).toString("base64url")
# 不设这个环境变量，serve 每次启动就换一把新钥匙。而前端把 token 存进
# sessionStorage（键 mirasim.localToken）、只给 /ws 拼 ?token=，
# 所以服务一重启，开着的标签页里那把旧 key 立刻作废 ——
# 症状正是 /ws refused "missing/bad local token" 加满屏 /api/* 401。
#
# 正常路径：由 compose 从 variants/mirasim/.env 注入（`make token` 生成），
# 这里什么都不用做，值在容器重建后依然不变。
# 下面这段只是兜底：有人直接 docker run 起来、没经过 .env 时，
# 至少让同一个卷里的 token 别每次都变。
if [ -z "${MIRASIM_LOCAL_TOKEN:-}" ]; then
  tok_file="$MIRASIM_HOME/local-token"
  if [ -r "$tok_file" ] && [ -s "$tok_file" ]; then
    MIRASIM_LOCAL_TOKEN="$(cat "$tok_file")"
    export MIRASIM_LOCAL_TOKEN
  elif mkdir -p "$MIRASIM_HOME" 2>/dev/null && [ -w "$MIRASIM_HOME" ]; then
    head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_' > "$tok_file"
    chmod 600 "$tok_file" 2>/dev/null || true
    MIRASIM_LOCAL_TOKEN="$(cat "$tok_file")"
    export MIRASIM_LOCAL_TOKEN
  else
    echo "⚠ 没设 MIRASIM_LOCAL_TOKEN，且 $MIRASIM_HOME 不可写：" >&2
    echo "  只能退回随机 token，每次重启网页地址都会变（旧标签页会 401）。" >&2
    echo "  修：在宿主机仓库目录执行 make token && make up" >&2
  fi
fi

# ── 前置转发器（可选）───────────────────────────────────────────────
# 为什么需要：serve 的对端判定只看 TCP 源地址。经 docker 端口映射进来的请求，
# 源地址是网桥网关（172.x.0.1），于是被当成远程 —— 回环限制的接口（/mirachannel/pair、
# /remote、getDevices…）直接 403，普通接口则要求 access token。
# 让转发器在容器内重新发起连接，对端就永远是 127.0.0.1，语义回到「本机」。
# 配合 compose 里的 MIRASIM_SERVER_HOST=127.0.0.1：serve 自己不再绑容器 eth0，
# 对外只剩这一个入口。
# 代价：任何能连到这个 docker 网络的人，其请求都会被当作本机请求（仍需 token）。
if [ -n "${MIRASIM_FORWARD_PORT:-}" ]; then
  if command -v socat >/dev/null 2>&1; then
    forward() {
      while :; do
        # backlog 默认只有 5，而网页一次加载会并发拉一堆资源 + 一条 WS，
        # 峰值时会被内核丢连接（偶发白屏、刷新又好）。抬到 128。
        socat "TCP-LISTEN:${MIRASIM_FORWARD_PORT},fork,reuseaddr,backlog=128" \
              "TCP:127.0.0.1:${MIRASIM_PORT}" 2>/dev/null \
          || { echo "⚠ socat 转发退出（${MIRASIM_FORWARD_PORT} 被占用？），1 秒后重试" >&2; sleep 1; }
      done
    }
    forward &
    echo "→ 转发已启动：容器 :${MIRASIM_FORWARD_PORT} → 127.0.0.1:${MIRASIM_PORT}（对端恒为回环）"
  else
    echo "⚠ 没装 socat，跳过转发；此时只能从容器内部访问 Web UI" >&2
  fi
fi

if [ -z "${1:-}" ]; then
  set -- serve
fi
case "$1" in
  -*) set -- serve "$@" ;;
esac

signed_in() {
  [ -f "$MIRASIM_HOME/setting.json" ] \
    && grep -q '"refreshToken"' "$MIRASIM_HOME/setting.json" 2>/dev/null
}

case "$1" in
  serve)
    # 未登录时不退出：容器保持运行，登录完成后自己接手。
    # 这样整个流程只用 up + exec，不需要 `docker compose run`（也就没有一次性容器）。
    if ! signed_in; then
      cat >&2 <<'EOF'
⏳ 还没有登录，先等着。

  另开一个终端执行（要有交互终端，要点开邮件里的验证码）：

      docker compose exec -it mirasim mirasim login email

  登录态写进 mirasim-home 卷。这个进程每 5 秒看一次，
  一旦看到 refreshToken 就自己开始 serve，不用重启容器。
EOF
      while ! signed_in; do sleep 5; done
      echo "→ 检测到登录态，开始 serve（端口 $MIRASIM_PORT）"
    fi
    shift || true
    exec "$MIRASIM_BIN" serve --no-open --port "$MIRASIM_PORT" "$@"
    ;;
  *)
    # login / ui-cli / version … 原样交给 CLI
    exec "$MIRASIM_BIN" "$@"
    ;;
esac
