# 云端服务器接入 Live Capture

本文说明云端服务器如何接入 Operator XR 的 Live Capture 通路。当前 XR 端已经拆成两个 addon：

- `live-push`：XR -> server，发送 Quest capture 产生的传感器数据。
- `live-pull`：server -> XR，接收算法结果并在 XR 中渲染，例如 dense map 点云。

服务器实现时应把这两条通路拆成独立连接和独立队列。不要把大体积 dense map 回传塞回 capture 上传连接里。

## 当前通路

默认开发端口：

```text
63910  live-push: XR 连接服务器，上传 capture 数据
63912  live-pull: XR 连接服务器，接收算法结果
```

开发机上运行服务器、Quest 通过 USB 连接时，可以用 `adb reverse` 把 Quest 的 localhost 映射到开发机：

```bash
adb -s <quest-serial> reverse tcp:63910 tcp:63910
adb -s <quest-serial> reverse tcp:63912 tcp:63912
```

如果服务器在局域网或云端，则在 Live Capture 设置里把 server host 改成服务器 IP 或域名，不需要 `adb reverse`。

XR 端启动 Live Capture 后：

1. `QuestCapturePlugin` 采集 RGB、depth、pose、hand、controller input。
2. `live-push` 的 `LivePushPlugin` 连接 `server_host:server_port`，发送 OLCP v1 frame。
3. `live-pull` 的 `LivePullClient` 连接 `server_host:server_result_port`，等待服务器推送结果 frame。

## live-push 入站协议

`live-push` 当前使用 OLCP v1 二进制帧。所有整数都是 big-endian。

```text
magic         4 bytes    "OLCP"
version       1 byte     1
frame_type    1 byte
flags         2 bytes
pts_ns        8 bytes
duration_ns   8 bytes
payload_size  4 bytes
payload       N bytes
```

Python 中可按这个结构解析：

```python
FRAME_HEADER = struct.Struct(">4sBBHQQI")
magic, version, frame_type, flags, pts_ns, duration_ns, size = FRAME_HEADER.unpack(header)
```

入站 frame type：

| Type | 名称 | Payload |
| --- | --- | --- |
| 1 | `session_start` | JSON |
| 2 | `rgb_csd` | JSON，包含 HEVC codec config 的 base64 |
| 3 | `rgb_packet` | HEVC bytes |
| 4 | `depth_metadata` | JSON |
| 5 | `depth_frame` | raw depth bytes，或 composite JSON + u16 depth |
| 6 | `head_pose` | JSON |
| 7 | `controller_pose` | JSON |
| 8 | `hand_joints` | JSON |
| 9 | `controller_input` | JSON |
| 10 | `session_end` | JSON |

`rgb_csd` 描述后续 RGB packet 的 codec 和 packetization。当前 Quest live-push
发送 HEVC Annex-B elementary stream；每个 `rgb_packet` payload 是一个完整
MediaCodec 输出 access unit，keyframe 会设置 `flags & 1`。

```json
{
  "width": 1920,
  "height": 1080,
  "fps": 30,
  "codec": "hevc",
  "bitstream_format": "hevc_annexb",
  "packet_format": "access_unit",
  "stereo_layout": "side_by_side",
  "camera_count": 2,
  "cameras": [],
  "csd_base64": "..."
}
```

flags：

| Flag | 含义 |
| --- | --- |
| `1` | keyframe |
| `2` | composite payload: `u32 json_size + json + binary` |

`session_start` 会包含基础 session 信息，例如：

```json
{
  "protocol": "operator.live_capture.v1",
  "stream_name": "session_...",
  "auth_token": "",
  "contract_version": 1,
  "session_start_unix_us": 123456789,
  "rgb_width": 1920,
  "rgb_height": 1080,
  "rgb_fps": 30,
  "rgb_camera_count": 2,
  "depth_expected": true,
  "head_pose_expected": true,
  "controller_pose_expected": true,
  "hand_joints_expected": true,
  "controller_input_expected": true,
  "rgb_icam_base64": "...",
  "rgb_ecam_base64": "...",
  "rgb_dstr_base64": "..."
}
```

服务器应至少实现：

1. 校验 `magic == b"OLCP"` 和 `version == 1`。
2. 读取完整 payload 后再分发。
3. 非 droppable 数据写入可靠存储，例如 `session_start`、`rgb_csd`、`session_end`。
4. 高频数据进入 bounded queue，例如 RGB packet、pose、depth。
5. 队列满时丢旧帧，不阻塞 socket reader。

推荐队列：

```text
session       session_start/session_end
rgb_csd       HEVC codec config
rgb_packet    HEVC packets
depth         depth_metadata/depth_frame
head_pose     head pose samples
controller    controller pose/input
hands         hand joints
```

## live-push 最小接收骨架

```python
import json
import socket
import struct

MAGIC = b"OLCP"
VERSION = 1
HEADER = struct.Struct(">4sBBHQQI")

def read_exact(conn, size):
    chunks = []
    remaining = size
    while remaining:
        chunk = conn.recv(remaining)
        if not chunk:
            raise EOFError("connection closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)

def read_frame(conn):
    header = read_exact(conn, HEADER.size)
    magic, version, frame_type, flags, pts_ns, duration_ns, payload_size = HEADER.unpack(header)
    if magic != MAGIC or version != VERSION:
        raise ValueError("unsupported OLCP frame")
    payload = read_exact(conn, payload_size)
    return frame_type, flags, pts_ns, duration_ns, payload

def serve_push(host="0.0.0.0", port=63910):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(1)
        conn, peer = server.accept()
        with conn:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            while True:
                frame_type, flags, pts_ns, duration_ns, payload = read_frame(conn)
                if frame_type == 1:
                    session = json.loads(payload.decode("utf-8"))
                    print("session_start", session.get("stream_name"))
                elif frame_type == 3:
                    handle_rgb_packet(payload, pts_ns, flags)
                elif frame_type == 10:
                    break
```

真实服务不要在 socket reader 线程里跑算法。reader 只负责解析、落盘、入队；算法 worker 从队列取数据。

## composite payload

当 `flags & 2 != 0` 时，payload 格式是：

```text
json_size   4 bytes big-endian
json        json_size bytes, UTF-8
binary      remaining bytes
```

depth frame 和 dense map fragment 都使用这个格式。

```python
def parse_composite(payload):
    (json_size,) = struct.unpack(">I", payload[:4])
    json_end = 4 + json_size
    metadata = json.loads(payload[4:json_end].decode("utf-8"))
    binary = payload[json_end:]
    return metadata, binary
```

## live-pull 结果回传协议

服务器需要监听 result port，等待 XR 的 `LivePullClient` 连接：

```python
def serve_pull(host="0.0.0.0", port=63912):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(1)
        conn, peer = server.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return conn
```

回传也使用同一个 OLCP header。当前 `live-pull` 支持的 server -> XR frame type：

| Type | 名称 | Payload |
| --- | --- | --- |
| 110 | `algorithm_status` | JSON |
| 111 | `map_reset` | JSON |
| 112 | `dense_map_manifest` | JSON |
| 113 | `dense_map_fragment` | composite JSON + binary |
| 114 | `dense_map_commit` | JSON |
| 115 | `camera_trajectory` | JSON |
| 116 | `map_transform` | JSON |

发送 JSON result：

```python
def pack_frame(frame_type, flags, pts_ns, duration_ns, payload):
    return HEADER.pack(MAGIC, VERSION, frame_type, flags, pts_ns, duration_ns, len(payload)) + payload

def send_json(conn, frame_type, value, pts_ns=0):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    conn.sendall(pack_frame(frame_type, 0, pts_ns, 0, payload))
```

示例 status：

```python
send_json(result_conn, 110, {
    "schema": "operator.algorithm_status.v1",
    "algorithm": "vggt_slam2",
    "state": "running",
    "message": "worker started"
})
```

## Dense map 回传

Dense map 可能很大。按 28 MiB/submap 估算，服务器必须切 chunk 和 fragment：

1. 发送 `dense_map_manifest`，描述 map version、chunk、编码和 fragment 数。
2. 发送多个 `dense_map_fragment`，每个 fragment 是 composite payload。
3. 发送 `dense_map_commit`，XR 只渲染 commit 中列出的完整 chunk。

manifest 示例：

```json
{
  "schema": "operator.dense_map_manifest.v1",
  "map_id": "session_001",
  "map_version": 42,
  "submap_id": 7,
  "chunks": [
    {
      "chunk_id": "submap_0007_chunk_0000",
      "operation": "upsert",
      "encoding": "f32xyz_u8rgba_f32conf",
      "point_stride_bytes": 20,
      "point_count": 100000,
      "fragment_count": 8,
      "coordinate_frame": "map"
    }
  ],
  "T_openxr_map": [
    [1, 0, 0, 0],
    [0, 1, 0, 0],
    [0, 0, 1, 0],
    [0, 0, 0, 1]
  ]
}
```

fragment metadata 示例：

```json
{
  "schema": "operator.dense_map_fragment.v1",
  "map_id": "session_001",
  "map_version": 42,
  "submap_id": 7,
  "chunk_id": "submap_0007_chunk_0000",
  "operation": "upsert",
  "encoding": "f32xyz_u8rgba_f32conf",
  "point_stride_bytes": 20,
  "point_count": 100000,
  "fragment_index": 0,
  "fragment_count": 8,
  "T_openxr_map": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
}
```

fragment payload 打包：

```python
def pack_composite(metadata, binary):
    meta = json.dumps(metadata, separators=(",", ":")).encode("utf-8")
    return struct.pack(">I", len(meta)) + meta + binary

payload = pack_composite(fragment_metadata, binary_fragment)
result_conn.sendall(pack_frame(113, 2, pts_ns, 0, payload))
```

commit 示例：

```json
{
  "schema": "operator.dense_map_commit.v1",
  "map_id": "session_001",
  "map_version": 42,
  "committed_chunks": ["submap_0007_chunk_0000"],
  "replace_versions_before": 41
}
```

XR 的 `LivePullClient` 会按 `chunk_id` 组装 fragment。只有收到 `dense_map_commit` 后，`LivePullDenseMapView` 才会渲染对应 chunk。

当前 XR renderer 支持：

```text
f32xyz_u8rgba_f32conf
quantized_u16xyz_rgba8_conf8
```

`quantized_u16xyz_rgba8_conf8_zstd` 会被识别但不会在 GDScript 中解压。生产环境如果要发 zstd，应该把解压放到 native addon 或 Android plugin。

## VGGT-SLAM2 接入方式

以 VGGT-SLAM2 类算法为例，服务器侧建议按如下边界设计：

1. `rgb_csd` 初始化 HEVC decoder。
2. `rgb_packet` 解码成图像帧，并以 `pts_ns` 作为主时间轴。
3. `head_pose` 按 `pts_ns` 插值或取最近邻，作为 keyframe gating、初始位姿或可视化辅助。
4. `depth_frame` 可选，用于尺度检查、稠密约束或 debug。
5. keyframe selector 产生稳定 `frame_id`。
6. worker 以 `submap_size + overlap` 的 keyframe window 调用算法。
7. worker 输出 submap points、camera trajectory、map transform。
8. result publisher 将输出转成 `dense_map_manifest`、`dense_map_fragment`、`dense_map_commit`。

算法 worker 不应直接读 socket，也不应直接写 XR socket。推荐拆成：

```text
push reader -> durable log -> bounded queues -> algorithm worker -> result queue -> pull publisher
```

这样可以独立处理：

- capture 入站突发。
- 算法处理延迟。
- dense map 大包回传。
- XR result channel 断开重连。

## 能力协商和数据需求

目标协议中，服务器应先声明算法需求，再由 XR 确认是否支持。当前 XR APK 的 live-push 已经能根据 UI 配置发送子集数据，但完整 OLCP v2 capability handshake 还没有落地。

服务器代码现在就应该保留这个结构：

```json
{
  "algorithm": "vggt_slam2",
  "required_streams": ["rgb.hevc"],
  "optional_streams": ["head_pose.json", "depth.u16"],
  "result_streams": [
    "status.json",
    "dense_map.point_cloud_delta",
    "camera_trajectory.json",
    "map_transform.json"
  ],
  "limits": {
    "rgb_max_hz": 15,
    "head_pose_max_hz": 30,
    "submap_size": 16,
    "overlap": 1
  }
}
```

当前兼容模式下，服务器使用 Quest 静态 capability profile 做校验；未来 XR 发送 `client_capabilities` 后，服务器改为用实际 capability 校验。

## 运行顺序

生产服务器应同时启动 push listener 和 pull listener：

```bash
# 示例命令；具体入口由你的服务器实现决定。
python your_live_capture_server.py \
  --host 0.0.0.0 \
  --push-port 63910 \
  --pull-port 63912 \
  --algorithm vggt_slam2 \
  --out live_capture_out
```

如果只想先验证 OLCP v1 入站解析，可以运行当前 prototype：

```bash
python examples/live-capture-vggt-slam2/operator_live_capture_server.py \
  --host 127.0.0.1 \
  --port 63910 \
  --out live_capture_out \
  --algorithm vggt_slam2
```

Quest 通过 USB 连接开发机时，映射两个端口：

```bash
adb -s <quest-serial> reverse tcp:63910 tcp:63910
adb -s <quest-serial> reverse tcp:63912 tcp:63912
```

在 XR 里进入 Live Capture 后，设置：

```text
server host: 127.0.0.1
server port: 63910
result port: 63912
```

注意：`examples/live-capture-vggt-slam2/operator_live_capture_server.py` 是 prototype。它展示 OLCP v1 parse、queue、mock worker 和 result packing，但 result frame type 仍可能落后于当前 `live-pull`。新的服务器实现应以本文和 `xr/addons/live-pull/live_pull_client.gd` 中的 110-116 result type 为准。

## 接入检查清单

- push reader 和 pull publisher 使用不同 socket。
- push reader 不跑算法，只 parse、落盘、入队。
- RGB CSD 必须在 RGB packet 前进入 decoder。
- 所有队列有上限，高频流可丢旧帧。
- 以 `pts_ns` 对齐 RGB、pose、depth。
- dense map 按 `map_version`、`chunk_id`、`fragment_index` 管理。
- 28 MiB 级 submap 必须拆 fragment，不发送单个超大 OLCP payload。
- 发送 commit 前确认同一 TCP result 连接上已经写出完整 chunk 的所有 fragment。
- `zstd` dense payload 需要 XR native/plugin 解码支持；当前 GDScript renderer 不解压。
- 服务器要能处理 result client 尚未连接、断开或慢速消费。

## 相关代码

- `xr/addons/live-push/live_push_writer.gd`
- `xr/android_plugin/live_capture_server/src/main/java/com/spatialmp4/livecapture/LiveCaptureServerPlugin.kt`
- `xr/addons/live-pull/live_pull_client.gd`
- `xr/addons/live-pull/live_pull_dense_map_view.gd`
- `examples/live-capture-vggt-slam2/operator_live_capture_server.py`
- `claw/rfcs/002-live-capture-cloud-vggt-slam2.md`
