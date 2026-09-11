# 打印 Lessons 索引

本目录保存实际打印失败、险情和重要误判形成的防复发经验。`print-sop.md` 只保留通用流程；
每个具体 lesson 使用一篇独立 Markdown。

## 使用规则

每次实际打印前：

1. 运行 `../../scripts/list_bambu_lessons.sh`；未登记或丢失的 lesson 会使脚本失败。
2. 读取本索引和脚本列出的全部 lesson。
3. 对每篇标记 `APPLIES` 或 `NOT_APPLICABLE`，并说明原因。
4. 对 `APPLIES` 的 lesson 执行其 `Required controls`。
5. 把检查证据写入打印报告。
6. 任何适用 lesson 未检查或证据不足时禁止打印。

不要只根据文件名猜测适用性；需要打开 lesson 正文读取触发条件。

## Lessons

| Lesson | 适用场景 | 核心阻断条件 |
| --- | --- | --- |
| [`2026-09-04-mirrored-shell-orientation.md`](2026-09-04-mirrored-shell-orientation.md) | 左右镜像件、盒体、罩壳、杯状件、复制旋转、关闭支撑 | 开口方向错误；床面接触异常；内腔上方出现无支撑大跨度挤出 |
| [`2026-09-04-machine-service-paths.md`](2026-09-04-machine-service-paths.md) | 用 G-code 坐标检查越界 | 未区分机器维护轨迹与模型打印轨迹 |
| [`2026-09-08-cloud-submit-false-positive.md`](2026-09-08-cloud-submit-false-positive.md) | Cloud/PIN 打印、云接口返回成功、异地网络打印 | 未观察到 `PREPARE/RUNNING`；把上传成功误报为打印开始；状态未知时重复提交 |
| [`2026-09-09-multi-shell-assembly-fused.md`](2026-09-09-multi-shell-assembly-fused.md) | 单 STL 含多个闭合 shell、装配体、壳体加背板、print-in-place | 未确认物理零件数；可拆件仍按一个对象打印；间隙小于线宽 |
| [`2026-09-10-critical-neck-layer-fracture.md`](2026-09-10-critical-neck-layer-fracture.md) | 窄颈、安装耳、悬臂座、承力凸台、沿层面断裂 | 未审核载荷与层线方向；承力连接仍用低墙数/低填充；侧立稳定性未验证 |
| [`2026-09-11-h2s-ftps-session-reuse.md`](2026-09-11-h2s-ftps-session-reuse.md) | H2S 旧式 FTPS 目录读取出现 `522` | 数据连接未复用控制连接 TLS 会话；把可读误判为可写 |
| [`2026-09-11-h2-project-file-protocol.md`](2026-09-11-h2-project-file-protocol.md) | H2 系列 LAN 打印、FTPS `STOR` 返回 `553` | 未使用官方 BRTC/eMMC 本地打印接口；失败后未经新授权自动重发 |
| [`2026-09-11-h2-local-mqtt-readiness.md`](2026-09-11-h2-local-mqtt-readiness.md) | H2 本地连接成功、BRTC 上传后发送阶段返回 `-4030` | 未发送 `pushall` 并等待本地 `push_status`；把连接回调误当作发布通道就绪 |
| [`2026-09-11-h2-device-cert-signing.md`](2026-09-11-h2-device-cert-signing.md) | H2 已收到 `push_status`，但特权打印命令仍返回 `-4030` | 未安装应用/设备证书；缺少 `device_cert_installed` 就绪证据 |

H2 系列排障按表中顺序执行：先区分 FTPS 数据连接与写入能力，再切换 BRTC/eMMC，随后验证
本地 `push_status`，最后验证设备证书。某一层成功不能替代下一层；只有目标任务进入
`PREPARE/RUNNING` 才能确认提交链路真正完成。

## 新增 lesson 格式

每篇 lesson 应包含：

- 日期与状态。
- Trigger conditions。
- Symptom。
- Direct cause、root cause 和 contributing factors。
- Evidence。
- Required controls。
- Blocking conditions。
- Verification evidence。
- Recovery/remediation。

文件名使用 `YYYY-MM-DD-short-topic.md`。一个独立问题一篇，不把多次无关事故合并。
