# Wuji Glove 开箱到跑通

拿到一副 Wuji Glove 之后，按这个顺序做。每一步都给了**验证手段**——不要跳过验证直接进下一步，
这次踩的坑里有一半是因为「看起来接上了」但其实没接上。

---

## 0. 先建立正确的心智模型

**手套是网络设备，不是串口设备。**

一开始很容易去找 `/dev/ttyACM*`、查 `dialout` 组权限——方向完全错了。实际链路是：

```
手套 ──USB-C线── USB-C转以太网转接盒 ──USB── 电脑
                  (GenesysLogic USB3.1 Hub + ASIX AX88179B，走 cdc_ncm 驱动)
```

手套在网络上是一个独立 IP 主机，SDK 通过 **UDP** 跟它通信：

| 项目 | 值 |
|---|---|
| 出厂 IP | 左手 `192.168.1.100`，右手 `192.168.1.101` |
| 发现端口 | UDP `50000`（广播扫描） |
| 数据端口 | UDP `50001` |
| 子网掩码 | `255.255.255.0` |
| 数据速率 | `hand_skeleton` 约 120 Hz |

一个转接盒 = 一只手套，点对点。**两只手套需要两条独立路径**（两个转接盒，或一个交换机把两只手套并到同一网段）。

---

## 1. 物理连接

按官方文档，有两个极易犯错的点：

1. **必须用 USB-A to USB-C 线供电。USB-C to USB-C 线无法给手套供电。**
2. **线缆两端的同一面上有白色矩形标识，两端标识必须朝同一面。**
   插反了只供电、不通数据——现象是**手套绿灯正常亮起，但网络上完全看不见它**。
   这次右手套卡了很久就是这个原因。

连好后确认：
- 手套 LED 亮起并转入呼吸灯状态
- 转接盒指示灯亮

---

## 2. 确认系统看见了转接盒

```bash
lsusb | grep -i ax88          # 应出现 ASIX AX88179 Gigabit Ethernet
ip -br link | grep -E "^en"   # 应多出一个 enx<mac> 网卡
```

**如果你刚插拔过，但内核日志里一个事件都没有，说明插拔根本没被系统感知**——别再查软件了，回去查线和口：

```bash
journalctl -k --since "-10 min" | grep -iE "usb [0-9]|ax88|renamed"
```

正常插入会看到类似：

```
usb 4-1: Product: USB3.1 Hub / Manufacturer: GenesysLogic
usb 4-1.3: Product: AX88179B / Manufacturer: ASIX
cdc_ncm 4-1.3:2.0 enx6c1ff7c93c06: renamed from eth0
```

---

## 3. 配置电脑网络

### 3.1 快速验证（临时，重启即失效）

先用临时地址确认链路能通，别一上来就写持久化配置：

```bash
sudo ip addr add 192.168.1.10/24 dev <网卡>
ping -c2 192.168.1.100
```

不通就先回 §1/§2 查物理层，通了再往下做持久化。清理：`sudo ip addr del 192.168.1.10/24 dev <网卡>`。

### 3.2 持久化（NetworkManager）

给接手套的那张网卡配同网段静态 IP，**避开手套占用的 .100/.101**：

```bash
nmcli con add type ethernet ifname <网卡> con-name wuji-glove \
      ipv4.method manual ipv4.addresses 192.168.1.10/24
nmcli con up wuji-glove
```

### 3.3 **多网卡必做：用 /32 静态路由把手套钉在正确的网卡上**

**这一步是这次真正解决问题的关键，单网卡可以跳过，多网卡千万别跳。**

这台机器上同时有两个 `192.168.1.0/24`：`enp132s0`（192.168.1.165，别的用途）和手套网卡
（192.168.1.10）。两条 /24 路由互相竞争，去手套的流量会随机走错网卡，表现为**时通时不通**。

调 metric 不可靠（另一张网卡的 metric 不归你管）。**正确做法是给两个手套 IP 各加一条 /32 主机路由**——
最长前缀匹配的优先级高于任何 metric，/32 一定赢：

```bash
sudo nmcli connection modify wuji-glove ipv4.routes "192.168.1.100/32,192.168.1.101/32"
nmcli con up wuji-glove
```

验证配置写进去了：

```bash
nmcli -g ipv4.routes connection show wuji-glove
# { ip = 192.168.1.100/32 }; { ip = 192.168.1.101/32 }
```

验证真的生效了（**这条才算数**，看 `dev` 是不是接手套的那张）：

```bash
ip route get 192.168.1.100
ip route get 192.168.1.101
ip neigh show 192.168.1.100    # 顺便对 MAC，确认响应方是手套不是冒名设备
```

### 3.4 多网卡环境的两个陷阱

- **冒名设备**：另一张网卡的网段下挂着别的设备，恰好占用了手套 IP 并响应 ping。
  → 拔掉手套后再 ping，**仍有响应就是冒名设备**。
- **IP 冲突**：两张网卡都在 192.168.1.0/24 → 用上面的 /32 路由解决，
  或者干脆只保留接手套的那张网卡在该网段。

### 3.5 ⚠️ 换了转接盒，nmcli profile 会静默失效

nmcli profile 绑的是 `connection.interface-name`，而 USB 网卡名是 **`enx<MAC>`**——
**换一个转接盒，MAC 变了，网卡名就变了，profile 直接不再匹配任何设备，且不报错。**

这次就撞上了：profile 绑在 `enx6c1ff7c93c06`，换盒后机器上只剩 `enx6c1ff7c93c2d`，
配置看着好好的（`nmcli connection show wuji-glove` 一切正常），但网卡上根本没有 192.168.1.10。

**判据**：

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status   # 手套网卡的 CONNECTION 是不是 wuji-glove
nmcli -g connection.interface-name connection show wuji-glove   # 对比现存网卡名
ip -br addr show <现存网卡>                            # 地址到底配上没有
```

**处理**：改绑到新网卡名，或改用 MAC 无关的绑定。

```bash
sudo nmcli connection modify wuji-glove connection.interface-name <新网卡名>
nmcli con up wuji-glove
```

### 3.6 怎么判断一条线接的是手套还是办公网

手套是点对点接入，**一个网段上应该只有 1 台设备**。逐网卡扫描：

```bash
for n in $(seq 1 254); do ping -c1 -W1 -I <网卡> 192.168.1.$n >/dev/null 2>&1 & done; wait
ip neigh show dev <网卡> | grep lladdr
```

扫出 6 台主机 + 一个网关 → 这条线插在办公网交换机上，不是手套。
（这次右手套「不见了」，真实原因就是它的转接盒网口接到了公司交换机。）

**一键配置：`scripts/setup_network.sh <网卡>`**（做 3.2 + 3.3 + 3.5，并打印实际生效状态）
**一键排查：`scripts/check_gloves.sh`**（跑完本节所有检查，不改任何配置）

---

## 4. 装 SDK 并扫描

```bash
python3 -m venv .venv && ./.venv/bin/pip install wuji_sdk
```

```python
from wuji_sdk import SdkManager
for d in SdkManager.instance().scan():
    print(d.sn, d.device_type, d.address)
```

期望输出两行，SN 形如 `WG1JA06260701014`(左) / `WG1KA06260627544`(右)。

扫不到但 ping 通 → 查 ufw 是否放行 UDP 50000/50001，以及是否有别的客户端（Studio 或另一个脚本）占着设备连接。

---

## 5. **传感器体检（关键，别跳过）**

**这一步是这次最重要的教训。** 连上了、有数据流、可视化里手也画出来了——都**不代表每根手指都是好的**。

一根 EMF 通道死掉的手指，解算器仍然会输出一个**固定的默认姿态**，可视化照样把它画出来，
看起来只是「这根手指不太动」，非常容易被当成没戴好或者环境干扰。

```bash
python scripts/glove_healthcheck.py --secs 6
```

它逐通道检查 5 项：

| 检查 | 健康表现 | 异常表现 |
|---|---|---|
| **`emf_poses` 各通道模长** | 0.07~0.14 | **恒为 0.00000 = 该通道无输出** |
| **每指 `confidence`** | >0.9 | **恒为 0.0000 = 无数据（和「低」是两回事）** |
| 骨长 | 各段 20~95mm | 接近 0 = 几何异常 |
| 静止位移 | 亚毫米级抖动 | 恒 0（冻结）**或**上百 mm（乱摆）——见下 |
| 静止时关节角摆幅 | <1° | 几十度乱摆 |

**只有加粗的前两项是死通道的可靠判据。** 通道死掉后，后两项既可能表现为「冻结在默认姿态」，
也可能表现为「大幅乱摆」，取决于解算器状态——同一只手套两次采样就给出过相反的结果，
不要拿它们当主判据（详见 `troubleshooting.md` §D）。

退出码：**存在硬件故障时为 1；只有环境/使用类提示（如置信度偏低）时为 0**。

新手套到手第一天就该跑一次，留作基线。有问题时才能证明「不是我用坏的」。
**两只手套都跑**——健康的那只是排除环境/驱动/SDK 共因的对照组。

---

## 6. 手部模型标定

```python
result = glove.calibrate_blocking(timeout_s=900.0)
```

**注意这个坑**：标定产物按 **SDK 用户 + 左右手** 存放（`~/.wuji/sdk/users/<user_id>/models/{left,right}_hand.urdf`）。

> **默认 SDK 用户会跳过标定产物，永远用内置默认 URDF。**
> 必须先 `create_user` / `switch_user` 到具名用户，标定才有意义。

同一用户下**同侧手套共享同一模型**，换一只同侧手套不用重新标定。

搞清楚这是什么标定：**它标的是「你的手」的几何（骨长），生成 URDF，用于 IK。
它不是 EMF 幅度标定，修不了某个 EMF 通道没数据的问题。**

---

## 7. 可视化验证

```bash
python scripts/dual_glove_viz.py
```

自动发现 N 只手套，每只一列三个面板：

1. **3D 骨架** —— HUD 显示帧数/Hz，置信度低于阈值的手指灰显并标 `NO SIGNAL: <finger>`，
   受力的手指按压力变暖变粗、指尖出光点。
2. **6 个触觉分区按压强度柱状图**（已扣静息基线），无输出的分区标红 `DEAD`。
3. **区内触点分箱条带** —— 看得出一个分区里哪一段在受力。

> **启动头 2 秒在采静息基线，别碰手套。** 手套静息时各区读数 p95 已达 ~0.2、峰值到 1.00，
> 不扣基线画出来永远是「满手在受力」。基线被误抬高的话，之后轻按就没反应了。
> 时长可调：`--baseline-secs 3`。

静息时柱子下方显示 `pk<原始峰值>`——**这是区分「没被按」和「传感器坏了」的关键**，
两者扣完基线都是 0，但前者 pk 有 0.13~1.00，后者 pk 恒在 0.005 这种噪声底。

无头出图 / 只看骨架：

```bash
python scripts/dual_glove_viz.py --save out.png --secs 8
python scripts/dual_glove_viz.py --no-tactile
```

> **如果 `--save` 出来的 4 帧一模一样，先别怀疑代码**——大概率是手套没被戴上/没动。
> 脚本会打印 `max disp`，1.6mm 这种量级就是没动。

---

## 7.5 ⚠️ 报障前必须断电重插复测

**这是本次最贵的教训。** 见 `troubleshooting.md` §D。

「某个 EMF 通道模长恒为 0 + 该指 confidence 恒为 0 + 另一只手套对照正常」——
这条证据链看起来铁证如山，本次据此判定右手中指线圈损坏。
**但转接盒重插、手套重新上电后，该通道完全恢复正常**（模长 0.00000 → 0.13253）。

> `corrected amplitude = 0` 证明的是**「这次上电后这条通道没工作」**，
> 不是「这条通道坏了」。软件无法区分「出厂标定缺失」「线圈物理损坏」「本次上电初始化失败」。

**流程**：发现异常 → **断电重插 + 重新上电** → 复测 → 仍复现才报障。

---

## 8. 使用环境要求

EMF 是电磁定位，对环境敏感。官方阈值：

- `confidence` **低于 0.9 即不可信**
- **低于 0.8 说明环境干扰严重**

要求：
- 手距手背发射线圈 **30cm 以内**
- 远离金属物体和电子设备
- 发射线圈与手之间无大面积金属遮挡

实测参考：两只手套摊在桌上、紧挨主机和显示器时，各指 confidence 只有 **0.49~0.72**，全部低于不可信阈值。
戴上手套、离开金属环境后才有意义。

---

## 一次性检查清单

```
□ 用的是 USB-A to USB-C 线（不是 C to C）
□ 线两端白色矩形标识同面
□ 手套 LED 呼吸灯
□ lsusb 看得到 AX88179
□ journalctl 有 USB 插入事件
□ 网卡配了同网段静态 IP，掩码 /24
□ 多网卡时加了 192.168.1.100/32 和 .101/32 静态路由
□ ip route get <手套IP> 走的是对的网卡
□ nmcli profile 绑的网卡名 == 现存网卡名（换过转接盒必查）
□ 该网段上只有手套一台设备
□ ping 通 + SDK scan 扫到
□ glove_healthcheck.py 全绿  ← 别跳过
□ dual_glove_viz.py 六个触觉分区都不是 DEAD（pk 值有 0.1+，不是 0.005 噪声底）
□ 具名 SDK 用户下做过 calibrate()
□ 使用环境 confidence > 0.9
□ 判定为硬件故障前，断电重插 + 重新上电复测过一次  ← 别跳过
```
