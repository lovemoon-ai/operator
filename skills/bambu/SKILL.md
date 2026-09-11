---
name: bambu
description: 使用 bambu-cli 安装、配置、诊断、切片、审核、监控和控制 Bambu Lab 3D 打印机。用户要求通过局域网访问码或跨局域网匹配 PIN 操作打印机、选择 AMS 材料、准备并审核模型、启动/停止打印、复位设备，或排查 bambu-cli/Bambu Studio 云连接时使用。
---

# Bambu CLI

通过命令行完成 Bambu Lab 打印机操作，不使用 Bambu Studio 的桌面 UI。

当前功能源码使用：

- 仓库：`https://github.com/DuinoDu/bambu-cli.git`
- 分支：`main`

需要安装、更新、完整参数或排障时，读取 `references/cli-reference.md`。用户要求从模型文件
准备并实际打印时，**必须先读取并完整执行 `references/print-sop.md`**，再读取
`references/lessons/README.md`，运行 `scripts/list_bambu_lessons.sh` 并逐篇完成 Lesson Gate；
只读状态查询、配置查看和单纯排障不需要执行整套打印 SOP。先运行
`scripts/find_bambu_cli.sh` 定位支持 `slice` 和 `cloud` 的二进制；不要假定 `bambu-cli` 已经
在 `PATH` 中。

## 选择连接方式

- **LAN**：打印机 IP 可达，并且有序列号与 LAN Access Code。使用 `status`、`doctor`、
  `ams status` 以及普通 `print start`。
- **H2 系列 LAN**：用户侧仍使用普通 `print start`，但 CLI 必须识别 H2 序列号并改走
  Bambu Studio networking plugin 的 BRTC/eMMC 通道。提交前按顺序检查 FTPS 诊断、BRTC
  media ability、本地 `push_status` 和 `device_cert_installed`；具体失败模式见
  `references/lessons/README.md` 中四篇 H2 lesson。
- **Cloud**：打印机在另一局域网或只能用匹配 PIN。要求 Linux 上安装并登录 Bambu
  Studio，且存在官方 `libbambu_networking.so`。使用 `cloud doctor`、`cloud bind`、
  `cloud ams` 和 `print start --cloud`。
- Cloud 模式只需要目标打印机序列号，不应为了云打印索要 LAN IP 或 Access Code。
- `cloud doctor` 可以读取云端状态快照，包括 `printer_state`、`progress` 和
  `remaining_minutes`，但当前没有 Cloud `watch`。上传成功只表示任务已提交；观察到
  `PREPARE` 后再到 `RUNNING` 才能宣称已经开始，观察到 `FINISH` 才能宣称完成。

## 默认工作流

1. 定位二进制并运行 `--version`、`--help`，确认当前构建支持所需命令。
2. 先做只读检查：配置列表、`doctor`/`cloud doctor`、状态和 AMS。
3. 若任务涉及模型准备或打印，执行 `references/print-sop.md`，并对 lessons 索引中的每篇
   lesson 给出适用性、已采取控制和检查证据。
4. 保留独立对象；不要为了绕过单输入限制把多个零件静默合并成一个 STL。
5. 对最终 `gcode.3mf` 运行自动校验，并输出布局、首层、支撑、悬垂和风险层审核结果。
6. 向用户提交最终打印报告；授权必须绑定到已审核文件的 SHA-256。
7. 能用 `--dry-run` 时先预演，然后只提交一次真实命令。失败后默认不自动重试；若用户已对
   同一打印机、同一 SHA 和同一材料映射明确授予持续修复与重试权限，可在每次确认前次任务
   未启动且设备状态安全后继续。
8. 执行后查询状态。区分“已提交”“PREPARE”“RUNNING”和“FINISH”。

## 物理安全

- 将以下操作视为会改变真实设备状态：打印、暂停/恢复/停止、回零、移动、加热、风扇、
  灯光、校准、重启、云端复位、发送 G-code、上传/删除打印文件。
- 在打印、运动、加热、校准、重启、复位或任意 G-code 前，必须在当前上下文中取得用户
  对该具体动作的许可。旧任务的许可不能自动沿用到新的打印或恢复动作。
- 用户可以对一个明确限定的任务授予持续执行或重试权限；记录其打印机、文件 SHA、材料映射
  和停止条件，不要把该权限扩展到其他任务。
- 回零、移动或复位前，提醒用户确认打印盘、喷头路径和机构附近无手、工具、残料或打印件。
- `--force` 会绕过 CLI 自带确认；仅在用户明确要求无交互执行该具体动作时使用。
- 优先使用精确确认 token：`cloud-print`、`reset`、`stop`、`delete`、`gcode`、
  `calibrate`、`reboot`。即使 CLI 本身未要求 token，也仍需遵守上面的用户授权规则。
- `--dry-run` 是全局参数，必须放在命令前；它不是所有子命令都支持，尤其不要用它假设
  `print pause` 或 `print resume` 不会执行。

## 凭据安全

- 不在命令行、聊天、日志、提交或进程参数里暴露 Access Code、匹配 PIN、云 token。
- Access Code 写入权限为 `0600` 的文件，再通过 `--access-code-file` 使用。
- 匹配 PIN 首选交互式 `bambu-cli cloud bind`，由 CLI 隐藏输入；自动化时只从 stdin
  传入，命令示例中只使用占位符或临时环境变量，执行后立即清除。
- 不读取、复制或打印 Bambu Studio 的登录 token。云 helper 应直接复用已登录 Studio
  会话和已安装插件。
- 输出诊断信息给用户前，遮盖 Access Code、PIN、token；公开日志也应酌情遮盖序列号。

## 命令语法不变量

- 全局参数放在主命令前：`bambu-cli --printer lab --json cloud doctor`。
- 子命令参数放在文件位置参数前：
  `bambu-cli print start --cloud --plate 1 ./part.gcode.3mf`。
- Cloud AMS 映射必须来自 `cloud ams` 的实际 tray ID；按颜色和材料共同匹配。
  多个 tray 都满足时询问用户，不按视觉位置或历史槽位猜测。
- 多文件任务必须保留为独立对象，以便分别审核朝向、支撑、brim、接缝和材料。现有工具无法
  做到时停止并说明能力缺口，不把文件合并后直接打印。
- 尺寸使用毫米。用户要求 `1 cm` 立方体时，建模尺寸应为 `10 mm × 10 mm × 10 mm`；
  `slice` 会将模型放到打印盘中心。

## 故障处置

- 命令失败时先保存退出码和 stderr，再做一次只读诊断；不要循环重试打印、复位或 G-code。
- 上次任务状态不明时，先确认打印机实际状态和打印盘是否清理，不能直接发起下一次打印。
- Cloud-only 场景可以用 `cloud doctor` 轮询状态快照，但不能假装有持续流式监控或摄像头
  证据。状态字段不足以判断首层外观、翘边、拉丝或支撑质量时，要求用户从打印机屏幕确认。
- 喷头停在角落不等于故障。只有用户确认机构区域安全后，才可执行 LAN `home` 或 Cloud
  `cloud reset`；Cloud reset 会停止任务、降温并回零。
