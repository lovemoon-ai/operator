# Cloud 提交成功不等于打印已启动

- 日期：2026-09-08
- 状态：ACTIVE

## Trigger conditions

- 使用 `bambu-cli print start --cloud`。
- 云插件返回成功或 CLI 输出 `started=true`。
- 打印机位于异地网络、通过 Cloud/PIN 访问，或任务下发存在延迟。

## Symptom

云插件完成 `create → upload → sending → finished` 并返回 0，但打印机持续为 `IDLE`、进度 0%，没有出现 `PREPARE` 或 `RUNNING`。

## Causes

- Direct cause：CLI 把云插件返回 0 解释为“打印已启动”，但该返回值只证明上传/云任务调用完成。
- Root cause：CLI 在 `bambu_network_start_print` 返回后立即销毁 CloudAgent，没有保持同一订阅会话等待设备确认；异步下发可能尚未完成，同时 CLI 也无法检测这一状态。
- Contributing factors：CLI 未在同一命令中主动刷新并等待设备状态转换；未保存阶段日志时无法区分上传、建任务与设备启动。

## Evidence

- 同一最终工件两次提交均完成 `create/upload/sending/finished`，退出码为 0。
- 第二次使用唯一项目名，排除了简单任务名冲突。
- 第二次提交后约四分钟内 18 次查询均未观察到 `PREPARE/RUNNING`，设备保持 `IDLE`。
- 修复后保持同一 CloudAgent、主动刷新状态；相同工件再次提交后在命令返回前观察到 `RUNNING`，随后独立查询仍为 `RUNNING`，AMS 3 已实际装载。

## Required controls

- 将云插件成功仅记录为 `SUBMITTED`，不得据此报告 `RUNNING`。
- 每次真实提交保存 stdout、stderr、退出码、项目名、SHA-256 和提交时间。
- 提交后持续只读查询；只有观察到 `PREPARE/RUNNING` 才确认设备接收，只有 `RUNNING` 才报告开始。
- 超时仍为 `IDLE` 时标记 `SUBMITTED_BUT_NOT_STARTED`，禁止自动重发。
- 再次提交必须由用户明确授权，并先确认屏幕、历史记录或队列中没有隐藏任务。

## Blocking conditions

- 上一次提交结果仍未知。
- 设备没有状态转换且用户尚未检查任务队列或屏幕。
- 未保留本次提交阶段日志。

## Verification evidence

- 云插件阶段日志包含无错误的 `sending/finished`。
- 独立状态查询观察到 `PREPARE` 或 `RUNNING`。
- 若仍为 `IDLE`，报告明确区分“云端已接受”和“设备未启动”。

## Recovery/remediation

- 已修复 CLI：保持 CloudAgent 活跃并等待设备进入 `RUNNING`；超时输出 `submitted:true, started:false` 并返回状态码 2。
- 增加原始设备错误/HMS/任务字段诊断，定位云端下发后被设备拒绝的原因。
