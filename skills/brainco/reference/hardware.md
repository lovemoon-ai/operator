# BrainCo Revo 灵巧手 —— 硬件参考

> **两类信息严格分开**：
> 📘 = 来自 BrainCo 官方文档 <https://www.brainco-hz.com/docs/revolimb-hand/>
> 🔬 = 在 Unitree G1（`unitree@192.168.124.169`）上实测，2026-08-26
>
> 官方文档随固件更新，实测只代表那台机器那次上电。冲突时以实测为准，但要复测。

---

## 1. 三个型号 —— 唯一的区别是触觉

📘 Revo2 同一套机械结构（6 自由度、拇指 2 个电机），分三个版本：

| 版本 | 触觉 | 每指触觉通道 | 典型用途 |
|---|---|---|---|
| **BASIC** | ❌ 无 | — | 位置/电流控制、抓取演示 |
| **TOUCH** | ✅ 电容式 | 法向 + 切向 + 方向 | 接触检测、轻触物体 |
| **TOUCH PRESSURE** | ✅ 压阻式 | 法向 + 切向 + 方向 + 压力分布 | 力控、滑移检测 |

**BASIC 没有任何力/触觉传感器。** 它唯一的"力"信号是**电机电流**——间接、有死区、
受摩擦和位形影响。需要真实接触力、接近觉或滑移检测，只能换 TOUCH 硬件，
**升级固件或 SDK 都没用**。

### 怎么判断手里这只是哪个版本

三条独立证据，**建议三条都看**：

1. **`hardware_type` 字段**（`stark_get_device_info`）：

   | 值 | 型号 | 有触觉 |
   |---|---|---|
   | 0 | Revo1（旧 Protobuf 协议） | ❌ |
   | 1 | Revo1 BASIC | ❌ |
   | 2 | Revo1 TOUCH | ✅ |
   | 3 | Revo1 ADVANCED | ❌ |
   | 4 | Revo1 ADVANCED TOUCH | ✅ |
   | 5 | **Revo2 BASIC** | ❌ |
   | 6 | Revo2 TOUCH（电容） | ✅ |
   | 7 | Revo2 TOUCH PRESSURE（压阻） | ✅ |

2. **序列号前缀**：`BC` + 版本码 + `L`/`R`（左右手）

   | 前缀 | 含义 |
   |---|---|
   | `BCXRL…` / `BCXRR…` | **BASIC**，左 / 右 |
   | `BCXTL…` / `BCXTR…` | **TOUCH**，左 / 右 |

3. **🔬 直接问硬件**（最可靠）：`stark_get_touch_status()` 返回 `NULL` 就是没有触觉模块。
   `detect_hand` 三条都查，并在互相矛盾时明确报 `MISMATCH`——
   **别只信 `hardware_type` 一个字节**。

---

## 2. 🔬 本机实测：G1 上这两只手

```
左手  /dev/ttyUSB1  slave 126  SN BCXRL2103J2600007  hw=5  sku=2 (MEDIUM_LEFT)
右手  /dev/ttyUSB3  slave 127  SN BCXRR2100J2600007  hw=5  sku=1 (MEDIUM_RIGHT)
两只   fw 1.0.22.U   RS485 Modbus RTU @ 460800   同一颗 FT4232H 四口 USB-UART
```

**两只都是 Revo2 BASIC，无触觉**（`hardware_type=5` + `BCXR*` 前缀 +
`stark_get_touch_status()` 返回 NULL，三条一致）。

sku 取值：1=MEDIUM_RIGHT，2=MEDIUM_LEFT，3=SMALL_RIGHT，4=SMALL_LEFT。

### 🔬 上电默认值

| 参数 | 左手 | 右手 |
|---|---|---|
| `max_current` | 1000 mA ×6 | 1000 mA ×6 |
| `protected_current` | 500 mA ×6 | 800 mA ×6 |
| turbo | OFF | OFF |

`max_current` **不掉电保存**，每次上电回到 1000。两只手的 `protected_current`
出厂就不一样，别假设左右对称。

---

## 3. 自由度与手指编号

📘 6 个电机，SDK 里固定顺序（`StarkFingerId`）：

| idx | 名称 | 说明 |
|---|---|---|
| 0 | `THUMB` | 拇指**旋转/对掌** |
| 1 | `THUMB_AUX` | 拇指**弯曲** |
| 2 | `INDEX` | 食指 |
| 3 | `MIDDLE` | 中指 |
| 4 | `RING` | 无名指 |
| 5 | `PINKY` | 小指 |

拇指占两个电机，其余四指各一个（欠驱动，一个电机带整根手指弯曲）。
触觉数据 `CTouchFingerData.items[]` 只有 **5** 项（按手指分，不按电机），
遍历时别用 6。

---

## 4. 位置与电流的单位（最容易搞错的地方）

📘 位置：`0` = 完全张开，`1000` = 完全闭合。

🔬 **电流读数永远是归一化的 ±1000，和 `FINGER_UNIT_MODE` 无关。**
设成 `FINGER_UNIT_MODE_PHYSICAL` 也一样。换算：

```
实际电流(mA) = currents[f] / 1000.0 * max_current[f]
```

所以**每次采数都要把 `max_current` 一起记进 CSV 头**，否则事后无法还原成 mA。
`grasp_log` 就是这么做的。

电机状态 `states[f]`：0=IDLE，1=RUN，2=STALL，3=TURBO。
**STALL 是判断"抓到东西了"最直接的信号**，比给电流设阈值稳。

---

## 5. 🔬 BASIC 用电流当力传感器：能做到什么程度

空抓（右手、turbo off、限流 800 mA）实测基线：

- 自由闭合只要 **+50…+200 mA**，随弯曲角增大而升高
- 张开是 **−50…−110 mA**（硅胶和腱的回弹力）
- **保持阶段电流 ≈ 0**：位置到位后，turbo 关、又没东西可挤，电机直接停转
- 每个电机的静息偏置**不是固定值**，baseline 和 hold 两段都不一样 ——
  必须减**同一次运行内**的基线，不能用历史基线
- 所有 |电流| > 600 mA 的样本都恰好落在启停瞬间，是真实的浪涌/刹车尖峰，
  一个样本宽。**永远别让它们决定 y 轴范围。**

含义：**空载电流地板很低（<200 mA），接触后的抬升信噪比是够用的。**
但"接触 → 建力 → 堵转平台"这个完整形状必须有实物才测得到，空抓只给出自由运动的地板。

---

## 6. 📘 官方参数（速查）

| 项 | 值 |
|---|---|
| 自由度 | 6 主动 |
| 通信 | RS485 Modbus RTU / CAN FD |
| 默认波特率 | 460800 |
| 默认从站号 | 126（左）/ 127（右） |
| 位置分辨率 | 0–1000 |
| 供电 | 24 V |

Revo2 BASIC 手腕下方有 **CAN FD / Modbus-RTU 拨码开关**；
拨在 CAN 侧时串口完全扫不到，容易误判成"手坏了"。

---

## 7. SDK

🔬 `bc-stark-sdk v1.1.9`，随 Unitree 的 `brainco_hand_service` 一起分发：

```
~/workspace/{zedong.liu,kaihui.wang}/brainco_hand_service/
  include/stark-sdk.h
  lib/aarch64/libbc_stark_sdk.so     # Jetson Orin 用这个
  lib/x86_64/libbc_stark_sdk.so
```

预编译 `.so`，**没有交叉编译路径，必须在机器上编**（见 `scripts/build.sh`）。

`brainco_hand_service` 本身是 Unitree 的串口→DDS 桥，话题
`rt/brainco/{left,right}/{cmd,state}`。它**独占串口**，直连 SDK 前必须先停掉。
