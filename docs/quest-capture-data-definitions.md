# Quest 数采定义对照

本文精简对照 Operator 与 [`atongbuxiang/hand_tracking_with_video_streamer`](https://github.com/atongbuxiang/hand_tracking_with_video_streamer)（检查版本 `15037ebe1f28ce7302ab4d2ca6807c20e080f207`）的 Quest RGB、头/手 pose 与时间同步定义。

## 结论表

| 定义 | Operator | hand_tracking_with_video_streamer（HTVS） |
| --- | --- | --- |
| RGB 来源 | Android Camera2 passthrough，相机 `Image.timestamp` | Meta MRUK/PCA `PassthroughCameraAccess` texture；帧时间是 CPU readback/JPEG 时取的 `Stopwatch` 时间，不是 PCA `Timestamp` |
| Head pose | Godot `XRCamera3D.global_transform`，即 OpenXR HMD/头部 tracking pose | Unity `CenterEyeAnchor`（缺失时 `Camera.main.transform`）的 world pose |
| RGB optical pose | 不直接计算；只保存 Camera2 `LENS_POSE_TRANSLATION/ROTATION` 标定 | 优先使用 PCA `GetCameraPose()` 的逐帧 world pose；否则用 `head pose × LensOffset` 计算 |
| World origin | 当前 OpenXR session reference space；代码未锁定或记录 `stage/local-floor/local` | Scene 的 OVR tracking origin 序列化为 `1`，对应 OVR `FloorLevel`；允许 recenter。数据仍是 session-local Unity world，不是跨 session 固定地图坐标 |
| 坐标约定 | Godot 右手系，`+Y` 上、相机前方 `-Z`，四元数 `xyzw`，米 | Unity 左手系，`+Y` 上、`+Z` 前，四元数 `xyzw`，米。仓库文档提出转右手系时翻转 Y；消费者应固定一种显式变换并同步变换位置和旋转 |
| Pose 频率 | 目标 90 Hz；head MP4 每次采样，controller/hand 约 30 Hz | Scene 中 head 为 100 Hz（`frequencySeconds=0.01`）；hand 目标 100 Hz，实际由 `WhenHandUpdated` 驱动和限频 |
| 时间域 | RGB、OpenXR pose/depth 转到共同的 `godot_ticks_ns`/monotonic 域 | RGB、head、hand 都在产生/发送数据时调用同一 `Stopwatch.GetTimestamp()` monotonic clock |
| 帧对齐 | 采集端不生成 `aligned_frames`；MP4 各 track 保留独立 PTS | 每个 camera frame 对每条 telemetry 流做全缓冲区绝对时间差最近邻；不插值 |
| 最大对齐误差 | 无采集端阈值 | **无阈值**；只记录有符号 `*_dt_ms = telemetry_ts - camera_ts` |
| Tracking 丢失 | controller 无效时不写；hand 无效时跳过；head 当前硬编码有效 | hand `IsTrackedDataValid=false` 时不产出 wrist/landmarks；head 没有显式 validity 字段 |
| 缺失处理 | 各 MP4 track 可自然出现时间空洞 | 缓冲为空时字段为 null/0；缓冲非空时可能无限期复用旧的最近样本，因此必须用 `*_dt_ms` 在下游过滤 |

## Operator

Operator 的 head pose 是 `XRCamera3D.global_transform`，不是 RGB 光学中心。`XROrigin3D` 以单位变换创建，OpenXR 初始化前没有设置 requested reference-space 类型，所以这里只能称为“当前 session 的 OpenXR tracking space”，不能声称一定是 stage 或 floor。

RGB 使用 Camera2 `Image.timestamp`。Quest 默认的 `SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN` 按 `CLOCK_MONOTONIC` 处理；REALTIME 来源按 `CLOCK_BOOTTIME` 处理。OpenXR predicted display `XrTime` 与相机时间都转换为 Godot ticks 域后写入 MP4 独立 tracks。这里是统一时钟，不是采集时逐帧配对；下游仍需按 PTS 对齐。

RGB 标定保存了 lens translation/rotation，但当前 writer 没有输出明确的 `T_world_rgb = T_world_head × T_head_rgb` 字段，也没有把实际 reference-space 类型写入 manifest。

Tracking 丢失时 controller/hand 会停止写入，因此对应 track 出现空洞。Head 调用则把 `tracking_valid` 固定为 `true`，不能表达头部 tracking loss。

主要证据：

- `xr/scripts/capture_app.gd`：OpenXR 初始化、XROrigin 创建、90 Hz pose loop。
- `xr/scripts/pose_sampler.gd`：head/controller/hand pose 来源与 OpenXR 时间转换。
- `xr/scripts/session_spool_writer.gd`：pose 字段、MP4 mett 写入与 manifest 时间域。
- `xr/android_plugin/questcapture/.../QuestCapturePlugin.kt`：Camera2 时间戳、clock anchors 与 lens pose metadata。

## HTVS

HTVS 的 `telemetry_raw` 包含独立的 `head:pose`、左右 `wrist` 和 `landmarks` 样本。Head 使用 `CenterEyeAnchor` 的 Unity world position/rotation；hand wrist 使用 `IHand.GetRootPose()`；21 个 landmark 来自 `GetJointPosesFromWrist()`，所以原始 landmark 是 wrist-local，再通过

```text
p_world = p_wrist + R_wrist · p_local
```

生成 `*_landmarks_world`。

相机使用左眼 PCA texture。每个已编码帧有 frame ID 和 `Stopwatch` monotonic 时间。若 PCA 支持 `GetCameraPose()`，`aligned_frames.camera_*_world` 使用该逐帧 pose；否则使用：

```text
T_world_camera = T_world_head × T_head_lens
```

其中 `T_head_lens` 来自 PCA `Intrinsics.LensOffset`，缺失时 position fallback 为 `[-0.032, 0, 0.015]` m、rotation 为单位四元数。

`telemetry_raw → aligned_frames` 的具体算法是：

```text
for each camera frame at t_camera:
    for head, left/right wrist, left/right landmarks:
        sample = argmin(abs(t_sample - t_camera)) over retained samples
        dt_ms = (t_sample - t_camera) / 1e6
```

每流只保留最近 512 个样本。算法没有最大误差、没有插值、也不要求样本与相机 frame ID 相同。若 tracking 丢失导致某流停止更新，最近邻会继续选中旧样本；因此 `aligned_frames` 中“字段非空”不等于“此帧 tracking 有效”。训练或转换前必须对各 `*_dt_ms` 设定业务阈值，超阈值置 null 或丢帧。

另一个时间语义限制是：代码虽然读取 PCA `Timestamp`，但实际传输帧的 `timestamp_ns` 在 texture CPU readback/JPEG 编码时重新取 `Stopwatch`；`GetCameraPose()` 也使用这个时间标签。因此它更接近采集处理时刻，而不是严格的曝光中心时间。

主要证据：

- `Assets/Scripts/QuestCameraCapture.cs`：PCA texture、intrinsics、LensOffset、GetCameraPose 与帧时间。
- `Assets/Scripts/HeadPoseStreamer.cs`：CenterEyeAnchor world pose。
- `Assets/Scripts/HandLandmarkStreamer.cs`：tracking validity、wrist pose 和 wrist-local landmarks。
- `Assets/Scripts/QuestLocalDatasetRecorder.cs`：512 样本缓冲、最近邻对齐、camera optical pose 与 null/旧值行为。
- `Assets/Scripts/QuestStreamClock.cs`：统一 Stopwatch monotonic clock。
- `scripts/record_quest_dataset.py`：PC 录制路径使用相同的最近邻且同样没有误差阈值。

## 建议统一的数据契约

两个采集端接入 EgoQuest 前，至少显式保存：

1. `pose_frame`：例如 `openxr_local_floor`，并记录是否/何时 recenter。
2. `axis_convention`、单位和 quaternion 顺序。
3. `pose_node`：`head_center` 或 `rgb_left_optical_center`，以及有方向定义的外参 `T_head_rgb_left`。
4. `timestamp_clock` 与时间语义：sensor exposure、predicted display 或 CPU sample/readback。
5. 每次对齐的 `dt_ms`、最大允许误差和 tracking-valid 字段；超阈值必须显式置 null，不能静默复用旧 pose。
