# H2 本地打印必须等待 MQTT 状态流就绪

- Date: 2026-09-11
- Status: Active

## Trigger Conditions

- H2S/H2D 等 H2 系列通过官方 networking plugin 执行 LAN 本地打印。
- `bambu_network_connect_printer` 的本地连接回调返回成功。
- BRTC/eMMC 上传成功，但提交阶段返回 `-4030` 或 `send msg failed`。

## Symptom

本地打印进度先进入 `upload` 和 `waiting`，随后在 `sending` 阶段返回 `-4030`。打印机保持
`FINISH` 或 `IDLE`，目标任务没有进入 `PREPARE/RUNNING`。该症状也可能由后续设备证书
握手缺失引起，不能仅凭 `-4030` 判定是状态流问题。

## Direct Cause

本地连接成功回调只证明 LAN MQTT 连接已建立，不证明插件内部的状态订阅和发布通道已经
就绪。Bambu Studio 在连接成功后还会发送 `pushing.pushall`，并等待本地消息回调返回
`push_status`，之后才启动本地打印任务。

## Root Cause

helper 把 `OnLocalConnectedFn(status=0)` 错当成完整就绪条件，收到回调后立即调用
`bambu_network_start_local_print`。fake plugin 也只检查“已连接”，没有要求本地状态握手完成，
因此原集成测试无法发现真实插件的时序约束。实机验证表明补齐本关后仍可能因设备证书未安装
而返回 `-4030`；设备证书要求见 `2026-09-11-h2-device-cert-signing.md`。

## Contributing Factors

- BRTC 文件上传和 MQTT 任务发布是两个阶段；上传成功掩盖了发布通道尚未就绪。
- `-4030` 出现在官方插件内部，缺少握手阶段诊断时容易被误判为 AMS 或 G-code 参数错误。
- 只验证连接回调，没有验证 `on_local_message` 是否真正收到状态数据。

## Evidence

- 旧实现实机返回 `local print: sending code=-4030 send msg failed`。
- 失败后打印机仍为 `FINISH`，旧任务 `192/192`，温度归零且错误码为 `0`，证明目标任务未启动。
- 补齐状态握手后，只读 `local-connect` 实机返回 `connected=true` 和 `printer_ready=true`，证明
  本关通过，但不单独证明签名打印命令可发布。
- 同一版本的只读 media-ability 检查返回 `emmc` 和 `udisk`。

## Required Controls

1. 调用 `bambu_network_connect_printer` 前清除旧的连接状态和 `printer_ready` 标志。
2. 仅在本地连接回调返回 `status=0` 后发送完整 `pushing.pushall` 请求。
3. 必须从 `on_local_message` 收到目标序列号的 `push_status` 或等价完整状态消息，才允许上传和
   调用 `bambu_network_start_local_print`。
4. `pushall` 发送失败或状态等待超时必须返回明确错误，并在上传前阻断任务。
5. fake-plugin 集成测试必须让本地打印依赖状态握手；另设无状态回调测试，确认 helper 会超时
   失败而不是继续打印。
6. 真实提交前运行无副作用的 `local-connect`，输出必须同时包含 `connected=true` 和
   `printer_ready=true`。
7. 任一真实提交失败后立即核对打印状态。默认不自动重试；存在绑定打印机、版本、SHA 和材料
   映射的持续重试授权时，可在确认前次任务未启动后继续。

## Blocking Conditions

- 本地连接成功，但 `pushall` 返回负值。
- 未收到本地 `push_status`，或状态消息来自其他序列号。
- helper 只报告 `connected`，不能证明 `printer_ready`。
- fake plugin 允许未完成状态握手时调用本地打印。
- 上一次真实提交失败后没有新的明确授权。

## Verification Evidence

- `0.1.11-h2s-ready` 的 Go 测试和 cloud-helper fake-plugin 集成测试全部通过。
- 回归测试在禁用本地状态回调时要求 `local-connect --timeout 1` 失败，并检查超时诊断。
- H2S 实机只读验证收到 `push_status`，返回
  `{"connected":true,"printer_ready":true,...}`。
- 最终打印文件 SHA-256 保持不变；随后一次已授权提交仍在 `sending` 阶段返回 `-4030`，由此
  确认还必须执行独立的设备证书关卡。
- 补齐设备证书关卡后，同一 H2S 的目标任务成功进入 `RUNNING`，层数为 `147`，证明
  `push_status` 是必要但不充分的中间就绪条件。

## Recovery / Remediation

- 安装包含本地 MQTT 就绪握手的 CLI/helper。
- 先执行 `local-connect`、media-ability 和打印机空闲状态检查。
- 重新核对最终文件 SHA、AMS 映射和打印盘安全状态。
- 获取新的明确授权后只提交一次，并观察目标任务进入 `PREPARE/RUNNING`。
