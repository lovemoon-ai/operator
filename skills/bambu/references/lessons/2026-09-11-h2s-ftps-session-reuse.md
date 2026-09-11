# H2S FTPS 数据连接必须复用 TLS 会话

- Date: 2026-09-11
- Status: Active

## Trigger Conditions

- 通过 LAN profile 对 H2S 执行旧式 FTPS 目录读取或兼容性诊断。
- FTPS 控制连接和登录成功，但数据连接返回 `522 SSL connection failed: session reuse required`。
- 上传返回 `553 Could not create file`，同时打印机仍为空闲且任务文件未创建。

## Symptom

`doctor` 的 FTP 端口检查可以通过，但目录读取失败。修复会话复用后目录读取可成功；这并不
表示 H2S 允许使用旧式 FTPS 写入打印文件。

## Direct Cause

H2S 的 FTPS 服务要求数据连接复用控制连接的 TLS 会话。原客户端没有配置
`ClientSessionCache`；并且在没有固定 `ServerName` 时，Go 使用包含随机数据端口的远端地址作为
会话缓存键，控制连接与数据连接无法命中同一个 TLS 会话。

## Root Cause

- `doctor` 只验证了 FTPS 控制端口可连接，没有建立数据连接。
- P1/P1S 的服务没有暴露该要求，因此原 LAN 工作流没有覆盖 H2S 的会话复用行为。
- 上传错误 `553` 没有直接显示底层 TLS 会话复用原因，只有后续目录读取显示明确的 `522`。

## Required Controls

1. FTPS TLS 配置必须设置共享 `ClientSessionCache`。
2. TLS 配置必须使用稳定的打印机主机名或 IP 作为 `ServerName`，使控制连接与随机端口的数据
   连接共享缓存键。
3. H2S 首次使用或升级 CLI 后，先运行只读 `files list`；仅控制端口 `doctor` 通过不够。
4. H2S 打印上传必须继续执行 H2 BRTC/eMMC lesson，不能因为 FTPS 列表成功就使用 `STOR`。
5. 上传或打印提交失败后立即查询打印状态；没有观察到 `PREPARE/RUNNING` 时不得宣称已启动。
6. 失败后默认禁止自动重发。若用户已对同一任务明确授予持续重试权限，仍需先确认前次任务未
   启动，再进入 BRTC/eMMC 路径。

## Blocking Conditions

- `files list` 返回 `522 session reuse required`。
- 修复后的 CLI 尚未通过测试和 H2S 实机只读目录访问。
- 上一次失败后尚未取得用户明确的重新提交授权。

## Verification Evidence

- 修复前：H2S `files list` 返回 `522 SSL connection failed: session reuse required`。
- 修复后：Go 测试全部通过；安装后的 CLI 能通过 H2S FTPS 数据连接列出根目录且无错误。
- 修复范围：`internal/printer/ftp.go` 增加稳定 `ServerName` 和共享 TLS client session cache。

## Recovery / Remediation

- 更新并重新构建 CLI，再用 `files list` 做无副作用验证。
- 若目标是打印，转入 H2 BRTC/eMMC lesson，不继续尝试 FTP `STOR`。
