# TODO: Host 声明式组合（Host-declared composition）重构方案

状态：第 0–6 步已实现（含导航例子 `examples/lightnav`）。主机端仅设备用例未跑（无头显）：`cicd/02`、`cicd/04`、`cicd/08`、`xr_module_harness`、第二道门。
记录日期：2026-09-22（实施：2026-09-23）
第 6 步未决问题 2 的决定：`media_up` 复用 OLCP v1 帧格式，由 xr-bridge 在自己的端口组（默认 63905 / 63906）中继；地址与 `auth_token` 由会话注入描述符的 `media` 块，host 程序永不声明传输。
关联：`claw/todo/blueprint-text-input.md`（头显内文本输入，本方案第 4 步的一个 view 原语）

## 0. 术语

| 术语 | 含义 |
| --- | --- |
| **headset** | 运行 Operator APK 的头显（Quest / Pico）。 |
| **host（主机端）** | 头显所连接的那台机器及其上的程序：遥操时是机器人车载电脑（`xr-bridge` / 适配器），导航、算法服务时是 GPU 服务器（`pyoperator` 程序）。host 发布声明、接收头显数据。头显不区分它背后是真机、仿真还是模型服务。仓库现有文档中的 "robot/host"、"source"（Blueprint 发布方）统一改称 host；"source" 一词留给数据源组件。 |
| **host 声明** | host 发给头显的全部声明 = **描述符**（`DeviceDescriptor`，每次连接 Hello 之后交换一次：`xr_stream` / `capture_streams` / `video_feeds` / `capabilities`）+ **Blueprint**（渲染与交互，会话中可按 revision 替换）。 |
| **Blueprint** | host 声明中的渲染/交互部分（wire 契约，`specs/blueprint/v1.json`，三端生成绑定并以 hash 锁定）。 |
| **capability（能力）** | APK 内置的实现：相机采集、编码器、渲染器、权限流程、平台差异处理。能力只随 APK 版本增长，永不从网络传入；头显在 `Hello.capabilities` 通告。**能力永远属于头显，host 只能获得使用许可。** |
| **component（组件）** | 头显内部一个可被任何宿主挂载的能力实现单元（source / sink / view，以及权限层的几个纯逻辑单元）。组件是头显本地概念，**不是** wire 契约的一部分。 |
| **stream（流）** | 头显→host 的命名数据流，沿用 OLCP 词汇：`rgb.hevc`、`depth.u16`、`head_pose.json`、`controller_pose.json`、`controller_input.json`、`hand_joints.json`、`audio.*`。 |
| **composition（组合）** | 一次会话里实际生效的组件连线。由三方共同决定：preset/本地默认、host 声明、用户授予的权限与覆盖。 |
| **permission（权限）** | 不加限定时指 **host permission**：用户经头显授予某个 host 使用头显某类能力、或把数据送到某个去向的许可。与 **system permission**（Android 运行时权限，OS 授予 APK，如 `CAMERA` / `RECORD_AUDIO`）是两层：system permission 在 source 组件内部处理，不出现在权限层。 |
| **ingest 端点 / ingest 会话** | 头显本地配置（QR 扫码）并验证过的**被动接收端**：上传服务器、实时推流服务器。N:1——一个服务器接收多台头显；由头显/用户发起；服务器不发声明（它的 `capture_request` 只能缩小集合）。与 host 会话（1:1，host 发声明）相对。 |
| **`godot_ticks_ns`** | 头显上唯一的采样时基：Godot `Time.get_ticks_usec()` 域（ns），OpenXR `XrTime` 与 Android `System.nanoTime()` / Camera2 时间戳都通过捕获的偏移映射进该域。见 3.7。 |

## 1. 目标与原则

**目标**：Operator APK 成为通用运行时。除完全离线的功能（Ego 本地录制、上传管理、Ego 推流到 ingest 端点）外，所有依赖远端的行为都由 host 的声明定义，而不是预先烙在 APK 的某个"模式"里。新增一个机器人、一个算法、一个场景，不重编 APK。

**原则**（写进架构文档，作为硬规则）：

1. **APK 提供能力，host 提供声明，用户决定权限。**
2. **声明的是"要什么"，不是"怎么做"**。host 声明启用哪些能力、参数信封、连线；实现全部在 APK 内。不传代码、场景、shader、任意资源路径（现有规则保留）。
3. **数据只流向声明它的 host，或头显本地已验证的 ingest 端点。**
4. **两类数据不混**：声明与低速状态走 latest-wins 的结构化通道；高速率流（HEVC/深度/点云/视频）走专用二进制通道。声明层永远不承载流。
5. **本地永远拥有**：安全互锁与控制仲裁、system permission 流程、平台选择、边界策略、追踪校准。host 对这些最多"请求"。
6. **时间戳链路是冻结契约**：任何步骤都不改变采样器、编码器、写入器为样本打时间戳的方式（见 3.7）。

## 2. 现状与度量（2026-09-22，主分支 `a67a902`）

以下数据来自对代码的直接度量，是本方案取舍的依据。

### 2.1 两条平行栈

| | Teleop 会话（xr-bridge） | Live Feed（OLCP） |
| --- | --- | --- |
| 端口 / 发现 / 鉴权 | 63900–63904 + 视频 12345；beacon + `Hello` capabilities；**无鉴权** | 63910 push / 63912 pull；QR + `auth_token`（配置了即校验：`runtime.py:570`、`results.py:420`） |
| 基数 | **1:1**：新连接替换旧 socket（wire-protocol.md） | 服务端逐连接串行处理（`server.py:712`、`LiveFeedReceiver.sessions()`），会话目录按 peer 命名——形态是 **N:1**，实现是排队式 |
| host 声明"从头显要什么" | 描述符 `xr_stream {schema_version, rate_hz, streams}` → `xr_state_sender.configure()`；**描述符只在每次 Hello 之后发一次**（`pose_server.rs:321`），重连重发 | `capture_request`（live-pull 通道）：`selected_streams`、`limits.rgb_max_hz / rgb_bitrate_bps / rgb_eye`。头显支持重复请求（`_on_capture_request_received` 每次重置合并），但 pyoperator 只在 result client 连接时发一次 `config.capture_request`（`runtime.py:661/678`），**没有会话中改参 API** |
| 头显→host | `XrStateFrame`（head / controllers+input / hands / body / trackers，latest-wins） | `head_pose` / `controller_pose` / `controller_input` / `hand_joints`：**同一批传感器的第二套编码**（`xr_state_sender.gd` 201 行 + `xr_tracking_sampler.gd` 513 行 vs `pose_sampler.gd` 503 行） |
| 相机 / 深度 | 无 | `rgb.hevc`、`depth.u16`（唯一路径） |
| host→头显 | Blueprint / State / Event + H.264（`video_feeds` 协商） | 点云 chunk；`algorithm_status`、`camera_trajectory` 仅打 log |
| 渲染器 | `xr/scripts/blueprint/` 2013 行 | `live-pull` 948 行，`display_as_minimap` 默认 true、无协议字段可切 1:1 |
| host 侧模型 | `pyoperator/models.py` 304 行 | `pyoperator/live_feed/models.py` 1008 行 |
| 时基 | `timestamp_ns` / `sample_timestamp_ns`：`godot_ticks_ns` | `pts_ns`：`godot_ticks_ns`（绝对值原样透传）；`session_start` 已含 `session_start_godot_ticks_us` |

一个 host 若同时需要 UI 和头显相机，今天必须说两种协议、开 4 个端口，且两者在 APK 里是**两个独立场景**，不能共存。

### 2.2 模式脚本的构成（按函数名归类，含约 13–24% 未归类）

`capture_app_base.gd`：3325 行、153 个函数。权限/平台/provider/插件 21%（708 行），会话生命周期 12%，QR/上传 8%，指标/解析 7%，**Live Feed 专属 7%（239 行、17 个函数）**，自动化 7%，追踪/租约 6%，UI 5%，passthrough 3%，play space 1%。基类内"连线"代码 **0 行**；三个 composition 文件合计 **173 行**（41 + 95 + 37）。`_is_live_feed_mode()` 被引用 **36 处**。

`teleop_controller.gd`：3233 行、164 个函数。会话/连接/重连 22%（721 行），UI 9%，生命周期 9%，机器人控制/安全 8%，视频/FPV 7%，追踪 6%，**Blueprint 宿主 6%（180 行）**。

结论：声明式的图能替代的只有 173 行连线；耦合的真正来源是**相机/推流/拉流/权限逻辑没有从基类抽出**（36 处模式分支），以及**会话/连接逻辑没有从 teleop 模式脚本抽出**。

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

### 2.5 已具备的基础与已核实的事实

- 描述符已是"host 从头显要什么 / 给头显什么"的协商载体：`xr_stream`（要姿态流）、`video_feeds`（给视频）、`capabilities`（含 `blueprint_v1@sha256`）；头显在 `Hello.capabilities` 通告 `xr_state_v1` 等。Rust 结构全部 `#[serde(default)]`、无 `deny_unknown_fields`，新增字段对旧 APK 向后兼容。`xr_stream` / `video_feeds` 是 Rust serde + `xr/scripts/contracts/teleop/device_descriptor.gd` + Python 手写三元组，未曾漂移。
- `capture_request.limits` 已支持 host 端控制 `rgb_max_hz`（1–60）、`rgb_bitrate_bps`（0.5–24 Mbps）、`rgb_eye`。
- sink 接口已统一：`accepted_frame_types() / start(options) / stop() / policy() / health() / on_frame(frame)`；`StreamBinding` 扇出；`CaptureSessionController` 管生命周期；`CaptureProviderRegistry` 做能力探测。
- **`pose_sampler.gd` 是 Ego 本地录制姿态 track 的唯一生产者**（`sample()` → `_frame_sink.on_frame(SensorFrame)` → `SessionSpoolWriter`；消费者 `ego_capture_composition.gd`、`stream_binding.gd`，下游 `web/app/scripts/spatialmp4_to_rrd.py`），同时也是 OLCP 姿态流的生产者。`xr_state_sender.gd` + `xr_tracking_sampler.gd` 是 `XrStateFrame` 的第二套编码器。
- **两套编码器同域、不同时刻**：`pose_sampler.resolve_pose_timestamp_ns` 优先 OpenXR 预测显示时间；`xr_tracking_sampler.gd:143` 以 `_ticks_usec()*1000`（采样时刻）为默认。差值量级为一帧（~14 ms @72 Hz）。
- Blueprint 的 `external_view`（`video_panel`）已是"声明视图、内容走媒体通道"的范式；`BlueprintRuntime` 设计为可复用宿主。
- 头显本地已有"经验证的端点"概念：上传端点经 QR → `_start_upload_ack` → `_apply_scanned_upload_endpoint`（单个 `upload_url` 设置，尚无命名端点表）；Live 服务器地址也经 QR。
- `capture_sink` 是场景导出属性（`live_feed_app.tscn`、`live_feed_mode.gd`），不是运行时选项；Live Feed 的 intent 路径（`mode_select.gd:581`，`operator.mode=live_feed`）不查 launcher flag。
- 组件基类规则已成型：`SensorSink` 子类、`LivePushWriter`、`CaptureSessionController` 是 RefCounted；`PoseSampler`、`DepthSampler`、`BodyMotionSampler`、`TrackingProvider` 是 Node；`BlueprintRuntime`、`LivePullDenseMapView` 是 Node3D。
- 时基已统一（见 3.7）：所有采样路径都落在 `godot_ticks_ns`；OLCP `session_start` 已带 `session_start_unix_us` 与 `session_start_godot_ticks_us`。
- `export_presets.cfg` 四个 preset 的 `operator_feature_mode_live_feed` 均为 `true`（卡片显示中）。

## 3. 目标架构

### 3.1 四层

```
┌ 权限层  permission 表 · 记忆与撤回 · 端点注册 · 限幅 · 指示                 （头显本地，数据驱动）
├ 声明层  host 声明 = 描述符（xr_stream / capture_streams / video_feeds）+ Blueprint（components / assets）
├ 能力层  组件：source / sink / view                                            （APK 内置，任何宿主可挂载）
└ 会话层  host 会话（1:1，ctrl / xr_state / media_up / media_down）· ingest 会话（N:1，media_up + 回执）
```

### 3.2 声明层：描述符（协商）+ Blueprint（渲染/交互）

**放置原则**：需要在连接建立时协商、涉及权限的内容放描述符；渲染与交互放 Blueprint。描述符交换正是权限决定发生的时机；Blueprint 可在会话中按 revision 反复替换，不适合承载需授权的东西。

**描述符扩展**（与现有 `xr_stream` 并列）：

```json
"xr_stream":       {"schema_version": 1, "rate_hz": 72, "streams": ["head", "controllers"]},
"capture_streams": {
  "schema_version": 1,
  "sink": {"protocol": "olcp.v1", "push_port": 63910, "result_port": 63912, "auth_token": "<host 每会话随机生成>"},
  "streams": [
    {"name": "rgb.hevc",  "required": true,  "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
    {"name": "depth.u16", "required": false, "max_hz": 5}
  ],
  "local_tasks": [
    {"kind": "record", "container": "spatialmp4", "streams": ["rgb.hevc", "head_pose.json"]},
    {"kind": "upload", "endpoint_ref": "lab-ingest"}
  ]
}
```

- **信封语义**：描述符声明的是**流的集合与上限**（`max_hz`、`max_bitrate_bps`、`eye`），这是权限的对象，每次连接确认一次（含记忆，3.5）。会话中的实际参数由 `StreamsControl` 在信封内调整，不触发再次授权。
- `sink.protocol / ports / auth_token`：过渡期字段。头显把流推到**连接的对端**（地址不可声明）的这些端口，host 侧用现有 `pyoperator.live_feed.LiveFeedReceiver` 接收。`auth_token` 由 host 每会话随机生成、in-band 下发——它走的是本来就无鉴权的 xr-bridge TCP，不降低现有安全水平；第 6 步通道统一后整个 `sink` 字段删除。
- `streams[].name` 沿用 OLCP 词汇；参数只用现有 9 种字段类型，`eye` 的合法值（`left` / `mono` / `stereo`）在代码里校验（契约语言无 enum）。头显只接受它在 `Hello.capabilities` 里通告过的流（新增 `capture_streams_v1` 以及 `stream.rgb.hevc`、`stream.depth.u16`、`stream.audio` 等能力项）。
- **`required` 不阻断连接**：用户拒绝相机不断开遥操；它只影响 `streams_status` 与提示优先级，host 自行降级（导航例子：label 显示"需要相机"）。
- `local_tasks` 与 `streams` 分开命名，便于将来单独收紧。`upload.endpoint_ref` 只能引用头显本地已配置并验证过的 ingest 端点名，host 不能给 URL。
- **实现方式**：与 `xr_stream` 同一套路的手写三元组（Rust serde / `device_descriptor.gd` / Python dataclass），版本协商靠 `capture_streams_v1` 能力项。spec 生成与 hash 锁不阻塞第 3 步，字段数增长后再评估。
- **兼容矩阵**：旧 APK + 新 host——APK 忽略未知字段、不通告 `capture_streams_v1`，host 收不到 `StreamsStatus`，按 unsupported 处理；新 APK + 旧 host——描述符无 `capture_streams`，行为与今天相同。

**Blueprint**：保持"渲染什么、怎么交互"。现有全部原语 + 新增 `path`、`marker`；`dense_map` 作为 `external_view`；`robot_model` 资产不变。

**头显的回答：`StreamsStatus`**——ctrl 通道上与 `Hello` 同级的新命令，在协商后、权限变化、能力 narrow、`StreamsControl` 之后发送：

```json
{"schema": "operator.streams_status.v1",
 "streams": {"rgb.hevc":  {"state": "active", "hz": 4, "bitrate_bps": 2000000, "eye": "left"},
             "depth.u16": {"state": "denied", "reason": "permission_denied"}},
 "local_tasks": {"record": {"state": "running"},
                 "upload": {"state": "denied", "reason": "unknown_endpoint"}}}
```

`reason` 取值：`permission_denied`、`revoked`、`unsupported`、`limit`（被裁剪到信封内）、`unknown_endpoint`。不放进 `BlueprintState`（那是 host→头显方向；反向的 `BlueprintEvent` 语义是交互事件）。

**host 的会话中调参：`StreamsControl`**——ctrl 通道上 host→头显的新命令，`StreamsStatus` 的对称命令：

```json
{"schema": "operator.streams_control.v1",
 "streams": {"rgb.hevc": {"hz": 2, "bitrate_bps": 1000000, "paused": false}}}
```

只能在信封内：`hz ≤ max_hz`、`bitrate_bps ≤ max_bitrate_bps`、流 ∈ 已授予集合；越界项被裁剪并在随后的 `StreamsStatus` 里报 `limit`。它把今天 OLCP `capture_request` 的重规划正式化到 host 会话内，并补上 pyoperator 侧今天不存在的会话中调帧率能力。

### 3.3 能力层：头显组件

统一生命周期：`configure(properties) → bind(streams) → start() → stop()`，加 `policy() / health()`，与现有 sink 接口对齐。基类规则：需要 `_process` / 信号 / 场景树的（source、view、HostSession）是 Node；纯数据流的（sink、权限层）是 RefCounted。

| 组件 | 来源 | 说明 |
| --- | --- | --- |
| `CameraSource`（Node） | 从 `capture_app_base.gd` 抽出（`_bind_android_plugin`、`_start/_try_start/_stop_camera_plugin` 等 389 行链） | provider 绑定 + system permission 等待 + 插件启停 + Quest 4:3 / Pico 原生管线差异；接 Android 插件信号 |
| `DepthSource`、`AudioSource`（Node） | `depth_sampler.gd`（539，已是 Node）/ 基类内 `AudioCapture` 绑定 | |
| `PoseSource`（Node） | `pose_sampler.gd`（503）**原样** | 唯一姿态编码器；只发 `SensorFrame`；打戳仍由 `resolve_pose_timestamp_ns` 决定 |
| `HandSource`、`BodySource` | 现有 native hand worker / `body_motion_sampler.gd` | 继续走 tracking lease |
| `XrStateSink`（RefCounted，新增） | 取代 `xr_state_sender.gd` + `xr_tracking_sampler.gd`（714 行）的编码部分 | 普通 sink，接在同一个 `StreamBinding` 上，把同一 tick 的 head / controllers / hands `SensorFrame` 组装成 `XrStateFrame` 交给 `HostSession`；`StreamBinding` 增加 `end_of_tick()` 触发 flush，满足"一个 tick 内不 yield 组装" |
| `LivePushSink`（RefCounted） | `LiveStreamSink` + `LivePushWriter` | 目标由会话注入：host 会话的对端，或 ingest 端点 |
| `SpatialMp4Sink`、`UploadQueueSink`（RefCounted） | 现有 | 本地任务；**时间戳处理零改动** |
| `RobotControlSink`（RefCounted） | 现有 | 遥操命令输出 |
| `DenseMapView`（Node3D） | `live_pull_dense_map_view.gd` | 挂在 Blueprint `dense_map` external_view 之下；minimap 变为 anchor/scale 属性 |
| `PermissionTable`（RefCounted，新增） | | 见 3.5，数据驱动 |
| `EndpointRegistry`（RefCounted，新增） | 今天的 `upload_url` 设置 + ack 握手 | 命名的、已验证的 ingest 端点 |
| `StreamPlanner`（RefCounted） | `_on_capture_request_received` 等 | 合并 host 声明 × 本地上限 × permission × 能力通告 → 有效 composition，输出 `StreamsStatus` |
| `HostSession`（Node） | 从 `teleop_controller.gd` 抽出连接/重连/描述符/ctrl 路由（~720 行） | 1:1；ctrl 命令的唯一收发点（Hello · Descriptor · Blueprint · State · Event · StreamsStatus · StreamsControl） |
| `IngestSession`（RefCounted） | Live Feed 的 QR / OLCP 客户端连接 | N:1；只带 `media_up` + 回执 |

组合根（今天的三个 composition 文件）变为解释器：给定生效的 composition，实例化组件并连线。

### 3.4 会话层

**两种会话**：

| | host 会话 | ingest 会话 |
| --- | --- | --- |
| 基数 | 1:1（新连接替换旧 socket） | N:1（一个服务器收多台头显） |
| 发起 / 声明 | host 发描述符 + Blueprint，头显授予权限 | 头显/用户发起（扫码、按开始），服务器被动接收 |
| 耦合 | 交互式、低延迟、双向 | 单向数据 + 少量回执；上传是 store-and-forward，独立于连接生命周期 |
| 权限 | 描述符交换时按类别确认（3.5） | 扫码 + 开始本身就是授权 |
| 共享 | `media_up` 帧格式（OLCP 信封）、`LivePushSink`、`LiveFeedReceiver`、`CaptureSessionController` | |
| 不共享 | 发现、鉴权、权限流程、生命周期 | |

- **host 会话通道**：`ctrl`（descriptor、Blueprint、State、Event、`StreamsStatus`、`StreamsControl`、命令、遥测）、`xr_state`（唯一姿态源）、`media_up`（rgb / depth / audio）、`media_down`（视频、点云、结果）。
- **过渡**：xr-bridge 会话与 OLCP 并存；host 会话内的 `LivePushSink` 用 OLCP 帧格式推到同一 host 的 `capture_streams.sink` 端口（带描述符下发的 `auth_token`）；`capture_streams` / `StreamsStatus` / `StreamsControl` 走 ctrl 通道。
- **终态（第 6 步）**：host 会话内 `media_up` 复用 OLCP 帧格式，地址与鉴权来自会话本身，删除 `capture_streams.sink`；姿态编码器去重（`XrStateSink`）；`pyoperator.XrSession` 长出 `capture` / `streams_status` / `streams_control` API。**OLCP 独立会话与 `pyoperator.live_feed.LiveFeedReceiver` 作为 ingest 协议/服务端保留**，不并入 xr-bridge。
- **时基**：无需统一——已经同域（3.7）。

### 3.5 权限层（已决定）

**按能力类别授权**，做成一张表（`PermissionTable`），不散在代码里：

| 类别 | 策略 |
| --- | --- |
| 姿态 / 手柄 / 手（`xr_state`） | 连接即允许（与今天 Teleop 一致） |
| 身体追踪 / 外部追踪器 | 现有 tracking lease + 系统设置校准确认 |
| 相机 RGB / 深度 | **描述符交换时一次性列出该 host 请求的所有相机流（信封），确认一次**；会话期间常驻"正在向 \<host\> 推流"指示；可一键撤回，撤回后 `StreamsStatus` 变 `denied: revoked` |
| 音频 | 同相机 |

**记忆**：key = (host 地址, `capture_streams` 声明的 hash)，进程生命周期内有效或直到用户撤回。描述符在每次 Hello 之后重发（2.1），重连**不重问**；声明或地址变化才重新确认。这是"host 身份"未决问题（第 6 节）的最小可用版本；将来按 host 身份记忆只需换 key。

**允许 host 编排本地任务（将来可能收紧）**：录制与上传可由 host 请求，但 ① 目标只能是当前 host 或 `EndpointRegistry` 里的 ingest 端点（`endpoint_ref`）；② 执行期间有本地指示；③ 用户可随时停止。收紧只需把可引用端点集合缩为空集。

**ingest 会话**：用户扫码并按开始即授权；ingest 服务器的 `capture_request` 只能缩小集合，不能扩大。

**两层权限**：system permission（Android）在 source 组件启动时处理，失败以 `StreamsStatus.reason = unsupported` 上报；host permission 在本层。二者互不替代。

### 3.6 Launcher

只剩两类入口：**连接 host**（一切由 host 声明的场景：遥操、导航、算法服务……）与**离线功能**（Ego 录制、上传管理）。Ego 的 sink 选项（本地 / ingest 服务器 / 两者）属于离线功能一侧，由用户决定去向；Live Feed 不再是独立入口。

### 3.7 时间戳不变量：Ego 录制各 track 的对齐不受影响

**现状（已核实）**——头显上只有一个采样时基 `godot_ticks_ns`：

| 数据 | 打戳位置 | 域 |
| --- | --- | --- |
| head / controller / hand 姿态（Ego track、OLCP） | `pose_sampler.resolve_pose_timestamp_ns`：优先 OpenXR 预测显示时间（`XrTime`，`CLOCK_MONOTONIC`）+ `getXrTimeToGodotTicksOffsetNs`，否则 Godot ticks | `godot_ticks_ns` |
| RGB（HEVC） | 编码器 `bufferInfo.presentationTimeUs * 1000`，由相机插件把 Camera2 传感器时间戳映射进同一域 | `godot_ticks_ns` |
| 深度 | `depth_timestamp_source_priority: [openxr_runtime_display_time, godot_async_callback_ticks]` | `godot_ticks_ns` |
| 音频 | `AudioCapture`：`System.nanoTime() + clockMonotonicToGodotTicksOffsetNs`，AAC 帧 0 锚在首次麦克风读取 | `godot_ticks_ns` |
| SpatialMP4 `operator_static` | `session_start_unix_us`、`session_start_godot_ticks_us`、`timebase_hz=1e6`、`media_pts_domain="godot_ticks_ns"`、`media_pts_clock="clock_monotonic_ns"` | 契约记录 |
| OLCP `pts_ns` | Kotlin `enqueue(Frame(type, flags, timestampNs, ...))` 原样透传 GDScript 传入的时间戳；`session_start` 含 `session_start_godot_ticks_us` | `godot_ticks_ns` |
| `XrStateFrame.timestamp_ns` / `sample_timestamp_ns` | `xr_tracking_sampler`：`_ticks_usec()*1000`（**采样时刻**，追踪源自带时间戳优先） | `godot_ticks_ns`，但与上一行**不是同一时刻**（差值一帧量级） |

结论：Ego 各 track 之间的对齐依赖的是**所有采样器在同一域打戳**，而不是任何写入器的换算；OLCP 已与之同域同刻，`XrStateFrame` 同域不同刻。因此本方案的时间戳工作只有：

1. 把上表写进 `claw/architecture/wire-protocol.md` 作为唯一时基契约；
2. `pyoperator.live_feed.SessionStartSample` 增加 `session_start_godot_ticks_us` / `session_start_unix_us` 访问器，并提供 OLCP 样本 ⇔ `XrFrame` 的按时间戳对齐 helper（导航例子把相机帧与头位姿对齐要用）；
3. 第 3 步一次设备测量：同一 tick 的 OLCP `head_pose` 与 `XrStateFrame.head.sample_timestamp_ns` 之差的分布——**预期非零**（一帧量级），作为第 6 步统一前的基线；
4. 第 6 步 `XrStateSink` 取代 `xr_tracking_sampler` 后，`XrStateFrame` 的时间戳自动变为 `pose_sampler` 的定义（预测显示时间）。这是 `xr_state` 通道的一次 **wire 语义变化**，写入 `wire-protocol.md`；现有 pyoperator 消费者（light-o1、retargeting）不消费该时间戳，影响为零，但要在第 6 步核对一遍。

**硬规则**：

- 第 0–6 步**不修改** `pose_sampler` / `depth_sampler` / `body_motion_sampler`、编码器、插件、`SessionSpoolWriter` / `LivePushWriter` 的打戳逻辑与 `operator_static` 时基字段。组件抽取只搬代码；`SensorFrame` 携带的时间戳必须原样传递到每个 sink。
- 被合并/删除的是 `xr_state_sender.gd` + `xr_tracking_sampler.gd`，**不是** `pose_sampler.gd`。
- 不引入任何"会话相对"换算；如需相对时间，由消费方用 `session_start_godot_ticks_us` 自行计算。

**回归检查**（两道门）：

- **第一道门（每次 APK 构建，确定性）**：`cicd/xr_module_harness.sh --suite capture.timestamps`——喂固定时间戳的 `SensorFrame` 穿过 source → `StreamBinding` → 每个 sink（含 `XrStateSink`），断言原样到达；`operator_static` 字段集合与语义固定。第 1a 步起生效。
- **第二道门（真机录制对比，第 1b、5、6 步）**：新增 `cicd/10_track_alignment.sh` + `scripts/verify_track_alignment.py`。同一台设备、同一 preset，重构前后各录一段 Ego（含 RGB、深度、头/手柄/手、音频）；`operator_static` 时基字段逐项相同（值可不同）；**同 track 内的确定性映射**（`rgb_frame_index` 传感器时间戳 − RGB 媒体 PTS、`depth_frame_meta` 运行时显示时间 − 深度 PTS、音频 PTS 与锚点）中位数偏移超过 1 ms 即失败；**跨 track**（头位姿与最近 RGB 帧的 |Δt|）比较分布形状，中位数变化超过采样周期的 25% 或需 N≥3 段录制取区间后仍超出即失败；现有 `cicd/02_ego_record.sh` 与 `run_rerun_conversion_check.sh` 通过。

### 3.8 重构后的组件结构

```
xr/scripts/
├─ contracts/                        数据契约，无行为
│   sensor/sensor_frame.gd             SensorFrame —— 时间戳承载体，冻结
│   capture/capture_options.gd
│   teleop/device_descriptor.gd        + capture_streams（手写，与 xr_stream 同套路）
│   streams/streams_status.gd  新      StreamsStatus / StreamsControl 编解码
│
├─ components/                       能力层 —— 今天散在 core/sensors、sinks、addons、capture_app_base 四处
│   sources/  (Node)
│     camera_source.gd    ← capture_app_base 的 389 行插件链 + system permission 等待 + Quest/Pico 差异
│     depth_source.gd     ← core/sensors/depth_sampler.gd (539)
│     audio_source.gd     ← 基类内 AudioCapture 插件绑定
│     pose_source.gd      ← core/sensors/pose_sampler.gd (503) 原样
│     body_source.gd      ← core/sensors/body_motion_sampler.gd (522)
│     hand_source         ← native hand worker（tracking lease 不变）
│   sinks/  (RefCounted，契约 sinks/sink_contract.gd 不变)
│     spatialmp4_sink.gd     现有 (123) + core/capture/session_spool_writer.gd (813)   打戳零改动
│     upload_queue_sink.gd   现有 (63) + ego_uploader.gd (946)
│     live_push_sink.gd      ← live_stream_sink.gd (104) + addons/live-push/live_push_writer.gd；目标由会话注入
│     xr_state_sink.gd   新  ← input/xr_state_sender.gd (201) 的 _frame_v1 编码；取代 xr_tracking_sampler.gd (513)
│     robot_control_sink.gd  现有 (94) + input/command_sender.gd
│   views/  (Node3D)
│     blueprint/             现有 blueprint_runtime.gd (988) 及 robot_model_view / ground_grid / system_menu_host …
│     dense_map_view.gd      ← addons/live-pull/live_pull_dense_map_view.gd，挂 external_view；minimap → 属性
│     path / marker          新原语
│   permissions/  (RefCounted)      host permission；system permission 不在这里
│     permission_table.gd    类别 → 策略；记忆 key (host 地址, 声明 hash)；撤回
│     endpoint_registry.gd   本地已验证的 ingest 端点（QR → ack → Save 的持久化）
│     stream_planner.gd      声明 × 本地上限 × permission × Hello 能力 → 有效 composition + StreamsStatus
│
├─ core/                             不变
│   pipeline/stream_binding.gd         扇出（+ end_of_tick()）
│   capture/capture_session_controller.gd  生命周期（两种会话共用）
│   time/                              时基
├─ platform/                         不变（platform_registry、quest/pico adapter、capture_provider_registry）
│
├─ session/                          会话层
│   host_session.gd     ← teleop_controller 的连接/重连/描述符/ctrl 路由（22%，~720 行）；1:1
│   ingest_session.gd   ← live_feed 的 QR / OLCP 客户端连接；N:1
│
└─ app/
    composition/                     解释器：有效 composition → 实例化组件并连线
      host_composition.gd   ← teleop_composition.gd (37) + capture streams 挂载
      ego_composition.gd    ← ego_capture_composition.gd (95) 吸收 live_feed_composition.gd (41)：sink = local | ingest | both
    modes/
      host_mode.gd    ← teleop_controller.gd 剩余：UI、机器人控制/安全、视频 FPV、追踪   （约 2500 行）
      ego_mode.gd     ← capture_app_base.gd 剩余：UI、QR、指标、play space、自动化        （约 2000 行）
      （live_feed_mode.gd、live_feed_app.tscn 删除）
    launcher/                        两类入口：连接 host / 离线功能
```

**唯一的数据流规则**：`source → StreamBinding → sink`，所有 sink 拿到同一个 `SensorFrame`（时间戳原样）；view 只消费 ctrl（Blueprint / State）与 `media_down`，不接触 `SensorFrame`。声明与权限只进 `StreamPlanner`，`StreamPlanner` 只产出"连哪些"，不碰数据。

**五个场景各是一份 composition**：

| 场景 | 会话 | sources | sinks | views | 权限 |
| --- | --- | --- | --- | --- | --- |
| Teleop（今天） | host | PoseSource、HandSource | XrStateSink、RobotControlSink | Blueprint（robot_model、label、video_panel…） | xr_state 连接即允许 |
| 导航（LightNav） | host | PoseSource、CameraSource（rgb 4 Hz 左眼） | XrStateSink、LivePushSink→host | Blueprint（path、marker、label；dense_map 可选） | 相机一次确认；`StreamsControl` 在信封内调帧率 |
| 导航 + host 编排本地任务 | host | 同上 | + SpatialMp4Sink、UploadQueueSink(endpoint_ref) | 同上 | + 本地指示、可随时停 |
| Ego 本地 | 无 | Camera / Depth / Audio / Pose / Body | SpatialMp4Sink、UploadQueueSink | 无 | 用户 |
| Ego → ingest（原 Live Feed） | ingest | 同上 | LivePushSink→ingest [+ SpatialMp4Sink] | DenseMapView（live-pull 结果） | 用户扫码即授权 |

前三行只换 composition，`host_mode.gd` 不变——这就是"新增场景不重编 APK"落在代码上的形态。

**冻结不动**：`SensorFrame`、`StreamBinding`（只加 `end_of_tick()`）、`CaptureSessionController`、`SessionSpoolWriter`、`LivePushWriter`、`pose_sampler.sample()` / `resolve_pose_timestamp_ns`、`depth_sampler` / `body_motion_sampler` 的打戳、`platform/` 全部、`addons/` 全部、`operator_static` 字段。

**度量门禁**：两个 mode 脚本重构后仍有 2000–2500 行，这是预期内的（UI、安全互锁、FPV、QR、指标都是"本地永远拥有"）。要守住的不是行数，而是 mode 脚本里**不再出现** provider / 插件 / system permission / 推流 / 拉流 / 连接重连代码——用 `grep` 门禁固定。

## 4. 分步实施

每步独立可发布；每步有可度量的验收。设备验证按 CLAUDE.md 只在目标设备上做。

| 步 | 内容 | 验收 | 依赖 |
| --- | --- | --- | --- |
| 0 | 本方案术语与原则写入 `overview.md` / `blueprint.md`（"source"→"host"）；3.7 时基表写入 `wire-protocol.md`；launcher flag **暂不动** | 文档变更，无行为变化 | — |
| 1a | 抽出 `LivePushSink` / `DenseMapView` / `StreamPlanner` / `IngestSession`；`_is_live_feed_mode()` 36 → 0；harness `capture.timestamps` suite 上线；**不碰相机管线** | `cicd/02`、`cicd/04` 通过；第一道门通过；基类减少 ≥ 300 行 | 头显 + CI harness |
| 1b | 抽出 `CameraSource` / `DepthSource` / `AudioSource`（708 行权限/平台/插件），基类与 Ego 组合行为不变 | 基类累计减少 ≥ 900 行；`cicd/02`、`cicd/04` 通过；**第二道门在 Quest 与 Pico 各通过一次** | 1a |
| 2 | Ego 采集 Output 面板 sink 选项（本地 / ingest / 两者）；`operator_feature_mode_live_feed=false`；删除 `live_feed_app.tscn`、`live_feed_mode.gd`、`live_feed_composition.gd`；`mode_live_feed.json` 清单迁移；`cicd/04` 改经 Ego intent | Launcher 无 Live Feed 卡；E2E 经 Ego 入口通过 | 1a |
| 3 | 描述符 `capture_streams`（信封 + `auth_token`，手写三元组）；`Hello.capabilities` 通告 `capture_streams_v1` 与 `stream.*`；`StreamsStatus` + `StreamsControl`（`teleop-protocol`、`BridgeToAdapter`、xr-bridge `pose_server`、pyoperator-native）；从 `teleop_controller` 抽出 `HostSession`；`PermissionTable` + 推流指示 + 撤回 + 记忆；host 组合可挂 `CameraSource` + `LivePushSink`；pyoperator：`BridgeConfig(capture_streams=…)`、`xr.capture.frames()`、`xr.streams_status()`、`xr.streams_control()`、`SessionStartSample` 时基访问器 + 对齐 helper | 一个 host 会话同时拿到 UI、`robot_model` 与 4 Hz 左眼 RGB；ctrl 命令只经 `HostSession` 收发，`teleop_controller` 减少 ≥ 500 行；设备用例覆盖允许 / 拒绝 / 撤回 / 重连不重问 / `required` 被拒不断连 / `StreamsControl` 越界被裁剪；信封上限处量一次帧时间与热；OLCP 与 `XrStateFrame` 姿态时间戳差值基线测量 | 1b |
| 4 | view 原语 `path`、`marker`；`dense_map` external_view 接管 `DenseMapView`（minimap 改属性） | 导航例子的轨迹以 Blueprint state 绘制在地面；`validate_xr_features` 通过 | 3 |
| 5 | `local_tasks`（record / upload）+ `EndpointRegistry` + 指示 | host 可编排"推流同时本地录制并上传到已验证端点"；第二道门再跑一次（record 任务复用 `SpatialMp4Sink`，打戳不变） | 2、3 |
| 6 | host 会话通道统一：`media_up` 用会话自身地址/鉴权，删 `capture_streams.sink`；`XrStateSink` 取代 `xr_state_sender` + `xr_tracking_sampler`（`xr_state` 时间戳语义变化写入 wire-protocol.md）；ingest 会话保留 OLCP | host 会话只开一组端口；`xr_tracking_sampler.gd` 删除；Ego pose track 字节级不变；第二道门通过 | 3、4、5 |

导航例子 `examples/lightnav` 分两阶段：**阶段 A** 不依赖头显改动——用今天的 Live Feed 模式（`LiveFeedReceiver`）做 host 侧客户端、几何、状态机、`--replay`，轨迹先在桌面 / rerun 显示，同时充当第 3 步 API 的真实消费者；**阶段 B** 依赖第 1、3、4 步，把轨迹搬进头显（第 4 步可先只做 `path` / `marker`）。

## 5. 风险与边界

- **设备验证依赖**：第 1b 步触碰 Quest 字节缓冲编码、Pico 零拷贝管线，只能真机回归；拆出 1a 是为了缩小每轮真机验证的爆炸半径。apex 无 Godot，APK 需在有 XR 工具链的机器上构建。
- **时间戳链路是冻结契约**：3.7 的硬规则与两道门是第 1、5、6 步的门禁，不是建议。第 6 步 `xr_state` 时间戳语义变化是唯一有意的例外，须先写文档再改代码。
- **spec hash 锁三端**：每次 Blueprint spec 变更要求 pyoperator、xr-bridge、APK 同一 checkout 发布（现状已如此）。`capture_streams` 先不进 spec 生成。
- **Rust 桥改动**：第 3 步 `capture_streams` / `StreamsStatus` / `StreamsControl` 要改 `teleop-protocol`（含 `BridgeToAdapter`）、xr-bridge、pyoperator-native；第 6 步改动更大。
- **性能与热**：host 场景已在渲染视频 + `robot_model`，再加 HEVC 编码；信封上限由本地限幅兜底，第 3 步验收含实测。声明层绝不承载流；权限层在 ctrl 通道上是低速事件。
- **不做的事**：不把 source/sink 变成 Blueprint 原语；不做通用 DI 框架；不让 host 声明安全互锁、system permission、平台选择、边界策略、校准；不引入第二个时基；不把 ingest 会话并入 host 会话。

## 6. 未决问题

1. **host 身份**：权限记忆目前按 (地址, 声明 hash)；若将来按 host 身份记忆，需要 token/证书方案。今天不做。
2. **第 6 步 host 会话内 `media_up` 的信封**：复用 OLCP 帧格式还是扩展 xr-bridge 帧——第 6 步开始时按当时的 `LivePushWriter` / 桥实现决定，不影响前五步。

（前两轮的其余问题已消解：`streams` 放描述符、手写三元组；`upload.endpoint_ref` 引用 `EndpointRegistry`；`StreamsStatus` / `StreamsControl` 为 ctrl 通道独立命令；时基已同域；组件基类规则按现状固化；Ego server sink 保持 ingest 会话，不走 host 会话。）
