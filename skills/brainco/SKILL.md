---
name: brainco
description: BrainCo Revo 灵巧手（Revo1/Revo2，BASIC/TOUCH/TOUCH-PRESSURE）的型号识别、串口排障、限流配置与抓取电流曲线采集分析。当用户需要确认手上这只灵巧手是哪个型号、判断它到底有没有力反馈/触觉反馈、SDK 扫不到手或 stark_auto_detect 报 NO DEVICE FOUND、设了限流却不生效、想采集抓取过程的每指电流曲线、或需要用电流当力信号做接触检测时使用。
---

# BrainCo Revo 灵巧手

BrainCo Revo2 是**六自由度腱驱动灵巧手**，走 **RS485 Modbus RTU**（默认 460800，
从站 126 左 / 127 右）。它分三个版本，**机械结构完全一样，唯一区别是有没有触觉**：

- **BASIC** —— 无任何力/触觉传感器。唯一的"力"信号是**电机电流**。
- **TOUCH** —— 电容式触觉。
- **TOUCH PRESSURE** —— 压阻式，带压力分布。

所以「这只手有没有力反馈」这个问题**只能靠查型号回答，不能靠试**——
BASIC 缺的是硬件，刷固件、升 SDK 都变不出触觉来。本 skill 的第一件事就是把型号钉死，
第二件事是在只有 BASIC 时，把电流这个间接信号用到它能到的精度。

> 🔬 本 skill 的所有实测结论来自 Unitree G1（`unitree@192.168.124.169`）上的两只
> **Revo2 BASIC**，2026-08-26。文档来源与实测在 `reference/hardware.md` 里用 📘/🔬 分开标注。

## 能力范围

- **型号体检**：端口 × 波特率 × 从站号扫描，报出型号 / SKU / SN / 固件，
  并用三条独立证据（`hardware_type` + SN 前缀 + **实际问硬件要触觉数据**）交叉验证，
  互相矛盾时明确报 `MISMATCH`。
- **串口排障**：`stark_auto_detect` 失效、端口被 `brainco_hand_server` 占用、
  CAN/Modbus 拨码开关、dialout 权限、供电误判。
- **限流配置**：设置并**读回验证**每指 `max_current` / `protected_current`，
  绕开「连发写入丢第一条」这个静默失败。
- **抓取电流曲线**：单进程发指令 + 采样到 CSV（实测 ~98.7 Hz），
  五相位（baseline→open→close→hold→release），带 `--dry` 零运动演练。
- **出图**：三联图 + 相位带 + STALL 标记 + 启停尖峰稳健截断。
- 官方文档：<https://www.brainco-hz.com/docs/revolimb-hand/>

## reference/ — 参考文档

- **`reference/hardware.md`** — 三个版本的对比与判别方法、`StarkHardwareType` 枚举
  对照表、SN 前缀表、6 电机编号、**位置/电流单位换算**、官方参数速查、SDK 位置。
  以及 🔬 本机两只手的完整实测档案和空抓基线数值。
  「这手有没有触觉」「电流怎么换算成 mA」看这份。
- **`reference/troubleshooting.md`** — 踩坑记录，按「现象 → 真实原因 → 判据 → 处理」组织，
  分 5 类：A 连不上、B 写配置、C 读数据、D 采曲线、E 编译。
  **B1（连发写入丢第一条）是最坑的一条，设限流前务必先看。**

## scripts/ — 可运行示例

> 三个脚本都要**在机器人上**跑：SDK 只有预编译 `.so`，matplotlib 也只装在机器人上。
> ```bash
> ssh unitree@<robot> 'mkdir -p ~/brainco_tools'
> scp scripts/* unitree@<robot>:~/brainco_tools/
> ssh unitree@<robot> 'cd ~/brainco_tools && ./build.sh'
> ```

- **`scripts/build.sh`** — 编译 C++ 工具。自动在 `~/workspace/*/brainco_hand_service`
  里找 SDK，按 `uname -m` 选 `lib/aarch64` 或 `lib/x86_64`，加 `-Wl,-rpath`
  让二进制自己找得到 `.so`（不用每次 `LD_LIBRARY_PATH`）。
  - 全部：`./build.sh`
  - 单个：`./build.sh detect_hand`
  - SDK 找不到时手动指：`SDK=/path/to/brainco_hand_service ./build.sh`

- **`scripts/detect_hand.cpp`** — **型号体检，接手新设备第一件事**。**只读，绝不发运动指令。**
  扫描端口 × 波特率 × 从站号，对每只找到的手打印型号 / `hardware_type` / SKU / SN /
  固件 / **触觉实测结果** / 限流 / turbo / 六指位置·电流·状态。
  **它不信 `hardware_type` 这一个字节**——同时调 `stark_get_touch_status()` 实际要一次
  触觉数据，两者不一致时打 `MISMATCH`。没找到手时打印分诊清单（供电/占用/权限/拨码）。
  - `./detect_hand` （默认扫 `/dev/ttyUSB0..7` × 三种波特率 × 四个从站号）
  - `./detect_hand --quick` （只试出厂默认组合，快）
  - `./detect_hand --port /dev/ttyUSB3 --slave 127`
  - 退出码：找到 =0，一只都没找到 =1
  - **`stark_auto_detect` 在 G1 上直接报 NO DEVICE FOUND**，这个脚本存在的理由就是绕开它。

- **`scripts/grasp_log.cpp`** — 抓取电流采集。**单进程**发指令 + 采样（串口独占，
  拆成两个进程必然抢端口），五相位循环写 CSV，CSV 头里带 `max_current`
  以便事后换算 mA。结束时无条件张开手。
  - 演练（**零运动指令**，改完参数先跑这个）：`./grasp_log --dry --out /tmp/dry.csv`
  - 实采：`./grasp_log --port /dev/ttyUSB3 --slave 127 --current-ma 800 --out /tmp/grasp.csv`
  - 关键参数：`--hz`（默认 100，实测 98.7）`--current-ma` `--speed` `--thumb` `--fingers` `--turbo`
  - ⚠️ **`--dry` 不走配置写路径**，所以 dry 通过 ≠ 限流设上了；看它打印的
    `max_current readback` 和 `WARNING` 行。
  - ⚠️ **要干净曲线就别开 `--turbo`**：turbo 关时位置到位电机即停，开着则持续给流，形状完全不同。

- **`scripts/plot_grasp.py`** — 出图。三联：①全量程电流（看启停尖峰）
  ②**稳态细节窗**（按 1.2/98.8 分位定标，尖峰用三角标在边缘并注明截断了多少个样本）
  ③位置曲线。相位灰带 + 相位名 + 每指直接标注 + **STALL 起始点虚线**。
  - `python3 plot_grasp.py /tmp/grasp.csv /tmp/grasp.png --note " - empty grasp"`
  - CSV 头没有 `max_current_ma` 时手动给：`--limits 800`
  - **在机器人上出图再把 PNG scp 回来**（matplotlib 3.1.2 在机器人上，开发机没有）。

## 五条最容易踩的经验

1. **🔬 连发的配置写入会丢掉第一条，而且不报错。** 循环设六指限流，读回来第一根
   （通常是拇指）还是旧值——这**不是**"拇指寄存器只读"，把循环倒过来丢的就变成小指。
   bisect 实测：0 ms 间隔每轮固定丢 1 条，**≥1 ms 就干净**（0/18）。
   写配置之间垫 ≥1 ms，**并且一定读回来比对**。
2. **🔬 电流读数永远是归一化 ±1000，`FINGER_UNIT_MODE_PHYSICAL` 也改不了。**
   `mA = cur/1000 × max_current`。**必须把 `max_current` 一起存进 CSV**，
   忘了记的数据事后无法还原单位，基本是废的。
3. **🔬 `max_current` 不掉电保存**（每次上电回 1000 mA），
   而且**左右手出厂参数不对称**（实测 `protected_current` 右 800 / 左 500）。
   每次运行都要重设，别假设两只一样。
4. **🔬 空抓测不出抓取曲线。** turbo 关 + 位置到位 + 没东西可挤 → 保持阶段电流 ≈ 0，
   电机直接停转。"接触 → 建力 → 堵转平台"这个形状**必须有实物**；
   空抓的价值只是给出自由运动的地板（闭合 +50…200 mA，张开 −50…−110 mA）。
   另外**静息偏置不是固定值**，同一次运行里 baseline 段和 hold 段都不一样，
   只能减同一次运行内的基线。
5. **判断"抓到了"优先看 `states[f] == STALL`**，比自己给电流设阈值稳得多。
   画图时**别让启停尖峰决定 y 轴**——所有 |电流|>600 mA 的样本都是一个样本宽的
   浪涌/刹车瞬态，不截断的话真实接触信号会被压成一条平线。
