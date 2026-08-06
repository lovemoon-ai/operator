# MemWorld 生成图像回传 Quest 设计

## 目标

Quest 的 `memWorld` 模式继续发送实时 head/hands Pose，但不再显示 Operator
投影的手部骨架 JPEG。Quest 只显示 MemWorld worker 最新生成的 JPEG 序列。
第一批模型结果完成前不发送图片，Quest 保持黑屏。

## 保持不变的部分

- Quest Pose 仍不限速发送，Operator 以约 8.89 Hz 采样。
- Operator 仍生成 640×352 手部骨架图，作为模型 keypoint 输入。
- 电脑 Dashboard 仍可显示骨架投影，方便检查投影和跟踪质量。
- 模型输入仍是 17 帧，后续窗口复用上一窗口末帧作为 anchor。
- 模型输出仍通过 worker 到 Operator 的 JPEG ZIP 通道传输。

## 数据流

1. Quest 向 Operator 发送最新 Pose。
2. Operator 投影骨架、构造 17 帧模型输入并提交给 worker。
3. Worker 返回 17 张生成 JPEG；后续 chunk 的重复首帧按
   `drop_first_frame=true` 从播放缓存中移除。
4. `DashboardState` 继续作为最新模型 chunk 的原子播放缓存，并按约
   8.89 Hz 选择当前生成帧。
5. Quest 回传循环从该模型播放缓存取得 JPEG，再用现有 PINF 二进制协议发送。
6. 新 chunk 完成时立即替换当前缓存；没有新 chunk 时冻结在末帧。

## Quest 回传语义

- 模型缓存为空时，回传循环不发送二进制图片，因此 Quest 保持黑屏。
- 模型缓存存在时，每个调度周期最多发送一张当前生成 JPEG。
- PINF 的 `frame_id` 和 `capture_time_ns` 使用当前最新 Pose 的值。
  这两个字段表示本次传输的新鲜度，避免 Quest 的 250 ms 过期保护把
  约 1.8 秒推理后的生成图误判为陈旧数据。
- JPEG 内容来自 worker 输出，不再来自 `latest_preview` 骨架缓存。
- Pose 停止或过期时暂停回传，避免持续显示为“实时”的陈旧结果。

## 组件修改

### Operator 网关

- `preview_loop` 改为接收 `DashboardState`，从模型播放缓存读取 JPEG。
- 保留 `projection_loop` 对骨架 PNG/JPEG 的生成：PNG 供模型输入，JPEG 供
  Dashboard `/skeleton.jpg` 调试页面使用。
- `websocket_handler` 创建回传任务时把 Dashboard 播放缓存传入。
- 统计字段 `preview_tx_hz` 暂时保留名称，但含义变为 Quest 模型图片发送率，
  目标约为 8.89 Hz。

### Quest 客户端

现有 `MemWorldClient`、PINF 解析和 `PoseInferenceDisplay.show_jpeg` 无需修改。
它们不区分 JPEG 的生成来源，只要求尺寸、协议头和时间戳有效。

## 错误处理

- worker 离线、推理失败或尚无结果：不发送图片，保持黑屏或上一张已显示内容。
- Quest Pose 过期：暂停图片发送。
- 新 worker 结果格式非法：沿用现有校验并拒绝替换当前播放缓存。
- Quest 断线：取消投影、模型回传和 worker 客户端任务。

## 测试标准

- 单元测试：没有模型帧时回传循环不发送任何 PINF 数据。
- 单元测试：有模型帧时，PINF 解出的 JPEG 与 worker 输出帧一致，且不是骨架图。
- 单元测试：PINF 使用最新 Pose 的 `frame_id/capture_time_ns`。
- 端到端测试：fake worker 返回 JPEG chunk 后，Quest WebSocket 收到其中的
  生成 JPEG；模型结果前不会收到骨架 PINF。
- 回归测试：Dashboard 骨架预览、17 帧 chunk、anchor 去重和约 8.89 Hz
  播放行为保持通过。

## 非目标

- 不新增 WebSocket 或新的 Quest 图像协议。
- 不让 worker 绕过 Operator 直接连接 Quest。
- 不移除电脑 Dashboard 的骨架调试预览。
- 不改变模型、checkpoint、推理步数或 CFG。
