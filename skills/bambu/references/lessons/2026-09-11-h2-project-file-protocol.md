# H2 系列 LAN 打印必须优先使用 BRTC/eMMC 通道

- Date: 2026-09-11
- Status: Active

## Trigger Conditions

- H2S/H2D 等 H2 系列通过 LAN 打印预切片 `.gcode.3mf`。
- FTPS 数据连接已经能建立，但 `STOR filename.gcode.3mf` 或 `STOR /filename.gcode.3mf`
  返回 `553 Could not create file`。
- CLI 尝试沿用 P1/A1/X1 的“FTPS 上传后发送 MQTT `project_file`”流程。

## Symptom

控制连接、登录和目录读取成功，但 H2S 拒绝通过旧式 FTPS 路径创建打印文件。只修改 `STOR`
路径为绝对路径仍返回 `553`，因此任务不会进入 MQTT 提交阶段。

## Direct Cause

- 支持 BRTC 的 H2 系列在 Bambu Studio 中优先使用 `libbambu_networking.so` 的文件传输/本地
  打印接口，而不是旧式 FTPS 写入。
- LAN 文件传输隧道 URL 为 `bambu:///local/<ip>?port=6000&user=bblp&passwd=<access-code>`；
  凭据只能通过安全输入传给 helper，不能出现在 CLI 参数或日志中。
- `bambu_network_start_local_print` 接收完整 `PrintParams`，并通过 `try_emmc_print=true` 选择
  H2 内部存储流程；由官方插件负责上传和发送与固件匹配的打印命令。

## Root Cause

CLI 错误地假设 H2S 仍允许通过传统 FTPS 写入打印文件，并尝试自行拼装 H2 MQTT payload。
官方 Studio 对该能力使用独立的 BRTC 文件传输 ABI；FTP 在此机型上只能作为兼容性回退，
不能把目录读取成功等同于可写。

## Required Controls

1. 通过序列号或打印机 model ID 明确识别 H2 系列；不得用用户猜测决定协议分支。
2. H2 LAN 打印调用 Bambu Studio 插件的 `bambu_network_start_local_print`，并设置
   `connection_type=lan`、打印机 IP、`try_emmc_print=true`。
3. 访问码仅通过 helper stdin 传入；不得出现在进程参数、日志或错误文本中。
4. 首次使用或插件升级后，先用 `ft_*` ABI 的 media-ability 只读请求确认 BRTC 隧道可连接，
   且返回 `emmc`。
5. H2 AMS 映射长度必须对应项目 filament 数；同时传递 `ams_mapping`、`ams_mapping2` 和
   `ams_mapping_info`。
6. 继续校验最终 3MF、plate G-code MD5、打印机状态和材料，再调用官方本地打印接口。
7. 对 helper ABI、参数映射和调用路径做 fake-plugin 回归测试。
8. 任一真实上传或提交失败后立即核对状态。默认禁止自动重试；若用户明确授予同一任务的持续
   重试权限，可在确认前次任务未启动后继续。

## Blocking Conditions

- H2 仍通过传统 FTPS 执行打印文件上传。
- BRTC media-ability 探测失败或结果不含 `emmc`。
- 官方 Bambu Studio networking plugin 缺失或不导出 `ft_*` / `bambu_network_start_local_print`。
- 最终 3MF 缺少或包含无效的 plate G-code MD5。
- 使用 AMS 但缺少 H2 `ams_mapping2`，或映射长度与项目 filament 数不一致。
- 打印机已有校准、维护或其他活动任务。
- 上一次失败后没有新的用户授权。

## Verification Evidence

- 传统 FTP 相对路径和绝对根路径都在 H2S 返回 `553`，且失败后打印机保持 `FINISH`。
- Bambu Studio 2.8.2 公开源码中的 `PrintJob`/`SendToPrinter` 对 `is_support_brtc` 设备创建
  `bambu:///local/...:6000` 隧道，并使用 eMMC 文件传输或 `start_local_print`。
- 修复版 helper 的只读 media-ability 实机验证返回 `["emmc","udisk"]`。
- fake-plugin 集成测试覆盖本地隧道、eMMC 上传和 `start_local_print` 参数；完整测试通过。
- 加入 MQTT 状态与设备证书关卡后，H2S 实机接受同一文件，目标任务进入 `RUNNING 0/147`，
  证明 BRTC/eMMC 路径是该机型的有效 LAN 打印通道。

## Recovery / Remediation

- 安装包含 H2 BRTC/eMMC 本地打印支持的 CLI 与 native helper。
- 等待设备当前任务结束，重新检查最终 SHA、AMS、打印盘和状态。
- 获得新授权后只提交一次，并观察到目标工件的 `PREPARE/RUNNING`。
