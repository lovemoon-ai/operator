# Quest memWorld 实时 Demo

这个模式使用 Quest 的实时 head/hands Pose 驱动 MemWorld。QuestCapturePlugin
只查询左侧透视相机的 Camera2 标定，不启动 YUV/RGB 采集。二维码扫描功能仍然保留。

## 数据链路

1. Quest 不限速发送 Pose 到 Operator 的 `/memworld` WebSocket。
2. Operator 用实际 Camera2 内参和 lens extrinsics 投影手部。
3. 投影图按宽度 640 等比缩放，从顶部裁剪，保留下方 640×352。
4. Operator 固定以 20 Hz 投影骨架，供模型输入和电脑 Dashboard 调试。
5. Operator 只维护一个固定 17 帧的最近窗口。首轮收满 17 帧后推理；此后每有
   16 个新采样且模型空闲时，直接读取当下最新 17 帧。模型偶发落后时不积压旧
   window，下一轮追到最新动作，并在 Dashboard 记录跳过的采样数。
6. 本地 WebSocket worker 仍可返回 17 帧 JPEG ZIP；NV stream worker 返回16帧
   H.264 chunk，Operator 在工作站解码为高质量 JPEG。两种后端最终都以20 Hz
   同时发往浏览器和 Quest。

## 启动

本地GPU模式下，终端一启动 MemWorld GPU worker：

```bash
cd /home/evophys/code/operator
bash ./run_memworld_direct_dmd1000_worker.sh
```

终端二启动 Operator 网关：

```bash
cd /home/evophys/code/operator
./run_quest_memworld.sh 10.10.99.72
```

这里的 `10.10.99.72` 是当前服务器 IP；网络变化后把参数换成实际地址即可。

浏览器打开：

```text
http://10.10.99.72:63921/
```

页面会显示 Quest 连接二维码、骨架预览、20 Hz模型图片序列、Pose/预览频率、
投影延迟、chunk 队列状态、推理耗时和 JPEG ZIP 传输/解包耗时。

NV模式不启动工作站本地GPU worker。先确认NV模型服务已经监听其loopback
`18768`，然后在工作站终端一建立隧道：

```bash
cd /home/evophys/code/operator
MEMWORLD_LOCAL_WORKER_PORT=18768 \
MEMWORLD_NV_WORKER_PORT=18768 \
bash ./run_memworld_nv_tunnel.sh
```

工作站终端二指定本地初始化图并启动原Operator网关：

```bash
cd /home/evophys/code/operator
export MEMWORLD_INITIAL_RGB=/绝对路径/initial_rgb.png
bash ./run_quest_memworld_nv.sh 10.10.99.72
```

NV模式的checkpoint、模型类型、NFE和CFG由NV服务端启动配置决定；工作站
客户端不固定或校验某个Direct-DMD checkpoint。

终端三，构建并启动 Quest：

```bash
cd /home/evophys/code/operator/xr
make ship-quest MODE=memWorld
```

Quest 进入 `memWorld` 后扫描仪表盘上的二维码即可。第一批模型结果完成前保持
黑屏；之后以20 Hz显示生成 JPEG。手部骨架图不再传回 Quest。

`bash ./run_memworld_direct_dmd1000_worker.sh` 会在模型加载后、监听 8765 端口前自动执行 2 次
完整 warmup。warmup 使用同样的 17 帧、640×352、4 steps 和 CFG 1.0，并使用
独立的临时 session；结果会被丢弃，不会推进真实推理的 anchor、history 或 chunk
序号。两次 warmup 成功后才打印 `listening`；任一次失败都会让脚本直接退出。
首次 Quest 连接不会重复 warmup，`session.ready` 会返回启动阶段记录的每次及总耗时。
本次用旧 `egoquest-step100000` checkpoint 实测为 5295.7 ms 和 1802.0 ms，总计 7097.7 ms，均发生在 `listening` 之前。

## 可调参数

- Pose 发送：无应用层上限，通常接收约 90 Hz。
- 时序 profile：17 帧 = 1 anchor + 16 个预测 RGB 帧 = 4 个 latent slot。
- Quest 生成图播放：20 Hz；首批结果前保持黑屏。
- 模型采样：从最新 Pose 严格采样20 Hz。
- Chunk：固定最近17帧；正常稳态下相邻推理窗口新增16帧，覆盖0.8秒。
- 模型图片播放：20 Hz；每个NV结果的16张新图覆盖0.8秒。
- 模型步数：网关参数 `--num-inference-steps`，默认 4（极速档）。
- CFG：网关参数 `--cfg-scale`，默认 1.0，不执行负向分支。
- 网关端口：`MEMWORLD_GATEWAY_PORT`，默认 63920。
- 仪表盘端口：`MEMWORLD_DASHBOARD_PORT`，默认 63921。
- Worker 地址：`MEMWORLD_WORKER_URL`，默认 `ws://127.0.0.1:8765`。
- NV Worker 地址：`tcp://127.0.0.1:18768`，由
  `run_quest_memworld_nv.sh`自动设置。
- 步数环境变量：`MEMWORLD_NUM_INFERENCE_STEPS`，bash 默认 4。
- CFG 环境变量：`MEMWORLD_CFG_SCALE`，bash 默认 1.0。
- Warmup 次数：`MEMWORLD_WARMUP_RUNS`，bash 默认 2。
- Warmup 输入图：`MEMWORLD_INITIAL_RGB`；static memory 可用 `MEMWORLD_STATIC_MEMORY` 覆盖。

模型忙时不会排队旧窗口：固定17帧环形窗口持续更新，当前推理结束后只取当下
最新窗口。`skipped_samples`记录为追上实时动作而跳过的旧采样。

## 推理速度口径

- 输入时长：`16 个采样间隔 / 20 Hz = 0.8 秒`。
- 严格生成 FPS：`16 个新生成 RGB 帧 / 单个 chunk 推理耗时`。
- 实时倍率：`单个 chunk 推理耗时 / 0.8`，数值越小越好。
- 每分钟 chunk 数：`60 / 单个 chunk 推理耗时`。

测速不包含首次模型加载与 static-memory 初始化时间。

## 2026-07-22 优化后实测

以下结果使用当时的 24 Hz 输入与 7 fps 播放配置，仅保留作为历史性能基线。

当前极速档使用 PyTorch 原生 SDPA、5 inference steps、CFG 1.0。固定 prompt
只在 worker 冷启动时用 UMT5-XXL 编码一次，之后卸载整个 text encoder；live
pipeline 中 `text_encoder is None`，只保留 4.0 MiB 的正向 prompt embedding。

档位矩阵采用一次 warm-up 后连续测试 3 个 33 帧 chunk；极速档中位结果：

- 中位耗时：4.6591 秒/chunk。
- DiT 中位耗时：1.5498 秒。
- 生成吞吐：7.0828 帧/秒。
- 输入实时倍率：3.388×。
- 峰值 CUDA allocated memory：约 13.87 GiB。
- 三个输出都为 33 帧、640×352，且数值有效。

同机原生 SDPA 的 10 steps/CFG 1.0 中位耗时为 6.2588 秒；极速档再缩短约
25.6%。相对旧的 20 steps、22.59 秒结果，极速档缩短约 79.4%。

`flash-attn 2.8.3.post1` 已在 RTX 4090 上从源码编译并通过 BF16 冒烟测试。
其 DiT 中位耗时为 3.1046 秒，而原生 SDPA 基线为 3.1234 秒，只快约
0.60%，未达到 5% 保留阈值，因此已经卸载，最终使用原生 SDPA。

7 fps 下一个 33 帧视频播放约 4.714 秒，而 worker 中位生成耗时约 4.659 秒，
理论余量约 55 ms，因此生成与播放速度基本对齐。模型仍慢于 24 Hz 输入的实时
采样速度；网关会继续只保留最新 pending chunk，不积压旧输入窗口。

## 2026-07-22 实测结果

以下结果同样是旧的 24 Hz 输入基线。

环境：

- GPU：NVIDIA GeForce RTX 4090 24 GB。
- Checkpoint：`egoquest-step100000/dit_step100000.safetensors`。
- 输入：640×352、24 Hz、33 帧，即每个 chunk 1.375 秒。
- 推理配置：默认 20 inference steps，固定 seed 0。
- 测试方式：模型加载完成后，在同一持久 session 内连续推理 3 个 chunk。

结果：

- 三次模型耗时：22.5138、22.5957、22.6606 秒。
- 平均耗时：22.5900 秒/chunk。
- 最小/最大：22.5138/22.6606 秒。
- 总体标准差：0.0601 秒。
- 模型生成吞吐：1.4608 帧/秒。
- 实时倍率：16.43×，即处理 1.375 秒输入平均需要 22.59 秒。
- 持续 chunk 吞吐：2.6560 个/分钟。

## 播放行为

输入采样、骨架预览和网页播放均为20 Hz；网关发送真实的`fps`与
`playback_fps`。首个输入窗口收集17帧，首末帧相隔0.8秒；稳态下后续窗口
新增16帧。若模型偶发落后，下一轮直接读取固定环形缓冲中的最新17帧。

首个输出播放全部 17 帧；后续输出根据 `drop_first_frame=true` 跳过重复 anchor，
播放16张新图，正好覆盖0.8秒。新 chunk 一到就立即替换旧播放；若没有新结果，
网页冻结在当前 chunk 的末帧，不循环旧动作。

实时 Worker 不再调用 `save_video()`，也不会把模型结果写成 MP4。普通离线/
批处理推理仍保留原来的 MP4 输出。

`MEMWORLD_STATS` 中 `pose_rx_hz` 是 Quest 原始接收率，通常仍接近 90 Hz；
`model_sample_hz` 才是进入模型窗口的实际采样率，应接近20 Hz；
`preview_tx_hz` 也应接近20 Hz。

每个真实模型结果会输出一行 `MEMWORLD_OUTPUT`，其中：

- `zip_bytes`：17 张 JPEG 的 ZIP 字节数。
- `jpeg_encode_ms`：Worker 编码并打包 17 张 JPEG 的耗时。
- `zip_receive_ms`：Operator 从收到输出元数据到完整收到 ZIP 的耗时。
- `zip_unpack_ms`：Operator 校验并解出 17 张 JPEG 的耗时。
- `inference_ms`：模型推理加 JPEG 编码打包的总耗时。

同样的数据可在 Dashboard 的 `status.json` 中通过 `frame_zip_bytes`、
`jpeg_encode_ms`、`frame_zip_receive_ms` 和 `frame_zip_unpack_ms` 查看。

## 2026-07-23 JPEG 传输与 warmup 实测
以下是切换 17 帧 profile 之前的历史数据，仅供对比。

RTX 4090、33 帧、640×352、4 steps、CFG 1.0：

- 真实模型 JPEG ZIP：725,513 bytes。
- Worker JPEG 编码及打包：20.85 ms。
- 本机 WebSocket 接收：0.777 ms（禁用 WebSocket 二次压缩）。
- Operator 校验并解包：1.399 ms。
- 两次首次 warmup：3979.9 ms、3011.0 ms，总计 6990.9 ms。
- 同一 Worker 的第二个会话跳过 warmup，约 48.9 ms 返回 ready。
