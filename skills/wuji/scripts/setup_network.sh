#!/usr/bin/env bash
# Wuji Glove 网络配置 —— 给接手套的网卡配静态 IP + /32 主机路由。
#
# 为什么需要 /32 路由:
#   多网卡机器上常有不止一张网卡落在 192.168.1.0/24（比如另一张业务网卡是 .165）。
#   两条 /24 路由互相竞争时，去手套的流量会随机走错网卡，表现为「时通时不通」。
#   调 metric 不可靠（别的网卡的 metric 不归你管）；给手套 IP 各加一条 /32 主机路由，
#   最长前缀匹配优先于任何 metric，一定赢。
#
# 用法:
#   ./setup_network.sh <网卡>                    # 本机用 192.168.1.10/24
#   ./setup_network.sh <网卡> 192.168.1.20       # 自定义本机 IP
#   ./setup_network.sh --show                    # 只看当前状态，不改配置
#
# 网卡名怎么找:  ip -br link | grep '^enx'   （USB 网卡名形如 enx<MAC>）

set -euo pipefail

CON="wuji-glove"
GLOVE_L="192.168.1.100"
GLOVE_R="192.168.1.101"

show() {
  echo "=== nmcli profile: $CON ==="
  if nmcli connection show "$CON" >/dev/null 2>&1; then
    nmcli connection show "$CON" \
      | grep -E "connection.id|connection.interface-name|ipv4.addresses|ipv4.routes|ipv4.method"
  else
    echo "  (不存在)"
  fi

  echo
  echo "=== 设备与连接绑定 ==="
  nmcli -f DEVICE,TYPE,STATE,CONNECTION device status | grep -E "DEVICE|ethernet"

  echo
  echo "=== 实际生效的地址（profile 正确 != 配置生效！）==="
  ip -br addr | grep -E "^(en|eth)"

  echo
  echo "=== 去手套的流量走哪张网卡 ==="
  for ip in "$GLOVE_L" "$GLOVE_R"; do
    printf "  %-16s -> %s\n" "$ip" "$(ip route get "$ip" 2>/dev/null | head -1 || echo '无路由')"
  done
}

if [ "${1:-}" = "--show" ]; then show; exit 0; fi

IF="${1:-}"
SELF="${2:-192.168.1.10}"

if [ -z "$IF" ]; then
  echo "用法: $0 <网卡> [本机IP]   |   $0 --show"
  echo
  echo "候选 USB 网卡:"
  ip -br link | grep -E "^enx" || echo "  (没有发现 USB 网卡 —— 先查转接盒是否插好，见 bringup.md §2)"
  exit 1
fi

if [ ! -e "/sys/class/net/$IF" ]; then
  echo "错误: 网卡 $IF 不存在。现有网卡:"
  ip -br link | grep -E "^(en|eth)"
  exit 1
fi

echo ">> 目标网卡: $IF    本机 IP: $SELF/24"
echo ">> 手套 IP:  $GLOVE_L (左) / $GLOVE_R (右)"
echo

if nmcli connection show "$CON" >/dev/null 2>&1; then
  # profile 已存在 —— 常见情况是换了转接盒导致 interface-name 失配（见 troubleshooting A6）
  OLD=$(nmcli -g connection.interface-name connection show "$CON")
  if [ "$OLD" != "$IF" ]; then
    echo ">> profile 原本绑在 '$OLD'，改绑到 '$IF'"
  fi
  sudo nmcli connection modify "$CON" \
       connection.interface-name "$IF" \
       ipv4.method manual \
       ipv4.addresses "$SELF/24"
else
  echo ">> 创建 profile $CON"
  sudo nmcli connection add type ethernet ifname "$IF" con-name "$CON" \
       ipv4.method manual ipv4.addresses "$SELF/24"
fi

# 关键一步：把两个手套 IP 钉死在这张网卡上
sudo nmcli connection modify "$CON" ipv4.routes "$GLOVE_L/32,$GLOVE_R/32"

# 不抢默认路由 —— 手套网段没有网关，别让它影响上网
sudo nmcli connection modify "$CON" ipv4.never-default yes

sudo nmcli connection up "$CON"

echo
show

echo
echo "=== 连通性 ==="
for ip in "$GLOVE_L" "$GLOVE_R"; do
  if ping -c2 -W1 "$ip" >/dev/null 2>&1; then
    echo "  $ip  可达"
  else
    echo "  $ip  不可达  —— 跑 ./check_gloves.sh 排查，或见 bringup.md §1（线是否插反）"
  fi
done
