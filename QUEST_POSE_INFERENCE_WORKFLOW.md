# Quest Pose Inference 运行流程

本文档记录在远端服务器上运行 Operator Quest pose 采集、Matplotlib 3D
可视化和 20 Hz 图片回传的完整流程。

## 固定环境

- 服务器：`10.10.99.72`
- 用户：`evophys`
- 工作目录：`/home/evophys/code/operator`
- Quest 二维码页面：<http://10.10.99.72:63920/>
- WebSocket：`ws://10.10.99.72:63920/pose-inference`
- Python 环境：`server/.venv`
- systemd 服务：`pose-inference.service`

所有环境配置、构建、测试和验证都在远端服务器执行。

## 1. 安装或更新 Python 依赖

在仓库根目录执行：

```bash
cd /home/evophys/code/operator
uv pip install   --python server/.venv/bin/python   -r server/requirements-pose-inference.txt
```

验证 Matplotlib 使用无界面 Agg 后端：

```bash
server/.venv/bin/python -c   'import matplotlib; print(matplotlib.__version__, matplotlib.get_backend())'
```

## 2. 启动 pose inference 服务

推荐使用已经配置好的 systemd 服务：

```bash
cd /home/evophys/code/operator
sudo systemctl restart pose-inference.service
systemctl status pose-inference.service --no-pager
sudo journalctl -u pose-inference.service -f -o cat
```

最后一条命令会持续显示实时日志，按 `Ctrl+C` 只会退出日志查看，不会停止
服务。

服务启动后，在同一局域网中的浏览器打开：

<http://10.10.99.72:63920/>

在 Quest 的 Pose Inference 配置页面扫描该网页中的二维码。

如果要绕过 systemd 进行前台调试：

```bash
cd /home/evophys/code/operator
server/.venv/bin/python server/pose_inference_ws.py   --host 0.0.0.0   --public-host 10.10.99.72   --port 63920
```

前台模式按 `Ctrl+C` 会直接停止服务。

## 3. 构建、安装并启动 Quest 客户端

另开一个远端终端执行：

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME="$HOME/.local/share/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK="$ANDROID_HOME/ndk/28.1.13356709"
export PATH="$HOME/.local/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

cd /home/evophys/code/operator/xr
adb devices
make ship-quest MODE=pose_inference
```

`adb devices` 必须只显示一台状态为 `device` 的 Quest。首次完整构建可能超过
10 分钟；后续构建会复用缓存。

仓库根目录的 `run_quest_pose_inference.sh` 也保存了这两个终端所需的命令，
它是命令清单，不应从头到尾作为单个脚本运行。

## 4. 数据与图像行为

Quest pose 接收路径不设置频率上限。服务端始终用最新 pose 覆盖旧 pose，不建立
等待队列，因此高频输入不会逐渐增加延迟。

返回 Quest 的图片循环目标为 20 Hz，即每 50 ms 选择当时最新的一帧 pose：

- 输出：960×540 JPEG。
- 绿色：head 位置与 head forward 方向。
- 青色：左手 26 个 OpenXR joints 和 bones。
- 橙色：右手 26 个 OpenXR joints 和 bones。
- 坐标映射：XR `[x, y, z]` → 图中 `[x, -z, y]`。
- 未跟踪或格式错误的 joint 会被跳过，不会停止整条图片流。
- Matplotlib 使用持久化 3D 对象和 Agg 背景增量重绘。
- 渲染在线程中执行，不阻塞 WebSocket 接收 Quest pose。

一帧完整 JSON 样本保存在：

```text
server/samples/quest_pose_frame_000001.json
```

## 5. 观察终端日志

每次 Quest 建立连接后，服务只打印一份完整紧凑样本：

```text
POSE_SAMPLE {"capture_time_ns":...,"frame_id":...,"head":...,"left":...,"right":...}
```

之后每秒打印一行统计：

```text
POSE_STATS pose_rx_fps=... image_tx_fps=... head_tracked_fps=... left_hand_tracked_fps=... right_hand_tracked_fps=... pose_to_image_avg_ms=... pose_to_image_max_ms=...
```

主要字段：

- `pose_rx_fps`：服务端每秒收到的 Quest pose 数，不限频。
- `image_tx_fps`：每秒返回 Quest 的图片数，目标约 20。
- `head_tracked_fps`：head 有效跟踪帧率。
- `left_hand_tracked_fps` / `right_hand_tracked_fps`：左右手有效跟踪帧率。
- `pose_to_image_avg_ms`：从 pose 到对应图片发送的平均服务端延迟。
- `pose_to_image_max_ms`：该统计窗口内的最大服务端延迟。
- `latest_pose_frame_id`：最近处理的 Quest pose frame ID。

## 6. 测试和性能验证

运行完整 Python 测试与语法检查：

```bash
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest discover -s server/tests -v
server/.venv/bin/python -m compileall -q server
```

运行 Matplotlib 渲染性能基准：

```bash
cd /home/evophys/code/operator
server/.venv/bin/python - <<'PY'
import json
import time
from pathlib import Path
from server.pose_inference_ws import MatplotlibPoseRenderer

pose = json.loads(
    Path("server/samples/quest_pose_frame_000001.json").read_text()
)
renderer = MatplotlibPoseRenderer()
renderer.render(pose, 0)

count = 100
start = time.perf_counter()
for sequence in range(1, count + 1):
    renderer.render(pose, sequence)
elapsed = time.perf_counter() - start

print(
    f"render_fps={count / elapsed:.2f} "
    f"average_ms={elapsed * 1000 / count:.2f}"
)
PY
```

2026-07-22 在该服务器上的参考结果为约 `197.22 FPS`、`5.07 ms/帧`。
这是纯渲染能力；实际网络图片发送仍由协议限制在目标 20 Hz。

## 7. 停止服务

如果服务通过 systemd 启动，使用：

```bash
sudo systemctl stop pose-inference.service
systemctl is-active pose-inference.service
ss -ltnp | grep ':63920' || true
pgrep -af '[p]ose_inference_ws.py' || true
```

正确停止后的 `systemctl is-active` 输出为 `inactive`，后两条命令不应显示
监听端口或 pose inference 进程。

如果是前台手动启动，优先回到对应终端按 `Ctrl+C`。若终端已经丢失，先运行：

```bash
pgrep -af '[p]ose_inference_ws.py'
```

确认命令行和 PID 确实属于
`/home/evophys/code/operator/server/pose_inference_ws.py` 后，再执行
`kill <确认过的PID>`。不要对未经核对的 Python 进程使用宽泛的
`pkill python`。

## 8. 常见检查

二维码页面不可访问：

```bash
systemctl status pose-inference.service --no-pager
curl -I http://127.0.0.1:63920/
ss -ltnp | grep ':63920' || true
```

Quest 未被 ADB 识别：

```bash
which -a adb
adb version
adb kill-server
adb start-server
adb devices
```

只使用 `$HOME/.local/share/android-sdk/platform-tools/adb` 这一套 ADB，避免
不同版本的 ADB server/client 相互抢占端口。

有 pose 但没有图片时：

```bash
sudo journalctl -u pose-inference.service -n 200 -o cat
```

重点检查 Matplotlib/Pillow 导入错误、JPEG 渲染异常，以及
`image_tx_fps` 是否为零。
