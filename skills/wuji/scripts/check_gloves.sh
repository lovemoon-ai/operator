#!/usr/bin/env bash
# Wuji Glove 网络层体检 —— 不依赖 SDK，纯系统命令。
#
# 拿到手套接上电脑后先跑这个。它回答一个问题：
#   "手套在不在这台机器能看见的网段上？"
#
# 用法:  ./check_gloves.sh [左手IP] [右手IP]
#        默认 192.168.1.100 / 192.168.1.101（出厂值）

set -u
L="${1:-192.168.1.100}"
R="${2:-192.168.1.101}"

hr() { printf '%.0s─' {1..70}; echo; }

hr; echo "1. USB 网卡（手套通过 USB-C 转以太网转接盒接入）"; hr
lsusb | grep -iE "asix|ax88|realtek.*ethernet" || echo "  (没有发现 USB 网卡)"

hr; echo "2. 以太网口状态"; hr
for i in $(ls /sys/class/net | grep -E "^(en|eth)"); do
  ip4=$(ip -4 -o addr show dev "$i" | awk '{print $4}')
  car=$(cat "/sys/class/net/$i/carrier" 2>/dev/null)
  spd=$(cat "/sys/class/net/$i/speed" 2>/dev/null)
  usb=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null | grep -o 'usb[0-9].*' || echo "-")
  printf "  %-20s ip=%-18s carrier=%s speed=%-5s %s\n" \
         "$i" "${ip4:-无}" "${car:-?}" "${spd:-?}" "$usb"
done

hr; echo "3. 手套 IP 可达性"; hr
for ip in "$L" "$R"; do
  if ping -c2 -W1 "$ip" >/dev/null 2>&1; then
    echo "  $ip  可达"
  else
    echo "  $ip  不可达"
  fi
done
echo
echo "  路由（确认流量走的是接手套的那张网卡）:"
for ip in "$L" "$R"; do
  printf "    %-16s -> %s\n" "$ip" "$(ip route get "$ip" 2>/dev/null | head -1)"
done
echo
echo "  ARP（对比 MAC，确认响应方真是手套而不是冒名设备）:"
ip neigh show | grep -E "^($L|$R) " || echo "    (无表项)"

hr; echo "4. 逐网卡扫描 192.168.1.0/24（找出每个网段上到底挂了什么）"; hr
# 手套是点对点接在转接盒上的，正常情况下一个网段应该只有 1 只手套。
# 网段上出现一堆主机 => 这条线接的是办公网，不是手套。
for i in $(ls /sys/class/net | grep -E "^(en|eth)"); do
  ip -4 -o addr show dev "$i" | grep -q "192\.168\.1\." || continue
  echo "  扫描 $i ..."
  for n in $(seq 1 254); do ping -c1 -W1 -I "$i" "192.168.1.$n" >/dev/null 2>&1 & done
  wait
  cnt=$(ip neigh show dev "$i" | grep -c lladdr)
  ip neigh show dev "$i" | grep lladdr | awk '{print "     ", $1, $3}'
  [ "$cnt" -gt 2 ] && echo "     ^ 该网段有 $cnt 台主机，不像点对点接手套（可能接到了办公网交换机）"
done

hr; echo "5. UDP 端口（50000 发现 / 50001 数据）"; hr
if command -v ufw >/dev/null && sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo -n ufw status | grep -E "50000|50001" || \
    echo "  ufw 已启用但未放行，需要: sudo ufw allow 50000/udp && sudo ufw allow 50001/udp"
else
  echo "  ufw 未启用或无权查询（未启用则无需放行）"
fi

hr; echo "6. 最近的 USB / 链路事件（验证插拔是否被内核看见）"; hr
journalctl -k --since "-15 min" 2>/dev/null \
  | grep -iE "usb [0-9]|ax88|Link is (Up|Down)|renamed" | tail -12 \
  || echo "  (无事件 —— 如果你刚插拔过，说明内核根本没察觉，检查线和口)"
