---
name: wuji
description: Wuji Glove（无际 EMF 动捕数据手套）开箱、联网、体检、标定与可视化。当用户需要接入/调试 Wuji Glove、手套 ping 不通或 SDK 扫不到、某根手指没反应或置信度异常、要跑手部骨架实时可视化、做传感器逐通道体检、做手部模型标定，或需要按证据向 Wuji 报障时使用。
---

# Wuji Glove

Wuji Glove 是**基于 EMF（电磁场）定位的数据手套**。它在系统里是**网络设备**——通过 USB-C
转以太网转接盒接入，手套本身是一台 IP 主机（出厂 `192.168.1.100` 左 / `192.168.1.101` 右），
SDK 走 UDP `50000`（发现）/ `50001`（数据），`hand_skeleton` 约 120 Hz。

本 skill 覆盖从**拿到设备 → 接上电脑 → 验证每根手指真的在出数据 → 标定 → 可视化**的完整流程，
以及一次真实排障中踩到的全部坑（含右手中指 EMF 通道无输出的完整定位过程）。

## 能力范围

- **开箱上手**：硬件构成与心智模型、USB-C 线朝向与供电要求、网卡静态 IP + `/32` 主机路由配置、SDK 安装与扫描。
- **网络层排障**：多网卡下的路由竞争与冒名设备、换转接盒后 nmcli profile 静默失效、判断一条线接的是手套还是办公网、内核 USB 事件核对。
- **传感器体检**：逐 EMF 通道 / 逐手指判断是否真的有数据，区分「置信度低」与「无数据」；
  逐触觉分区判断是否真的有输出。
- **标定**：手部几何模型（URDF）标定，以及标定产物按 SDK 用户存放的坑。
- **可视化**：N 只手套并排实时 3D 骨架 + 触觉渲染，低置信度手指自动标注，无输出的触觉分区标 DEAD。
- **报障**：把「某根手指坏了」变成一条可提交的四段式证据链（**且先断电复测过**）。
- 官方支持：`support@wuji.tech`

## reference/ — 参考文档

- **`reference/bringup.md`** — 拿到手套后从 0 到跑通的分步流程（0~8 步 + 一次性检查清单）。
  每步都附验证手段：物理连接 → USB 识别 → 网络配置 → SDK 扫描 → **传感器体检** → 标定 →
  可视化 → 使用环境要求。新设备到手先看这份。
- **`reference/troubleshooting.md`** — 踩坑记录，按「现象 → 真实原因 → 判据 → 处理」组织，
  分 5 类：A 连接与网络、B SDK/进程行为、C 数据判读、D 右手中指实例与报障模板、E 本机环境。
  遇到「灯亮但 ping 不通」「画面冻结但 HUD 在刷」「某根手指不动」时先查这份。

## scripts/ — 可运行示例

- **`scripts/0.subscribe_callback.py`** — 官方 SDK 回调订阅示例（Hello World）。自动发现并连接手套，
  用 `subscribe_with_callback()` 订阅全部 6 路数据流：`tactile` / `tactile_zones` / `emf_poses` /
  `hand_joint_angles` / `hand_skeleton` / `tactile_point_cloud`。回调在后台线程跑，不阻塞主流程。
  想知道某路数据长什么样、字段怎么取，看这个最快。
  - `python scripts/0.subscribe_callback.py`
  - 用自己标定的手部模型：`python scripts/0.subscribe_callback.py --hand-model-path ~/.wuji/sdk/users/<user>/models/right_hand.urdf`
    （注意：自定义 URDF 的在线 IK **需要具名 SDK 用户**，默认用户下不生效，见 troubleshooting B5）
- **`scripts/setup_network.sh`** — 一键配置手套网络。给指定网卡配静态 IP，
  **并给 `192.168.1.100/32` 和 `.101/32` 各加一条主机路由，把手套流量钉死在这张网卡上**
  （多网卡机器上常有两张网卡都落在 192.168.1.0/24，不加 /32 会时通时不通）。
  自动处理「换了转接盒导致 profile 绑错网卡」的情况，设 `never-default` 避免抢默认路由，
  配完自动打印实际生效状态 + 连通性。
  - 查看当前状态（只读，不改配置）：`./scripts/setup_network.sh --show`
  - 配置：`./scripts/setup_network.sh enx6c1ff7c93c06`（网卡名用 `ip -br link | grep '^enx'` 找）
- **`scripts/check_gloves.sh`** — 网络层体检，**不依赖 SDK**，纯系统命令。依次检查 USB 网卡、
  以太网口状态（IP/carrier/speed/USB 路径）、手套 IP 可达性与路由/ARP 归属、
  **逐网卡扫描 `192.168.1.0/24` 判断该网段是点对点接手套还是接了办公网交换机**、
  UDP 50000/50001 防火墙、最近的内核 USB/链路事件。ping 不通时先跑它。
  - `./scripts/check_gloves.sh` （可传自定义 IP：`./scripts/check_gloves.sh 192.168.1.100 192.168.1.101`）
- **`scripts/glove_healthcheck.py`** — 传感器逐通道体检，**新手套到手第一天就该跑一次留基线**。
  同时订阅 `emf_poses` / `hand_skeleton` / `hand_joint_angles`，输出 5 项判据：
  ① 5 个 EMF 通道位置向量模长（恒 0 = 该通道无输出）② 每指 confidence（区分「低」与「恒为 0」）
  ③ 反算骨长 ④ 静止位移 ⑤ 静止时关节角摆幅。**只有 ①② 是死通道的可靠判据**——
  通道死掉后 ④⑤ 既可能「冻结」也可能「乱摆」，同一只手套两次采样给过相反结果。
  区分**硬件故障**（退出码 1）与**环境提示**（如置信度偏低，退出码 0）。
  - `python scripts/glove_healthcheck.py --secs 6`
  - 只查一只：`python scripts/glove_healthcheck.py --sn WG1KA06260627544`
- **`scripts/dual_glove_viz.py`** — 实时 3D 手部骨架 + 触觉可视化。自动发现 1..N 只手套，
  每只一列三个面板：
  ① **3D 骨架** —— 五指分色 + 掌骨连线，HUD 显示帧数/Hz；
  置信度低于阈值的手指灰显并标 `NO SIGNAL: <finger>`；**受力的手指按压力变暖变粗 + 指尖光点**。
  ② **6 个触觉分区的按压强度柱状图**（已扣静息基线），无输出的分区标红 `DEAD`。
  ③ **区内触点分箱条带** —— 看得出一个分区里哪一段在受力。
  静息时柱子下方显示 `pk<原始峰值>`，用来区分「没被按」和「传感器坏了」（两者扣完基线都是 0）。
  订阅在退出时会被正确 `close()`（避免设备侧留下孤儿 session）。
  - 交互窗口：`python scripts/dual_glove_viz.py`
  - 无头出图：`python scripts/dual_glove_viz.py --save out.png --secs 8`
  - 只看骨架：`python scripts/dual_glove_viz.py --no-tactile`
  - **启动头 2 秒是在采静息基线，别碰手套**（可调 `--baseline-secs 3`，见 troubleshooting C7）
  - 出的几帧一模一样时先看打印的 `max disp` —— 多半是手套没被戴上/没动，不是脚本问题。

## 四条最容易踩的经验

1. **灯亮 ≠ 接好了。** USB-C 线插反时供电正常但数据不通，手套在网络上完全不可见。
   线两端的白色矩形标识必须朝同一面。
2. **可视化里手画出来了 ≠ 每根手指都好。** EMF 通道死掉时解算器会输出固定默认姿态照常渲染，
   看起来只是「不太灵活」。判断手指好坏必须跑 `glove_healthcheck.py` 看逐通道数据。
3. **`confidence == 0` 不是「置信度低」，是「没有数据」。** 两者排障方向完全不同。
4. **报障前一定要断电重插再复测一次。** 本次「右手中指 EMF 通道无输出」有完整证据链
   （模长恒 0 + confidence 恒 0 + 左手对照），看着就是线圈坏了——
   **但转接盒重插、手套重新上电后完全恢复**（模长 0.13253，healthcheck 退出码 0）。
   `corrected amplitude = 0` 证明的是「这次上电后这条通道没工作」，不是「这条通道坏了」。
