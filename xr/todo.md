# XR UI 游戏化改造 TODO

目标：把当前"工程师风格"的暗色面板 UI 改造成有"驾驶舱/操作员"质感的体验。
原则：反馈即时、操作有质感、文案有世界观；不真的变成游戏。

调色：保留现有 `COL_ACCENT = (1.0, 0.647, 0.169)` 橙色作为统一高亮色。

---

## P0：最值得做的五条（先落，立刻有感）

### [x] 1. `UISoundBus` 全局音效单例
- 新建 `xr/scripts/ui/ui_sound.gd`，注册为 autoload。
- 使用 `AudioStreamGenerator` 程序化合成 7 种音效（不依赖二进制资源）：
  - `hover`：500Hz, 30ms, 极轻 tick
  - `click`：800Hz, 50ms, 干脆 pop
  - `toggle_on` / `toggle_off`：双音阶（开升、关降）
  - `confirm`：三音上升 arpeggio
  - `error`：低频短促 buzz
  - `connected`：解谜成功音，0.8s
  - `disconnected`：下降三音
  - `discovery_found`：雷达 ping
  - `exit_charging`：持续上升音调
- 在 VR 中用 `AudioStreamPlayer3D` 挂到 panel 本体，声音有空间感。
- API：`UISoundBus.play("click")` / `UISoundBus.play_at(node, "ping")`。

### [x] 2. `Haptics` 手柄震动 helper
- 新建 `xr/scripts/ui/haptics.gd`（autoload 或静态类）。
- API：`Haptics.pulse(controller, amplitude, duration)` / `Haptics.fire(event_name)`。
- 事件 → 强度表：
  - `hover_cross`：amp=0.15, dur=0.03
  - `click`：amp=0.5, dur=0.05
  - `confirm`：双击 0.7 → 0.4，间隔 60ms
  - `exit_charging`：每 0.4s 一次心跳，越接近完成越密集
  - `connected`：0.25s, amp=0.6
- 接到现有 button hover/pressed 钩子。

### [x] 3. ModeSelect 改成"卡牌选角"
文件：`xr/scenes/ui/mode_select_ui.gd`
- 大图标 + 主标题 + 副标题三段式布局。
- 临时图标用 `_draw()` 程序化绘制（机械臂 = 三段折线，眼睛 = 圆+椭圆）。
- Hover 时按钮放大 1.08 + 上浮 8px（`TRANS_BACK ease OUT`，0.15s）。
- 未 hover 那张 `modulate.a = 0.55`，hover 那张 `modulate = (1.15, 1.1, 0.95)`。
- 背景流动光带（横向渐变循环）。
- 副标题文案：`UI_TELEOP_MODE_SUB = "操控你的机械分身"`、`UI_EGO_MODE_SUB = "第一人称记录世界"`。

### [x] 4. SVG 图标库 + 文字按钮换图标
- 新建 `xr/assets/icons/`，引入轻量 SVG 图标集（Lucide 风格，自带 OK）。
- 优先替换位置：
  - settings_button_ui：⚙️
  - Disconnect：🔌（红色 modulate）
  - Back：←
  - OK / Apply：✓
  - Exit：🚪 / power
  - robot_arm / rc_car：🦾 / 🚗（OptionButton 选项前缀）
  - Discovered list 状态点：🟢 / 🟡 / 🔴
  - HUD：📈 FPS / 📱 Platform / 👀 Tracking
- 原则：图标 + 文字并存，不要纯图标（VR 无 tooltip）。

### [x] 5. 连接握手序列剧情化
文件：`xr/scenes/ui/connection_panel.gd`
- 按下 Enter Control 之后，分 3 步弹卡片：
  1. `📡 正在广播 Hello…`（扫描 spinner）
  2. `🤝 等待设备应答…`（直到 DeviceDescriptor）
  3. `✅ %s 已上线`（0.5s 后切 CONTROL）
- 三步用 `Tween` 横向滑入滑出（右进左出）。
- 配 `discovery_found` / `connected` 音效。

---

## P1：中等收益

### [x] 6. `HoldIndicator` 升级成环形蓄力条
文件：`xr/scripts/ui/base_settings_panel.gd`
- `draw_arc` 画环形进度，橙→红渐变。
- 进度 > 0.5 时按钮 `position += randf_range(-1, 1)` 轻微震动。
- 完成瞬间白色闪光帧 + `confirm` 音效。

### [x] 7. 每个 Panel 开关过渡 Tween
文件：`xr/scripts/ui/base_settings_panel.gd`（覆盖 `open()` / `close()`）
- 打开：scale 0.9 → 1.0、alpha 0 → 1、`TRANS_BACK ease OUT`，0.25s。
- 关闭：反向 0.15s。
- VR 额外：从视线正下方 5cm 滑入。

### [x] 8. ItemList → 机器人卡片网格
文件：`xr/scenes/ui/connection_panel.gd` `_refresh_robot_list`
- 改 `GridContainer`，每 robot 一张卡：图标 + name 大字 + ip:port 小字 + 状态点。
- Hover 浮起 + 发光边框 + 哒一声。
- 双击 = 直连（保留 `_on_robot_activated` 快路径）。

### [x] 9. HUD "游戏 HUD" 美学
文件：`xr/scenes/ui/hud.gd` / `hud.tscn`
- 半透明圆角胶囊 + 每状态图标 + 数字。
- FPS 颜色编码：≥72 绿 / 60–72 黄 / <60 红。
- Tracking 三段小条：Head / Left / Right，每段亮起代表追踪正常。
- 连接状态用 1Hz 呼吸点，断开变红 + 慢心跳。

### [x] 10. i18n 文案游戏化
文件：`xr/scripts/i18n/*`
| 键 | 改前 | 改后 |
|---|---|---|
| UI_INITIALIZING | Initializing | 系统启动中… |
| UI_NOT_CONNECTED | Not connected | 未与设备建立链接 |
| UI_DRIVER_ACTIVE | Driver active: %s | 操作链路已建立 · %s 待命 |
| UI_DISCONNECTED | Disconnected | 链路中断 |
| UI_NO_HARDWARE_ADDRESS | Enter address | 请输入目标地址，操作员 |
| (Exit hint) | — | 长按确认 · 撤离当前任务 |

---

## P2：加分项

### [ ] 11. 环境氛围音
- ModeSelect 进入循环轻电子环境音（< -20dB）。
- 切 CONTROL 状态时换"在线"循环。

### [ ] 12. 背景粒子
- ModeSelect 面板后挂 `GPUParticles3D`，缓慢飘的发光点。

### [ ] 13. 设备指纹打字机
- CONTROL 页面 device 名字逐字打字机（`Tween.tween_method` + substring）+ ticker 音效。

### [ ] 14. 设备记忆感
- 第一次成功连接的 robot 存 `user://known_robots.cfg`。
- 下次出现时显示 "再次连接到 OldFriend-01"。

### [ ] 15. 错误反馈视觉化
- IP 错误时输入框红色抖动 0.3s（左右 6px） + error 音效。

### [ ] 16. 场景过渡黑场
- Mode Select → Teleop：0.5s 黑场 + 大字 "TELEOP MODE" 闪现 + 淡入。

---

## 不做

- 3D 模型按钮（VR 中点击精度差、性能开销大）。
- 花哨字体（VR 中非衬线高对比为王）。
- 真的可玩性元素（连接小游戏等 —— Operator 是工具）。

---

## 落地顺序建议（一个 PR 一项）

1. P0-1 `UISoundBus` autoload + 9 个程序化音效
2. P0-2 Haptics helper + 全部 click/hover 接上
3. P0-3 ModeSelect 卡牌重做
4. P0-4 SVG 图标库 + 文字按钮替换
5. P0-5 握手序列剧情化
6. P1-9 HUD 视觉升级
7. P1-10 i18n 文案游戏化
8. P1-6 HoldIndicator 环形蓄力
9. P1-7 Panel 开关过渡
10. P1-8 卡片网格
11. P2 系列按需

---

## 当前并行批次

第一批（互不冲突的文件域）：
- **A**：P0-1 音效系统 + P0-2 Haptics（新文件 + `project.godot` autoload 注册）
- **B**：P0-3 ModeSelect 卡牌重做（`mode_select_ui.gd`）
- **C**：P1-9 HUD 升级（`hud.gd` / `hud.tscn`）
- **D**：P1-6 HoldIndicator 环形 + P1-7 Panel 开关 Tween（`base_settings_panel.gd`）
- **E**：P1-10 i18n 文案（`i18n/*`）
