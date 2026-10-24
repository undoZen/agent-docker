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
