# TODO: Host 声明式组合（Host-declared composition）重构方案

状态：方案已讨论定稿（第二轮），分步实施尚未开始
记录日期：2026-09-22
关联：`claw/todo/blueprint-text-input.md`（头显内文本输入，本方案第 4 步的一个 view 原语）

## 0. 术语

| 术语 | 含义 |
| --- | --- |
| **headset** | 运行 Operator APK 的头显（Quest / Pico）。 |
| **host（主机端）** | 头显所连接的那台机器及其上的程序：遥操时是机器人车载电脑（`xr-bridge` / 适配器），导航、Live Feed 时是 GPU 服务器（`pyoperator` 程序）。host 发布声明、接收头显数据。头显不区分它背后是真机、仿真还是模型服务。仓库现有文档中的 "robot/host"、"source"（Blueprint 发布方）统一改称 host；"source" 一词留给数据源组件。 |
| **host 声明** | host 发给头显的全部声明 = **描述符**（`DeviceDescriptor`，会话建立时交换一次：`xr_stream` / `capture_streams` / `video_feeds` / `capabilities`）+ **Blueprint**（渲染与交互，会话中可按 revision 替换）。 |
| **Blueprint** | host 声明中的渲染/交互部分（wire 契约，`specs/blueprint/v1.json`，三端生成绑定并以 hash 锁定）。 |
| **capability（能力）** | APK 内置的实现：相机采集、编码器、渲染器、权限流程、平台差异处理。能力只随 APK 版本增长，永不从网络传入。 |
| **component（组件）** | 头显内部一个可被任何宿主挂载的能力实现单元（source / processor / sink / view）。组件是头显本地概念，**不是** wire 契约的一部分。 |
| **stream（流）** | 头显→host 的命名数据流，沿用 OLCP 词汇：`rgb.hevc`、`depth.u16`、`head_pose.json`、`controller_pose.json`、`controller_input.json`、`hand_joints.json`、`audio.*`。 |
| **composition（组合）** | 一次会话里实际生效的组件连线。由三方共同决定：preset/本地默认、host 声明、用户同意与覆盖。 |
| **consent（同意）** | 用户对头显能力被 host 使用的授权。 |
| **`godot_ticks_ns`** | 头显上唯一的采样时基：Godot `Time.get_ticks_usec()` 域（ns），OpenXR `XrTime` 与 Android `System.nanoTime()` / Camera2 时间戳都通过捕获的偏移映射进该域。见 3.7。 |

## 1. 目标与原则

**目标**：Operator APK 成为通用运行时。除完全离线的功能（Ego 本地录制、上传管理）外，所有依赖远端的行为都由 host 的声明定义，而不是预先烙在 APK 的某个"模式"里。新增一个机器人、一个算法、一个场景，不重编 APK。

**原则**（写进架构文档，作为硬规则）：

1. **APK 提供能力，host 提供声明，用户拥有同意权。**
2. **声明的是"要什么"，不是"怎么做"**。host 声明启用哪些能力、参数、连线；实现全部在 APK 内。不传代码、场景、shader、任意资源路径（现有规则保留）。
3. **数据只流向声明它的 host**，或头显本地已配置并验证过的 ingest 端点。
4. **两类数据不混**：声明与低速状态走 latest-wins 的结构化通道；高速率流（HEVC/深度/点云/视频）走专用二进制通道。声明层永远不承载流。
5. **本地永远拥有**：安全互锁与控制仲裁、权限流程、平台选择、边界策略、追踪校准。host 对这些最多"请求"。
6. **时间戳链路是冻结契约**：任何步骤都不改变采样器、编码器、写入器为样本打时间戳的方式（见 3.7）。

## 2. 现状与度量（2026-09-22，主分支 `a67a902`）

以下数据来自对代码的直接度量，是本方案取舍的依据。

### 2.1 两条平行栈

| | Teleop 会话（xr-bridge） | Live Feed（OLCP） |
| --- | --- | --- |
| 端口 / 发现 / 鉴权 | 63900–63904 + 视频 12345；beacon + `Hello` capabilities | 63910 push / 63912 pull；QR + `auth_token` |
| host 声明"从头显要什么" | 描述符 `xr_stream {schema_version, rate_hz, streams}` → `xr_state_sender.configure()` | `capture_request`（live-pull 通道）：`selected_streams`、`limits.rgb_max_hz / rgb_bitrate_bps / rgb_eye` |
| 头显→host | `XrStateFrame`（head / controllers+input / hands / body / trackers，latest-wins） | `head_pose` / `controller_pose` / `controller_input` / `hand_joints`：**同一批传感器的第二套编码**（`xr_state_sender.gd` 201 行 vs `pose_sampler.gd` 503 行） |
| 相机 / 深度 | 无 | `rgb.hevc`、`depth.u16`（唯一路径） |
| host→头显 | Blueprint / State / Event + H.264（`video_feeds` 协商） | 点云 chunk；`algorithm_status`、`camera_trajectory` 仅打 log |
| 渲染器 | `xr/scripts/blueprint/` 2013 行 | `live-pull` 948 行，`display_as_minimap` 默认 true、无协议字段可切 1:1 |
| host 侧模型 | `pyoperator/models.py` 304 行 | `pyoperator/live_feed/models.py` 1008 行 |
| 时基 | `timestamp_ns` / `sample_timestamp_ns`：`godot_ticks_ns` | `pts_ns`：`godot_ticks_ns`（绝对值原样透传）；`session_start` 已含 `session_start_godot_ticks_us` |

一个 host 若同时需要 UI 和头显相机，今天必须说两种协议、开 4 个端口，且两者在 APK 里是**两个独立场景**，不能共存。

### 2.2 模式脚本的构成（按函数名归类，含约 13–24% 未归类）

`capture_app_base.gd`：3325 行、153 个函数。权限/平台/provider/插件 21%（708 行），会话生命周期 12%，QR/上传 8%，指标/解析 7%，**Live Feed 专属 7%（239 行、17 个函数）**，自动化 7%，追踪/租约 6%，UI 5%，passthrough 3%，play space 1%。基类内"连线"代码 **0 行**；三个 composition 文件合计 **173 行**（41 + 95 + 37）。`_is_live_feed_mode()` 被引用 **36 处**。

`teleop_controller.gd`：3233 行、164 个函数。会话/连接/重连 22%（721 行），UI 9%，生命周期 9%，机器人控制/安全 8%，视频/FPV 7%，追踪 6%，**Blueprint 宿主 6%（180 行）**。

结论：声明式的图能替代的只有 173 行连线；耦合的真正来源是**相机/推流/拉流/权限逻辑没有从基类抽出**（36 处模式分支）。

### 2.3 Blueprint 契约语言的表达力实验

在 `specs/blueprint/v1.json` 副本上加入 `rgb_camera_source` / `spatialmp4_sink` / `olcp_push_sink`，运行生成器：

| 尝试 | 结果 |
| --- | --- |
| 塞进现有 `host: node3d`，只用现有字段类型 | 接受（语言无法区分相机源与 label） |
| `host: source / sink` | 拒绝：unsupported host（`HOST_TYPES` 只有 node3d / external_view / system_menu） |
| `outputs` / `inputs` 端口、`scope: local` | 拒绝：unsupported keys |
| string 的 `enum` 约束 | 拒绝：unsupported keys |
| `path` 字段类型 | 拒绝：unsupported type（`FIELD_TYPES` 共 9 种） |

诚实建模 source/sink 需要 4 个新语言构造并改写安全词汇（Blueprint 明确禁止 host 主机名与任意路径）。因此**组件不进 wire 契约**；"host 从头显要什么"进描述符（3.2）。

### 2.4 成本与频率

- Blueprint 诞生于 2026-09-11，三次提交（09-11 / 09-16 / 09-21）各 49–80 个文件。今天一个普通原语落在 7–14 个手写文件（spec、python 1–2、python 测试 1–3、rust 1、xr 脚本 1–2、xr 测试 1–3）；`label` 因到处使用是 42 个。
- 仓库 368 次提交（06-02 → 09-21）。所有模式与 composition 在 06-12 一次重构成型，之后 composition 目录仅 5 次提交；变化集中在模式脚本（27 次、38 次）。
- 9 月新增 5 个 host 侧场景（so101、brainco-revo2、unitree-g1d、whole-body-control、light-o1），**零 XR 改动**全部被现有 Teleop/Outside 组合吸收——"host 声明"在 UI 层已被验证。
- 在 Teleop 场景内启用相机推流的最小代码链：9 个函数、389 行，触及 18 个成员变量与 24 个基类函数。**不存在便宜的复制路径，最小路径就是抽组件。**

### 2.5 已具备的基础

- 描述符已是"host 从头显要什么 / 给头显什么"的协商载体：`xr_stream`（要姿态流）、`video_feeds`（给视频）、`capabilities`（含 `blueprint_v1@sha256`）；头显在 `Hello.capabilities` 通告 `xr_state_v1` 等。
- `capture_request.limits` 已支持 host 端控制 `rgb_max_hz`（1–60）、`rgb_bitrate_bps`（0.5–24 Mbps）、`rgb_eye`。
- sink 接口已统一：`accepted_frame_types() / start(options) / stop() / policy() / health() / on_frame(frame)`；`StreamBinding` 扇出；`CaptureSessionController` 管生命周期；`CaptureProviderRegistry` 做能力探测。
- Blueprint 的 `external_view`（`video_panel`）已是"声明视图、内容走媒体通道"的范式；`BlueprintRuntime` 设计为可复用宿主。
- 头显本地已有"经验证的端点"概念：上传端点经 QR → `_start_upload_ack` 握手 → 用户 Save；Live 服务器地址也经 QR。
- 组件基类规则已成型：`SensorSink` 子类、`LivePushWriter`、`CaptureSessionController` 是 RefCounted；`PoseSampler`、`TrackingProvider` 是 Node；`BlueprintRuntime`、`LivePullDenseMapView` 是 Node3D。
- 时基已统一（见 3.7）：所有采样路径都落在 `godot_ticks_ns`；OLCP `session_start` 已带 `session_start_unix_us` 与 `session_start_godot_ticks_us`。
- `export_presets.cfg` 四个 preset 的 `operator_feature_mode_live_feed` 均为 `true`（卡片显示中）。

## 3. 目标架构

### 3.1 四层

```
┌ 策略层  consent 表 · 限幅 · 端点白名单 · 指示与撤回                       （头显本地，数据驱动）
├ 声明层  host 声明 = 描述符（xr_stream / capture_streams / video_feeds）+ Blueprint（components / assets）
├ 能力层  组件：source / processor / sink / view                            （APK 内置，任何宿主可挂载）
└ 会话层  一个 host = 一个会话；ctrl / xr_state / media_up / media_down 四类通道
```

### 3.2 声明层：描述符（协商）+ Blueprint（渲染/交互）

**放置原则**：需要在会话建立时协商一次、涉及 consent 的内容放描述符；渲染与交互放 Blueprint。描述符交换正是 consent 发生的时机；Blueprint 可在会话中按 revision 反复替换，不适合承载需一次性同意的东西。

**描述符扩展**（与现有 `xr_stream` 并列）：

```json
"xr_stream":       {"schema_version": 1, "rate_hz": 72, "streams": ["head", "controllers"]},
"capture_streams": {
  "schema_version": 1,
  "sink": {"protocol": "olcp.v1", "push_port": 63910, "result_port": 63912},
  "streams": [
    {"name": "rgb.hevc",  "required": true,  "max_hz": 4, "bitrate_bps": 2000000, "eye": "left"},
    {"name": "depth.u16", "required": false, "max_hz": 5}
  ],
  "local_tasks": [
    {"kind": "record", "container": "spatialmp4", "streams": ["rgb.hevc", "head_pose.json"]},
    {"kind": "upload", "endpoint_ref": "lab-ingest"}
  ]
}
```

- `sink.protocol / ports`：过渡期字段。头显把流推到**连接的对端**（地址不可声明）的这些端口，host 侧用现有 `pyoperator.live_feed.LiveFeedReceiver` 接收。第 6 步通道统一后删除。
- `streams[].name` 沿用 OLCP 词汇；参数只用现有 9 种字段类型。头显只接受它在 `Hello.capabilities` 里通告过的流（新增 `stream.rgb.hevc`、`stream.depth.u16`、`stream.audio` 等能力项）。
- **`required` 不阻断连接**：用户拒绝相机不断开遥操；它只影响 `streams_status` 与提示优先级，host 自行降级（导航例子：label 显示"需要相机"）。
- `local_tasks` 与 `streams` 分开命名，便于将来单独收紧。`upload.endpoint_ref` 只能引用头显本地已配置并验证过的端点名，host 不能给 URL。
- 描述符扩展也走 spec 生成：`specs/descriptor/capture_streams.v1.json`，复用 `scripts/generate_blueprint_spec.py` 的字段类型与三端输出，避免 Rust serde / Python dict / GDScript 手写漂移。第 3 步实施。

**Blueprint**：保持"渲染什么、怎么交互"。现有全部原语 + 新增 `path`、`marker`；`dense_map` 作为 `external_view`；`robot_model` 资产不变。

**头显的回答：`StreamsStatus`**——ctrl 通道上与 `Hello` 同级的新命令，在协商后、consent 变化、能力 narrow 时发送：

```json
{"schema": "operator.streams_status.v1",
 "streams": {"rgb.hevc":  {"state": "active", "hz": 4, "eye": "left"},
             "depth.u16": {"state": "denied", "reason": "consent_declined"}},
 "local_tasks": {"record": {"state": "running"},
                 "upload": {"state": "denied", "reason": "unknown_endpoint"}}}
```

不放进 `BlueprintState`（那是 host→头显方向；反向的 `BlueprintEvent` 语义是交互事件）。它是今天 `session_start` 后 `capture_request` 重规划的正式化。

### 3.3 能力层：头显组件

统一生命周期：`configure(properties) → bind(streams) → start() → stop()`，加 `policy() / health()`，与现有 sink 接口对齐。基类规则：需要 `_process` / 信号 / 场景树的（source、view）是 Node；纯数据流的（sink、planner、policy）是 RefCounted。

| 组件 | 来源 | 说明 |
| --- | --- | --- |
| `CameraSource`（Node） | 从 `capture_app_base.gd` 抽出（`_bind_android_plugin`、`_start/_try_start/_stop_camera_plugin` 等 389 行链） | provider 绑定 + 相机权限等待 + 插件启停 + Quest 4:3 / Pico 原生管线差异；接 Android 插件信号 |
| `DepthSource`、`AudioSource`（Node） | 同上 | |
| `PoseSource`（Node） | 合并 `xr_state_sender.gd` 与 `pose_sampler.gd` | 唯一的姿态编码器，按订阅扇出到 `xr_state` 通道或流；时间戳仍由 `resolve_pose_timestamp_ns` 决定 |
| `HandSource`、`BodySource` | 现有 native hand worker / body sampler | 继续走 tracking lease |
| `LivePushSink`（RefCounted） | `LiveStreamSink` + `LivePushWriter` | 目标只能是当前会话的 host |
| `SpatialMp4Sink`、`UploadSink`（RefCounted） | 现有 | 本地任务；**时间戳处理零改动** |
| `LivePullView` / `DenseMapView`（Node3D） | `live_pull_dense_map_view.gd` | 挂在 Blueprint `dense_map` external_view 之下；minimap 变为 anchor/scale 属性 |
| `ConsentPolicy`（RefCounted） | 新增 | 见 3.5，数据驱动 |
| `StreamPlanner`（RefCounted） | `_on_capture_request_received` 等 | 合并 host 声明 × 本地上限 × consent × 能力通告 → 有效 composition，输出 `StreamsStatus` |

组合根（今天的三个 composition 文件）变为解释器：给定生效的 composition，实例化组件并连线。

### 3.4 会话层

- **目标**：一个 host = 一个会话 = 一份声明。通道：`ctrl`（descriptor、Blueprint、State、Event、`StreamsStatus`、命令、遥测）、`xr_state`（唯一姿态源）、`media_up`（rgb / depth / audio）、`media_down`（视频、点云、结果）。
- **过渡**：xr-bridge 会话与 OLCP 并存；Teleop 场景内的 `LivePushSink` 用 OLCP 帧格式推到同一 host 的 `capture_streams.sink` 端口；`capture_streams` / `StreamsStatus` 走 ctrl 通道。
- **终态**：OLCP 信封并入 xr-bridge 会话（或反向），单一发现/鉴权；OLCP 姿态流退役；`pyoperator.XrSession` 长出 `streams` 与 `results` API，`pyoperator.live_feed` 降为媒体编解码层。
- **时基**：无需统一——已经同域（3.7）。

### 3.5 策略层（已决定）

**同意按能力类别（决定 C）**，做成一张表，不散在代码里：

| 类别 | 策略 |
| --- | --- |
| 姿态 / 手柄 / 手（`xr_state`） | 连接即允许（与今天 Teleop 一致） |
| 身体追踪 / 外部追踪器 | 现有 tracking lease + 系统设置校准确认 |
| 相机 RGB / 深度 | **描述符交换时一次性列出该 host 请求的所有相机流，确认一次**；会话期间常驻"正在向 \<host\> 推流"指示；可一键撤回，撤回后 `StreamsStatus` 变 `denied: revoked` |
| 音频 | 同相机 |

**允许 host 编排本地任务（决定 2，将来可能收紧）**：录制与上传可由 host 请求，但 ① 目标只能是当前 host 或头显本地已验证端点（`endpoint_ref`）；② 执行期间有本地指示；③ 用户可随时停止。收紧只需把可引用端点集合缩为空集。

以后若改为"按 host 记忆同意"，只需给 host 加身份（token/证书）并改表，不重写流程。

### 3.6 Launcher

只剩两类入口：**连接 host**（一切由 host 声明的场景：遥操、导航、Live Feed……）与**离线功能**（Ego 录制、上传管理）。Live Feed 不再是入口。

### 3.7 时间戳不变量：Ego 录制各 track 的对齐不受影响

**现状（已核实）**——头显上只有一个采样时基 `godot_ticks_ns`：

| 数据 | 打戳位置 | 域 |
| --- | --- | --- |
| head / controller / hand 姿态 | `pose_sampler.resolve_pose_timestamp_ns`：优先 OpenXR 预测显示时间（`XrTime`，`CLOCK_MONOTONIC`）+ `getXrTimeToGodotTicksOffsetNs`，否则 Godot ticks | `godot_ticks_ns` |
| RGB（HEVC） | 编码器 `bufferInfo.presentationTimeUs * 1000`，由相机插件把 Camera2 传感器时间戳映射进同一域 | `godot_ticks_ns` |
| 深度 | `depth_timestamp_source_priority: [openxr_runtime_display_time, godot_async_callback_ticks]` | `godot_ticks_ns` |
| 音频 | `AudioCapture`：`System.nanoTime() + clockMonotonicToGodotTicksOffsetNs`，AAC 帧 0 锚在首次麦克风读取 | `godot_ticks_ns` |
| SpatialMP4 `operator_static` | `session_start_unix_us`、`session_start_godot_ticks_us`、`timebase_hz=1e6`、`media_pts_domain="godot_ticks_ns"`、`media_pts_clock="clock_monotonic_ns"` | 契约记录 |
| OLCP `pts_ns` | Kotlin `enqueue(Frame(type, flags, timestampNs, ...))` 原样透传 GDScript 传入的时间戳；`session_start` 含 `session_start_godot_ticks_us` | `godot_ticks_ns` |
| `XrStateFrame.timestamp_ns` / `sample_timestamp_ns` | `xr_tracking_sampler` | `godot_ticks_ns`（第 3 步含一次设备验证） |

结论：Ego 各 track 之间的对齐依赖的是**所有采样器在同一域打戳**，而不是任何写入器的换算；OLCP 与 `XrStateFrame` 已经与之同域。因此本方案的时间戳工作只有：

1. 把上表写进 `claw/architecture/wire-protocol.md` 作为唯一时基契约；
2. `pyoperator.live_feed.SessionStartSample` 增加 `session_start_godot_ticks_us` / `session_start_unix_us` 访问器，并提供 OLCP 样本 ⇔ `XrFrame` 的按时间戳对齐 helper（导航例子把相机帧与头位姿对齐要用）；
3. 一次设备验证：同一 tick 的 OLCP `head_pose` 与 `XrStateFrame.head.sample_timestamp_ns` 一致。

**硬规则**：

- 第 1–6 步**不修改**任何采样器、编码器、插件、`SessionSpoolWriter` / `LivePushWriter` 的打戳逻辑与 `operator_static` 时基字段。组件抽取只搬代码；`SensorFrame` 携带的时间戳必须原样传递到每个 sink。
- `PoseSource` 合并两套编码器时，时间戳仍取自 `resolve_pose_timestamp_ns`，`xr_state` 通道与流拿到的是同一个值。
- 不引入任何"会话相对"换算；如需相对时间，由消费方用 `session_start_godot_ticks_us` 自行计算。

**回归检查**（第 1 步验收的一部分，新增 `cicd/10_track_alignment.sh` + `scripts/verify_track_alignment.py`）：

- 同一台设备、同一 preset，重构前后各录一段 Ego（含 RGB、深度、头/手柄/手、音频）；
- `operator_static` 的时基字段逐项相同（值可不同，字段与语义相同）；
- 各 track 相对关系的分布一致：`rgb_frame_index` 传感器时间戳 − RGB 媒体 PTS 的偏移分布、头位姿与最近 RGB 帧的 |Δt| 分布、`depth_frame_meta` 运行时显示时间 − 深度 PTS 的分布、音频 PTS 与其锚点的一致性；任一分布的中位数偏移超过 1 ms 或离散度变化超过 20% 即失败；
- 现有 `cicd/02_ego_record.sh` 与 `run_rerun_conversion_check.sh` 通过。

## 4. 分步实施

每步独立可发布；每步有可度量的验收。设备验证按 CLAUDE.md 只在目标设备上做。

| 步 | 内容 | 验收 | 依赖 |
| --- | --- | --- | --- |
| 0 | `operator_feature_mode_live_feed=false`；本方案原则写入 `overview.md` / `blueprint.md`（"source"→"host"）；3.7 时基表写入 `wire-protocol.md` | `cicd/04` 仍通过（走 intent） | — |
| 1 | 从 `capture_app_base.gd` 抽出 `CameraSource` / `DepthSource` / `AudioSource` / `LivePushSink` / `LivePullView` / `StreamPlanner`，基类与 Ego 组合行为不变 | `_is_live_feed_mode()` 36 → 0；基类减少 ≥ 600 行；`cicd/02`、`cicd/04` 通过；**3.7 回归检查在 Quest 与 Pico 各通过一次** | 头显 + CI harness |
| 2 | Live Feed 降为 Ego 采集 Output 面板的 sink 选项（本地 / host / 两者）；删除 `live_feed_app.tscn`、`live_feed_mode.gd`、`live_feed_composition.gd`；`mode_live_feed.json` 清单迁移 | Launcher 无 Live Feed 卡；E2E 改经 Ego 入口 | 1 |
| 3 | 描述符 `capture_streams`（含 spec 生成 `specs/descriptor/capture_streams.v1.json`）；`StreamsStatus` 命令（Rust `teleop-protocol` / `operator` crate、pyoperator、GDScript）；`ConsentPolicy` 表 + 推流指示 + 撤回；`Hello.capabilities` 通告流能力；Teleop 组合可挂 `CameraSource` + `LivePushSink`（OLCP 帧格式推到 `capture_streams.sink` 端口）；`SessionStartSample` 时基访问器 + 对齐 helper | 一个 host 会话同时拿到 UI、`robot_model` 与 4 Hz 左眼 RGB；两份 spec `--check` 三端一致；设备用例覆盖同意 / 拒绝 / 撤回 / `required` 被拒不断连；OLCP 与 `XrStateFrame` 姿态时间戳一致性验证 | 1 |
| 4 | view 原语 `path`、`marker`；`dense_map` external_view 接管 `LivePullView`（minimap 改属性） | 导航例子的轨迹以 Blueprint state 绘制在地面；`validate_xr_features` 通过 | 3 |
| 5 | `local_tasks`（record / upload）+ 本地端点引用 + 指示 | host 可编排"推流同时本地录制并上传到已验证端点"；3.7 回归检查再跑一次（record 任务复用 `SpatialMp4Sink`，打戳不变） | 2、3 |
| 6 | 通道统一：OLCP 并入 xr-bridge 会话；姿态流去重（`PoseSource` 唯一）；单一发现 / 鉴权；删除 `capture_streams.sink`；`XrSession.streams` / `results` API | `pose_sampler.gd` 编码逻辑删除；host 只开一组端口；`pyoperator.live_feed` 仅剩编解码；3.7 回归检查通过 | 3、4、5 |

导航例子 `examples/lightnav` 依赖第 1、3、4 步（第 4 步可先只做 `path` / `marker`）。

## 5. 风险与边界

- **设备验证依赖**：第 1 步触碰 Quest 字节缓冲编码、Pico 零拷贝管线，只能真机回归；apex 无 Godot，APK 需在有 XR 工具链的机器上构建。
- **时间戳链路是冻结契约**：3.7 的硬规则与回归检查是第 1、5、6 步的门禁，不是建议。
- **spec hash 锁三端**：每次 spec 变更要求 pyoperator、xr-bridge、APK 同一 checkout 发布（现状已如此）；第 3 步起有两份 spec。
- **Rust 桥改动**：第 3 步 `capture_streams` / `StreamsStatus` 要改 `teleop-protocol` / `operator` crate；第 6 步改动更大。
- **性能**：声明层绝不承载流；`StreamPlanner` 与 consent 在 ctrl 通道上是低速事件。
- **不做的事**：不把 source/sink 变成 Blueprint 原语；不做通用 DI 框架；不让 host 声明安全互锁、权限、平台选择、边界策略、校准；不引入第二个时基。

## 6. 未决问题

1. host 身份：consent 若将来按 host 记忆，需要 token/证书方案；今天不做。

（第一轮的其余四个问题已在本轮消解：`streams` 放描述符并走 spec 生成；`upload.endpoint_ref` 引用头显本地已验证端点；`StreamsStatus` 为 ctrl 通道独立命令；时基已同域，无需映射；组件基类规则按现状固化。）
