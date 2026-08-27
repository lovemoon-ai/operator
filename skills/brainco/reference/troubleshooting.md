# BrainCo 灵巧手 —— 踩坑记录

按「现象 → 真实原因 → 判据 → 处理」组织。🔬 标记的都在 G1 上实测复现过。

---

## A. 连不上 / 扫不到

### A1. 🔬 `stark_auto_detect` 返回 "NO DEVICE FOUND"，但手是好的

**现象**：官方推荐的自动发现接口直接报找不到设备，手却完全正常。

**原因**：自动发现只在一小组默认组合上试；G1 上一颗 FT4232H 出四个
`/dev/ttyUSB*`，手挂在 USB1/USB3 而非 USB0，从站号又是 126/127 不是 1。

**处理**：**别用自动发现，自己扫。** `detect_hand` 遍历
端口 × 波特率 × 从站号，就是为了绕开这个：

```bash
./detect_hand                 # /dev/ttyUSB0..7 × {460800,115200,1000000} × {126,127,1,2}
./detect_hand --quick         # 只试出厂默认，快
```

判据：`modbus_open()` 成功 ≠ 有手。**必须 `stark_get_device_info()` 返回非
NULL 才算找到**——串口打开成功只说明这个 tty 存在。

### A2. 端口被别的进程占着

**现象**：`modbus_open` 成功但所有读都是 NULL，或者时好时坏。

**原因**：串口是独占的。Unitree 的 `brainco_hand_server` / holomotion 常年在跑。

**判据与处理**：
```bash
pgrep -af 'brainco_hand_server|udp_to_dds|holomotion'
```
有就先停。反过来也一样：**自己用完要放，否则机器人本体的手不能动了。**

### A3. 拨码开关拨在 CAN 侧

Revo2 BASIC 手腕下方有 CAN FD / Modbus-RTU 拨码开关。拨错时串口侧完全静默，
所有端口所有波特率都扫不到——看着就像手死了。

### A4. 权限

`id | grep dialout`，不在组里就 `sudo usermod -aG dialout $USER` 然后**重新登录**。

### A5. 供电

MCU 在**手掌里**，不在转接盒里。转接盒的灯亮不能证明手通电了。

---

## B. 写配置

### B1. 🔬 连发的写入会丢掉第一条 ⚠️ 最坑的一个

**现象**：循环给六根手指设 `max_current`，读回来**第一根**（通常是拇指）还是旧值，
其余五根正确。看起来像"拇指这个寄存器是只读的"。

**真实原因**：**和拇指无关。** 手会静默丢弃一串背靠背写入里的**第一条**，
拇指只是循环里排第一。把顺序倒过来，丢的就变成小指。

**🔬 实测（bisect，每档 3 轮 × 6 指）**：

| 写入间隔 | 丢失 |
|---|---|
| 0 ms | 3/18（每轮固定丢 1 条，就是第一条） |
| 1 ms | 0/18 ✅ |
| 2 / 3 / 5 / 10 / 20 ms | 0/18 ✅ |

**处理**：配置写之间插 **≥1 ms**（`grasp_log` 用 2 ms 留余量），
并且**写完一定读回来比对**：

```cpp
auto cfg_gap = []{ std::this_thread::sleep_for(milliseconds(2)); };
cfg_gap();                                   // 头一条也要垫，它才是被丢的那条
for (int f = 0; f < 6; ++f) {
  stark_set_finger_max_current(h, slave, FID[f], ma);  cfg_gap();
}
for (int f = 0; f < 6; ++f)
  if (stark_get_finger_max_current(h, slave, FID[f]) != ma)
    printf("WARNING: finger %d kept %u\n", f, ...);   // 别默默接受
```

### B2. 🔬 `max_current` 不掉电保存

每次上电回到 1000 mA ×6。**每次运行都要重设，不能假设上次的设置还在。**

### B3. 🔬 左右手出厂参数不对称

实测 `protected_current` 右手 800 / 左手 500。别假设两只一样，各读各的。

---

## C. 读数据

### C1. 🔬 电流永远是归一化 ±1000

`FINGER_UNIT_MODE_PHYSICAL` 也改不了它。

```
mA = currents[f] / 1000.0 * max_current[f]
```

**把 `max_current` 写进 CSV 头**，否则事后无法还原单位。忘了记的数据基本是废的。

### C2. 🔬 静息偏置不是固定值

同一次运行里，baseline 段和 hold 段的零点都不一样。
**只能减同一次运行内的基线**，不能存一份"标定好的零点"反复用。

### C3. 🔬 启停尖峰会毁掉整张图

|电流| > 600 mA 的样本全部落在启停瞬间，是真实的浪涌/刹车，一个样本宽。
**画图时别让它们决定 y 轴范围**，否则真正的接触信号被压成一条平线。
按分位数（如 p99）截断，或直接标出来。

### C4. 触觉字段是 5 项不是 6 项

电机 6 个，`CTouchFingerData.items[]` 只有 5 项（按手指分）。
用 `f < 6` 遍历会越界。

### C5. `STALL` 比电流阈值好用

判断"抓到了"优先看 `states[f] == STALL`，比自己给电流设阈值稳得多。

---

## D. 采电流曲线

### D1. 一个进程包办

串口独占，所以**发指令和采样必须在同一个进程里**。分成两个进程必然抢端口。
`grasp_log` 就是这么设计的。

### D2. 🔬 采样率上限

实测 `stark_get_motor_status` 单次往返 → 总线上限约 **287 Hz**；
`grasp_log --hz 100` 实测 **98.7 Hz**，抖动 p95 10.1 ms。要更高就得降低每帧读的寄存器数。

### D3. 先 `--dry` 再动手

`grasp_log --dry` 跑完整流程但**一条运动指令都不发**。改完参数先 dry 一遍，
确认相位时序和 CSV 正确，再让手真的动。

⚠️ **注意 `--dry` 不会走配置写路径**（`if (!a.dry)` 里），所以 dry 跑通
不代表限流真的设上了。限流是否生效看 B1 的读回比对。

### D4. 🔬 空抓测不出"抓取曲线"

保持阶段电流 ≈ 0：位置到位、turbo 关、没东西可挤，电机就停了。
**"接触 → 建力 → 堵转平台"这个形状必须有实物。** 空抓的价值是给出自由运动的地板。

### D5. Turbo 会改变曲线形状

想要干净的力-电流关系先关 turbo。turbo 开着时保持阶段会持续给电流，
和 turbo 关时的"到位即停"完全是两条曲线。

### D6. matplotlib 在机器人上，不在开发机上

🔬 G1 上是 matplotlib 3.1.2；开发机上没有。**在机器人上出图，再把 PNG scp 回来。**

---

## E. 编译

### E1. 必须在目标机上编

SDK 只提供预编译 `.so`（`lib/aarch64`、`lib/x86_64`），没有交叉编译路径。

### E2. 用 `-Wl,-rpath`

否则每次运行都得 `LD_LIBRARY_PATH=...`。`build.sh` 已经加了。

### E3. SDK 不在系统路径里

它藏在 `~/workspace/<某人>/brainco_hand_service/`。
`build.sh` 会自动找第一个可用的；找不到就手动指：

```bash
SDK=/path/to/brainco_hand_service ./build.sh
find ~ -name stark-sdk.h 2>/dev/null      # 找不到时用这个
```

### E4. bash 默认参数展开的坑（写 build.sh 时踩过）

`for t in "${@:-a b}"` 在无参时展开成**一个**词 `"a b"`，不是两个。
必须用数组：

```bash
targets=("$@"); [[ ${#targets[@]} -eq 0 ]] && targets=(a b)
```
