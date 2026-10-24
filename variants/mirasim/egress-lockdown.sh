#!/usr/bin/env bash
# 挡住容器出网到内网 / 云元数据地址。
# 默认 Docker 桥接允许容器访问你整个 LAN，而 agent 会执行陌生人给的命令，这条通路必须掐掉。
#
#   sudo bash egress-lockdown.sh
#
# 只处理 IPv4。撤销方式脚本末尾会打印。
set -euo pipefail

CHAIN=MIRASIM-EGRESS
NETWORK=mirasim-net

if ! command -v iptables >/dev/null 2>&1; then
  echo "找不到 iptables。Debian 13 上先装：apt install -y iptables" >&2
  exit 1
fi

SUBNET="$(docker network inspect "$NETWORK" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
if [ -z "$SUBNET" ]; then
  echo "查不到网络 $NETWORK 的网段。先在 variants/mirasim 里 docker compose up -d" >&2
  exit 1
fi
echo "容器网段：$SUBNET"

# 建链（存在就清空，保证可重复执行）
iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

# 顺序很重要：先放行自己网段和已建立连接，再挡私有地址
iptables -A "$CHAIN" -d "$SUBNET" -j RETURN
iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
for net in 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8; do
  iptables -A "$CHAIN" -d "$net" -j DROP
done
iptables -A "$CHAIN" -j RETURN

# 挂到 DOCKER-USER（幂等）
if ! iptables -C DOCKER-USER -s "$SUBNET" -j "$CHAIN" 2>/dev/null; then
  iptables -I DOCKER-USER -s "$SUBNET" -j "$CHAIN"
fi

echo
echo "已生效。现在容器访问你 LAN、路由器后台、169.254.169.254 都会被丢掉。"
echo "验证： docker compose exec mirasim curl -m 3 -sS http://192.168.1.1/   # 应超时"
echo
echo "撤销："
echo "  iptables -D DOCKER-USER -s $SUBNET -j $CHAIN"
echo "  iptables -F $CHAIN && iptables -X $CHAIN"
echo
echo "注意：规则在重启后消失。要持久化请装 iptables-persistent 并 netfilter-persistent save。"
