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

MIRASIM_BIN="/opt/mirasim/mirasim"

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
