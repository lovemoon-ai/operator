# H2 特权打印命令必须先安装设备证书

- Date: 2026-09-11
- Status: Active, verified on H2S

## Trigger Conditions

- H2S/H2D 等安全固件通过 LAN 接收 `project_file` 打印命令。
- BRTC 已成功把 `.gcode.3mf` 上传到 eMMC。
- 本地 MQTT 已连接并收到 `push_status`，但发送阶段仍返回 `-4030`。
- 打印机同时绑定到 Bambu 账号，即使当前使用 LAN Access Code。

## Symptom

helper 报告 `upload` 和 `waiting` 成功，随后在 `sending` 阶段返回
`code=-4030 send msg failed`。目标任务没有进入 `PREPARE/RUNNING`，打印机仍显示旧任务的
`FINISH` 状态。

## Direct Cause

H2 的特权 `print.project_file` 消息需要应用证书签名，并使用打印机设备证书加密 `url` 与
`param`。仅建立 LAN MQTT 和收到 `push_status` 不会自动完成该信任配置。Bambu Studio 会调用
`bambu_network_update_cert`，并周期性调用
`bambu_network_install_device_cert(dev_id, lan_only)`；安装成功后插件通过消息回调报告
`device_cert_installed`。

## Root Cause

CLI helper 已加载 CA 文件并建立 LAN MQTT，但没有调用官方插件的应用证书更新和设备证书安装
接口。插件因此缺少发布签名打印指令所需的信任状态，最终把 MQTT 发布失败映射为
`BAMBU_NETWORK_ERR_PRINT_LP_PUBLISH_MSG_FAILED (-4030)`。

## Contributing Factors

- 普通 `pushall` 不属于特权打印消息，可以成功发布，导致连接预检出现假阳性。
- BRTC 上传不依赖最终 MQTT 指令签名，因此文件上传成功不能证明打印发布可用。
- 原 fake plugin 未要求设备证书就绪，无法覆盖真实安全固件的约束。

## Evidence

- `0.1.11-h2s-ready` 实机已返回 `connected=true`、`printer_ready=true`，且 media-ability 返回
  `emmc`/`udisk`，随后同一次提交仍在 `sending` 返回 `-4030`。
- Bambu Studio `02.08.02.61` 在连接打印机和设备刷新流程中调用
  `bambu_network_install_device_cert`。
- networking ABI 将 `-4030` 定义为本地打印 MQTT 发布失败。
- 独立协议实现的实机研究记录：未安装设备证书时，特权消息会在客户端返回 `-4`，并由本地
  打印流程转换为 `-4030`。

## Required Controls

1. 本地连接成功并收到 `push_status` 后，调用 `bambu_network_update_cert` 刷新应用证书材料。
2. 对可能同时是 LAN-only 和账号绑定的打印机，依次请求
   `install_device_cert(dev_id, true)` 与 `install_device_cert(dev_id, false)`。
3. 重复安装请求时遵守超时，直到消息回调收到 `device_cert_installed`；未收到时禁止上传打印
   文件或调用 `start_local_print`。
4. fake plugin 必须要求应用证书已更新、两个安装路径已请求且设备证书回调已收到，才允许本地
   打印成功。
5. 真实提交失败后立即查询状态。默认禁止自动重试；若用户已对同一打印机、同一 SHA 和同一
   AMS 映射明确授予持续重试权限，可在确认前次任务未启动后继续。

## Blocking Conditions

- `bambu_network_update_cert` 或设备证书安装流程不可用。
- 未收到 `device_cert_installed`。
- 只有 `connected=true`/`printer_ready=true`，没有 `device_cert_ready=true`。
- BRTC 上传后出现 `-4030`，但目标任务未进入 `PREPARE/RUNNING`。
- 上一次真实提交失败后既没有新的明确授权，也没有覆盖该任务的持续重试授权。

## Verification Evidence

- `0.1.12-h2s-cert-ready` 的 Go 测试和 fake-plugin 集成测试全部通过。
- 回归测试要求本地打印同时满足 MQTT 状态就绪和设备证书就绪。
- 回归测试在禁用设备证书回调时验证 helper 会超时阻断。
- `0.1.12-h2s-cert-ready` 已在 H2S 实机返回
  `connected=true, device_cert_ready=true, printer_ready=true`。
- 同一版本随后成功提交 SHA-256
  `4ada6d802d84d79ff0313ddb5e766c90330615b5723e04670bcbdc5c44f01c35`，打印机进入
  `RUNNING`，目标层数为 `147`，从而验证 `-4030` 修复链路有效。

## Recovery / Remediation

- 安装包含应用证书更新、双模式设备证书安装和证书就绪等待的 CLI/helper。
- 复核目标 SHA、打印机空闲状态、AMS 映射和打印盘安全状态。
- 获取绑定新版本和 SHA 的授权后提交，并观察目标任务进入 `PREPARE/RUNNING`；若有明确的
  持续重试授权，仍需先排除前次任务已经启动。
