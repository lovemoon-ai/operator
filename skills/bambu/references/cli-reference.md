# bambu-cli 参考

从 STL/3MF 准备并实际打印前，必须同时读取并执行 `print-sop.md`，并按
`lessons/README.md` 完成 Lesson Gate。本文件说明命令本身，不能替代几何、支撑、预览和
发布审核。

## 安装与更新

优先使用已经安装的功能版二进制：

```bash
CLI="$(./scripts/find_bambu_cli.sh)"
"$CLI" --version
"$CLI" --help
```

仅在用户要求安装/更新或本机没有可用二进制时，从 fork 的 `main` 构建；该分支已包含
Cloud/PIN、无头切片和 H2 系列 LAN 打印支持：

```bash
git clone --branch main --single-branch \
  https://github.com/DuinoDu/bambu-cli.git /tmp/bambu-cli-src
cd /tmp/bambu-cli-src
make test
make install PREFIX="$HOME/opt/bambu-cli"
```

安装后使用：

```bash
export PATH="$HOME/opt/bambu-cli/bin:$PATH"
bambu-cli --help
```

若目标目录已存在，不要覆盖或强制重置。先检查 `git status`、remote 和当前分支；有未提交
修改时停止并询问用户。始终以实际 `bambu-cli --help` 和 `--version` 为准。

## 参数位置

该 CLI 使用分层 flag parser，参数位置有意义：

```bash
# 正确：全局参数在命令前
bambu-cli --printer lab --json cloud doctor

# 正确：print start 参数在文件前
bambu-cli --printer lab print start --plate 1 ./part.gcode.3mf

# 避免：文件后再追加 --plate/--cloud
bambu-cli print start ./part.gcode.3mf --plate 1
```

常用全局参数：

- `--printer <name>`：选择配置 profile。
- `--json`：机器可读输出，AI 解析时优先。
- `--no-input`：禁止交互；危险动作同时需要正确的 `--confirm=<token>`。
- `--dry-run`：预演支持该选项的动作，必须放在命令前。
- `--force`：跳过 CLI 确认；除非用户明确要求，否则不用。
- `--serial <serial>`：临时指定目标打印机，Cloud 模式可单独使用。

## 配置

配置优先级：命令行 > 环境变量 > 当前目录 `.bambu.json` >
`~/.config/bambu/config.json`。

LAN profile：

```bash
mkdir -p ~/.config/bambu
umask 077
printf '%s' 'ACCESS_CODE_PLACEHOLDER' > ~/.config/bambu/lab.code
chmod 600 ~/.config/bambu/lab.code

bambu-cli config set --printer lab \
  --ip 192.168.1.200 \
  --serial SERIAL_PLACEHOLDER \
  --access-code-file ~/.config/bambu/lab.code \
  --default
```

不要把真实 Access Code 写入示例、shell history 或工具输出。实际录入时优先让用户在安全
终端中完成。Cloud-only profile 至少配置序列号：

```bash
bambu-cli config set --printer lab --serial SERIAL_PLACEHOLDER --default
```

只读检查：

```bash
bambu-cli --json config list
bambu-cli --printer lab doctor
bambu-cli --printer lab --json status
bambu-cli --printer lab --json ams status
```

同时查看所有已配置打印机：

```bash
bambu-cli status --all
bambu-cli --json status --all
bambu-cli --json status --all --active
```

`status --all` 对同时具有 IP 和 Access Code 文件的 profile 优先使用 LAN；只有序列号的 profile
使用 Cloud。LAN 查询失败且存在序列号时会回退 Cloud，并在结果中保留 `warning`。
`--active` 仅保留活动任务，但不会隐藏状态查询错误。该命令展示每台打印机的当前任务，不是
历史任务或云端队列列表。

`doctor`、`status` 和 `ams status` 是 LAN 路径，需要 IP 可达和 Access Code。LAN 默认检查
MQTT 8883、FTPS 990、Camera 6000。

## H2 系列 LAN

H2S/H2D 等 H2 系列不能沿用 P1/A1/X1 的 FTPS `STOR` 打印路径。CLI 根据序列号识别 H2，
通过 Bambu Studio 的 `libbambu_networking.so` 建立本地 MQTT，再走 BRTC/eMMC 上传和
`bambu_network_start_local_print`。安装包必须同时包含：

```text
$PREFIX/bin/bambu-cloud-helper
$PREFIX/share/bambu-cli/cert/slicer_base64.cer
$PREFIX/share/bambu-cli/cert/printer.cer
```

首次使用、升级 helper 或排查 `-4030` 时，先执行无副作用的就绪检查。Access Code 只能从
文件经 stdin 传入：

```bash
CLI="$(./scripts/find_bambu_cli.sh)"
HELPER="$(dirname "$CLI")/bambu-cloud-helper"
cat ~/.config/bambu/lab.code | "$HELPER" local-connect \
  --json --serial SERIAL_PLACEHOLDER --ip 192.168.1.200 --access-code-stdin
```

只有结果同时包含以下字段，才允许提交 H2 打印：

```json
{"connected":true,"device_cert_ready":true,"printer_ready":true}
```

这三个字段分别只证明 LAN MQTT 已连接、特权消息签名证书已安装、`push_status` 状态流已
就绪。BRTC media ability 还必须包含 `emmc`。任一阶段失败都应在上传前阻断；完整故障链按
`lessons/README.md` 中 H2 lessons 的顺序检查。

## Cloud / 匹配 PIN

前提：Linux 上已安装并登录 Bambu Studio，账号区域与打印机一致，并存在：

```text
~/.config/BambuStudio/plugins/libbambu_networking.so
```

可用覆盖变量：`BAMBU_STUDIO_CONFIG_DIR`、`BAMBU_STUDIO_PLUGIN`、
`BAMBU_CLOUD_CA_FILE`、`BAMBU_CLOUD_COUNTRY`（`CN`、`US` 或 `Others`）。

先只读诊断：

```bash
bambu-cli --printer lab --json cloud doctor
bambu-cli --printer lab --json cloud ams
```

绑定匹配 PIN，优先直接使用隐藏输入：

```bash
bambu-cli cloud bind
```

无交互环境只走 stdin；不要把真实 PIN 写进命令文本：

```bash
read -rsp 'Bambu matching PIN: ' BAMBU_PIN; printf '\n'
printf '%s\n' "$BAMBU_PIN" | bambu-cli --no-input cloud bind
unset BAMBU_PIN
```

## 切片与校验

`slice` 调用已安装的 Bambu Studio 切片器，不打开 UI，读取 Studio 当前选择的 machine、
process、filament preset，展开继承，并把模型居中：

```bash
bambu-cli slice \
  --bed-type 'Textured PEI Plate' \
  --output ./part.gcode.3mf \
  ./part.stl
```

必要时明确 preset 或路径：

```bash
bambu-cli slice \
  --studio /path/to/bambu-studio \
  --studio-config ~/.config/BambuStudio \
  --machine 'MACHINE_PRESET' \
  --process 'PROCESS_PRESET' \
  --filament 'FILAMENT_PRESET' \
  --output ./part.gcode.3mf \
  ./part.stl
```

上传前校验：

```bash
bambu-cli --json print validate --plate 1 ./part.gcode.3mf
```

不用 AMS 时显式加 `--no-ams`。校验会检查可打印层、挤出、耗材密度/用量、打印机模型 ID
以及 AMS 装载序列。不要绕过失败的校验。

当前 `bambu-cli slice` 只接受一个输入文件，也没有暴露逐对象朝向、支撑、brim 和预览导出。
多文件任务不要通过合并成一个 STL 来绕过限制；应先生成保留独立对象的项目 3MF，或者停止
并向用户说明当前工具能力不足。完整要求见 `print-sop.md`。

## AMS 材料选择

读取实际 tray：

```bash
bambu-cli --printer lab --json cloud ams
```

解析 `ams.ams[].tray[]` 的 `id`、`tray_color`、`tray_type`、`tray_info_idx`。颜色通常为
RGBA 十六进制，例如红色可能接近 `FF0000FF`，但必须同时核对 `tray_type`。多个槽位匹配时
让用户选择。单色模型的 `--ams-mapping` 应只有一个实际 tray ID；多色模型的映射项数必须
与 `print validate` 报告的 filament 数一致。

## 启动打印

只有 `print-sop.md` 的需求、几何、切片和发布关卡全部通过，且用户已批准最终 artifact 的
SHA-256 后才能进入本节。执行前再次确认目标打印机、盘号、打印盘已清理、bed type、材料和
AMS tray。先预演，再执行一次；失败时默认不要自动重复提交。若用户明确授予同一任务的持续
重试权限，重试前仍须查询状态，确认前次提交未进入 `PREPARE/RUNNING`，且文件 SHA、打印机和
AMS 映射未变化。

LAN：

```bash
bambu-cli --printer lab --dry-run print start --plate 1 ./part.gcode.3mf
bambu-cli --printer lab print start --plate 1 ./part.gcode.3mf
```

H2 系列仍使用同一条 LAN 命令；CLI 会自动改走 BRTC/eMMC。使用 AMS 时映射数量必须与目标
plate 的 filament 数一致：

```bash
bambu-cli --printer h2s-lan print start \
  --plate 1 --ams-mapping 3 --flow-calibration --vibration-calibration \
  ./part.gcode.3mf
```

Cloud + AMS：

```bash
bambu-cli --printer lab --dry-run print start \
  --cloud --plate 1 --bed-type textured_plate --ams-mapping 0 \
  ./part.gcode.3mf

bambu-cli --printer lab --confirm=cloud-print print start \
  --cloud --plate 1 --bed-type textured_plate --ams-mapping 0 \
  ./part.gcode.3mf
```

将示例中的 `0` 替换成 `cloud ams` 返回的实际 tray ID。无 AMS 时使用 `--no-ams`，不要
保留虚假的映射。Cloud 打印会自动生成 companion config 3MF（未传 `--config-file` 时），
默认启用调平；流量、振动校准和延时摄影需显式开启。

Cloud bed type 值：`auto`、`cool_plate`、`eng_plate`、`hot_plate`、
`textured_plate`。它与 `slice --bed-type 'Textured PEI Plate'` 的显示名称不是同一套格式。

## 状态与恢复

LAN 打印后核验：

```bash
bambu-cli --printer lab --json status
bambu-cli --printer lab watch --interval 5
```

Cloud 状态快照：

```bash
bambu-cli --printer lab --json cloud doctor
```

不要仅凭 `print start` 退出码宣称已开始或完成。Cloud-only 场景用 `cloud doctor` 观察
`printer_state`：先出现 `PREPARE`、随后出现 `RUNNING` 才能报告已开始；`FINISH` 才能报告
完成。当前没有 Cloud `watch`，状态字段也不能替代首层或外观检查。

停止 LAN 打印：

```bash
bambu-cli --printer lab --confirm=stop print stop
```

Cloud 复位会停止任务、降温并回零。确认机构安全后执行：

```bash
bambu-cli --printer lab --dry-run cloud reset
bambu-cli --printer lab --confirm=reset cloud reset
```

LAN 回零：

```bash
bambu-cli --printer lab --dry-run home
bambu-cli --printer lab home
```

## CLI 自带确认 token

| 操作 | token |
| --- | --- |
| Cloud 上传并启动打印 | `cloud-print` |
| Cloud 停止、降温并回零 | `reset` |
| 停止 LAN 打印 | `stop` |
| 删除远端文件 | `delete` |
| 发送 G-code | `gcode` |
| 校准 | `calibrate` |
| 重启 | `reboot` |

LAN `print start`、`home`、`move z`、`temps set`、`fans set`、`light on/off`、
`print pause/resume` 没有内建 token，因此 AI 必须自己在执行前获得用户对具体动作的授权。

## 常见问题

- `Unknown command: cloud`：找到的是旧版二进制；运行 `scripts/find_bambu_cli.sh`，或从功能
  分支重新构建。
- Cloud helper/plugin 找不到：确认 Bambu Studio 已安装并登录，检查插件文件，必要时设置
  `BAMBU_STUDIO_PLUGIN`。
- Cloud 序列号缺失：为 profile 配置 `--serial`，或把全局 `--serial` 放在 `cloud` 前。
- `confirmation required`：使用正确 token，不要默认改用 `--force`。
- AMS mapping 数量错误：重新运行 `print validate` 和 `cloud ams`，按 filament 数重新映射。
- 上一次打印状态不明：停止自动流程，要求用户确认屏幕状态和打印盘，之后再决定 stop/reset/home。
- H2S 的 `files list` 返回 `522 session reuse required`：当前 CLI 构建缺少 FTPS 数据连接会话
  复用；更新到包含共享 TLS client session cache 和稳定 `ServerName` 的构建，再做只读验证。
- H2 系列 `files list` 成功但 `STOR` 返回 `553`：不要继续尝试 FTP 路径。H2 LAN 打印应使用
  Bambu Studio networking plugin 的 BRTC/eMMC 本地打印接口；先确认插件存在，并通过只读
  media-ability 探测看到 `emmc`。
- H2 本地上传完成但发送返回 `-4030`：先确认已经收到 `push_status`，再确认 helper 调用了
  `bambu_network_update_cert`、同时请求 LAN/账号绑定两种设备证书，并等待
  `device_cert_installed`。只有 `connected=true` 不足以证明可以发送特权打印命令。
