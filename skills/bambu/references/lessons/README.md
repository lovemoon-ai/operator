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
