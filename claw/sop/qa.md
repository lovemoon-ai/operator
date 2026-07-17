# QA Agent SOP

本文档定义 Operator 仓库里通用 QA agent 的工作方式。目标是让 agent 能从版本差异出发，产出可执行测试计划、自动化脚本、真实设备测试结果、失败归因和可审阅的 HTML 报告。

## 适用范围

适用于预发版本、release candidate、PR 合并前验证，以及需要比较“当前 commit vs 上一个版本 commit”的质量评估任务。

Operator 的设备运行测试必须在真实目标设备上执行。不要创建本地 fixture 来替代 Quest/Pico/GlassXR 等设备覆盖。

## 基本原则

- 先理解差异，再写测试。不要只根据用户印象或旧测试计划决定覆盖范围。
- 每个新增功能点必须对应至少一个测试方案：如何设置、预期结果、验证方式。
- 自动化优先，但不要把无法自动化的手测项伪装成已通过。
- 所有测试结果必须落盘，保留原始日志、产物、失败现场和最终报告。
- 失败先归因，分清产品缺陷、测试脚本缺陷、环境/设备状态问题。
- 修改测试脚本时保持可复用，优先参数化，不要依赖临时 patch 源码默认值。
- 重新测试必须覆盖失败点的最小复现，并在通过后回跑相关完整矩阵。
- 最终报告必须明确 PASS/FAIL/NOT RUN，并说明剩余风险。
- 如果因为测试脚本导致测试没有通过，应该自行修改测试脚本，重新运行测试。
- 如果因为功能实现代码的bug导致的测试没有通过，应该如实记录在测试报告中。

## 输入信息

QA agent 开始前应收集：

- 当前分支和 commit 状态：`git status --short --branch`。
- 当前 commit 与上一个版本 commit 的 diff。
- 目标版本号，例如 `v0.1.2`。
- 可用设备序列号，例如 `QUEST_SERIAL`、`PICO_SERIAL`。
- 相关测试入口：`cicd/` 下现有脚本、`xr/Makefile` 构建目标、web/robot 静态检查。
- 版本功能背景：用户说明、commit message、架构文档、代码 diff。
- 如果当前测试环境没有quest或者pico设备连接，应主动提醒我先连接设备，再开始测试。

如果用户没有给出上一个版本 commit，优先从 tag、release branch、`origin/main` 或最近 release 约定中推断；无法可靠判断时要明确说明假设。

## 标准产物目录

每个版本使用独立目录：

```bash
claw/qa-artifacts/<version>/
```

建议结构：

```text
claw/qa-artifacts/<version>/
  qa-test-plan.md
  run_static_checks.sh
  run_<feature>_matrix.sh
  validate_<feature>.py
  run_rerun_conversion_check.sh
  test-report.html
  runs/
    report-YYYYMMDD-HHMMSS/
      static.log
      <test-group>.log
      <test-group>/
        summary.tsv
        <case>/
          tests_*.log
          logcat.log
          validation.log
          validation.json
          pulled device artifacts
```

目录原则：

- `qa-test-plan.md` 记录测试设计。
- `run_*.sh` 是可复用测试脚本。
- `validate_*.py` 做产物级校验。
- `runs/` 保存每次运行，不覆盖历史现场。
- `test-report.html` 指向最新有效报告，并链接本轮日志/产物。

## 工作流程

### 1. 建立版本差异清单

从 commit diff 中提取新增点、行为变化和风险点。

推荐步骤：

```bash
git status --short --branch
git diff --stat <base>..HEAD
git log --oneline <base>..HEAD
```

必要时进一步看具体文件：

```bash
git diff <base>..HEAD -- xr tests web robot claw
rg -n "<feature keyword>" xr tests web robot claw
```

输出格式建议：

```markdown
## 新增功能点

1. RGB codec 支持 H.264/HEVC
   - 涉及文件/模块：
   - 用户可见变化：
   - 风险：

2. Live-feed descriptor 改为实际 codec
   - 涉及文件/模块：
   - 用户可见变化：
   - 风险：
```

注意：不要遗漏“底层依赖更新”“manifest/schema 变化”“测试脚本/CI 默认值变化”“转换工具兼容性”等非 UI 功能点。

### 2. 编写测试计划

保存到：

```bash
claw/qa-artifacts/<version>/qa-test-plan.md
```

每个功能点至少包含：

- 新增点：具体变更是什么。
- 设置：如何触发该功能。
- 自动化：用哪个脚本/命令覆盖。
- 预期：可观测、可校验的结果。
- 手测：无法自动化时写明步骤和判定标准。
- 风险：可能无法在当前环境完成的依赖。

示例：

```markdown
## RGB codec 可选 HEVC / H.264

新增点：
- 设置页新增 Video codec。
- Android encoder 支持 rgb_codec=hevc|h264。

设置：
- Quest/Pico 分别跑 HEVC 和 H.264 smoke。

预期：
- H.264: ffprobe 显示 codec_name=h264，tag 为 avc1/avc3。
- HEVC: ffprobe 显示 codec_name=hevc，tag 为 hev1/hvc1。
- manifest.capture_options.rgb_codec 与期望一致。
```

测试计划必须先给用户讨论机会；如果用户指出遗漏项，回到差异清单重新补齐。

### 3. 编写或修正测试脚本

优先复用 `cicd/` 里的脚本，不要复制大量逻辑。

常见模式：

- 静态检查脚本：聚合 shell syntax、Python syntax、repo 静态 validator。
- 矩阵脚本：按 `device:codec:resolution:fps` 等 case 调用基础脚本。
- 产物 validator：读取 manifest、ffprobe、metadata，做结构化校验。
- 转换检查：对真实产物跑 web/Rerun/转换链路。

测试脚本设计要求：

- 参数化，而不是每个 case 临时修改源码默认值。
- 支持设备 serial、输出目录、capture seconds、skip build/install。
- 每个 case 单独目录，日志完整落盘。
- 失败时保留现场并返回非 0。
- 每个脚本最后写 `summary.tsv`。
- 可通过环境变量在 CI 中复用。

避免：

- 只 patch UI 默认值而不校验运行时实际 options。
- 靠日志关键字假定成功但不验证产物。
- 对新 codec/格式仍写死旧检查，例如固定要求 HEVC。
- 修改后没有恢复源码。

### 4. 运行静态检查

先跑不依赖设备的检查，快速排除脚本语法和静态配置问题。

推荐命令：

```bash
bash claw/qa-artifacts/<version>/run_static_checks.sh 2>&1 \
  | tee claw/qa-artifacts/<version>/runs/report-<stamp>/static.log
```

Operator 当前常用静态检查：

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
bash cicd/03_godot_mujoco_static.sh
```

如修改了 Python 工具或 demo server，也要加：

```bash
python3 -m py_compile <file.py>
python3 <script.py> --self-test
```

### 5. 运行设备测试

设备测试必须确认 ADB 在线：

```bash
adb devices -l
```

典型运行：

```bash
QUEST_SERIAL=<quest-serial> PICO_SERIAL=<pico-serial> \
OUTPUT_BASE=claw/qa-artifacts/<version>/runs/report-<stamp>/ego-matrix \
bash claw/qa-artifacts/<version>/run_ego_codec_matrix.sh \
  2>&1 | tee claw/qa-artifacts/<version>/runs/report-<stamp>/ego_matrix.log
```

长时间运行可以后台执行，但不能结束 agent 回合时还留有必要进程在跑：

```bash
bash <script> > <run>.log 2>&1 &
echo $! > <run>.pid
```

轮询进度：

```bash
ps -p "$(cat <run>.pid)" -o pid=,stat=,etime=,command=
tail -n 120 <run>.log
rg -n '^=>| PASS| FAIL| WARN| ERR|summary' <run>.log
```

设备注意事项：

- Quest/Pico 需要真机佩戴或保持 tracking/guardian 状态稳定。
- Godot Android export 会输出宿主侧 GDExtension warning，不能仅凭 warning 判失败。
- 失败时第一时间保存 `logcat`、build log、install log、pull log、server log。
- Pico body tracking / motion tracking 依赖独立 tracker，默认 CI 不应检查。
- 每轮测试后尽量 reinstall clean APK 或 force-stop，避免 CI APK 残留影响用户设备。

### 6. 产物级校验

不要只看脚本 exit code。必须验证真实产物。

Ego 录制建议检查：

- MP4 存在且大小超过阈值。
- manifest schema、device block、capture options。
- requested options 和 resolved options。
- `stream_confirmations`。
- `ffprobe` stream codec/tag/geometry/packet count/FPS。
- metadata tracks：head pose、rgb_frame_index、depth/body/motion（按预期是否启用）。
- camera intrinsics。
- web/Rerun 转换可读。

Live-feed 建议检查：

- server 收到 session_start/session_end。
- server 收到 RGB CSD、RGB packets、depth、head pose。
- live-pull 连接并渲染结果。
- descriptor 记录实际 codec 和 bitstream format。
- 如果测试 RGB 上色，server 必须实际 decode RGB frames 并产生 RGB-colored points。

### 7. 失败归因和修复

失败处理顺序：

1. 复现失败，保留日志。
2. 找到第一处真实失败，不被后续连锁错误干扰。
3. 判断失败类型：
   - 产品缺陷：功能实际不符合预期。
   - 测试脚本缺陷：脚本假设错误、文件名错误、旧 codec 写死、临时 patch 不可靠。
   - 环境问题：设备未佩戴、tracking lost、adb 断开、端口占用、依赖缺失。
4. 只修最小必要范围。
5. 先跑最小失败 case。
6. 再跑完整相关矩阵。
7. 在报告里写清失败原因、解决方案、重跑结果。

典型经验：

- H.264 功能测试不能继续用 “MP4 contains HEVC RGB stream” 作为基础检查。
- live descriptor 通过不代表 server 已支持该 codec 解码，还要检查 server decoded frames。
- `events.jsonl` / `events.ndjson` 这类文件名变化要兼容真实产物。
- 如果测试脚本需要修改源文件构建 CI APK，必须使用 backup/restore；更好的方案是让基础脚本支持 env 参数。
- 设备启动超时要检查 logcat 是否有 crash、focus 被系统抢占、tracking 未稳定等。

### 8. 生成 HTML 报告

最终报告保存：

```bash
claw/qa-artifacts/<version>/test-report.html
```

报告必须包含：

- 版本、时间、设备 serial、运行目录。
- 总结论：PASS / FAIL / PARTIAL / NOT RUN。
- 测试组结果表。
- 每个 case 的关键确认。
- 失败原因和解决方案。
- 警告说明和剩余风险。
- 指向原始日志、validation log、summary.tsv、产物目录的链接。

报告结论规则：

- 有任意必测项失败：整体 FAIL。
- 有必测项未跑：整体 PARTIAL 或 FAIL，不能写 PASS。
- 只有非必测手测项未执行时，可 PASS 但必须标注残余风险。
- 修复后通过的失败项，要保留“曾失败原因”和“修复后结果”。

### 9. 最终交付前检查

发送最终回复前执行：

```bash
git status --short --branch
bash -n <changed shell scripts>
python3 -m py_compile <changed python scripts>
git diff --check -- <changed files>
find <artifact-root> -type d -name '__pycache__' -print
```

确认：

- 没有必要的后台测试进程仍在运行。
- 没有临时源码 patch 残留，例如 CI auto-start、codec 默认值被固定成测试值。
- 测试产物和报告已落盘。
- 未跟踪但与任务无关的用户文件没有被修改。
- 最终回复包含报告路径、关键测试结果、未完成项或风险。

## Agent 输出模板

测试完成后，最终回复建议包含：

```text
QA 已完成，报告在 claw/qa-artifacts/<version>/test-report.html。

结果：
- Static checks: PASS
- Ego matrix: PASS/FAIL
- Live-feed smoke: PASS/FAIL
- Rerun conversion: PASS/FAIL

修复：
- <脚本/代码修正摘要>

注意：
- <未跑项/残余风险/设备依赖>
```

## 常用命令清单

静态检查：

```bash
bash claw/qa-artifacts/<version>/run_static_checks.sh
```

Ego codec 矩阵：

```bash
QUEST_SERIAL=<quest> PICO_SERIAL=<pico> \
bash claw/qa-artifacts/<version>/run_ego_codec_matrix.sh
```

单 case：

```bash
QA_CASES='quest:h264:1280x960:30' \
QUEST_SERIAL=<quest> \
bash claw/qa-artifacts/<version>/run_ego_codec_matrix.sh
```

Rerun 转换：

```bash
bash claw/qa-artifacts/<version>/run_rerun_conversion_check.sh \
  --input-root claw/qa-artifacts/<version>/runs/latest
```

Live-feed codec smoke：

```bash
QUEST_SERIAL=<quest> \
bash claw/qa-artifacts/<version>/run_live_feed_codec_smoke.sh
```

基础设备测试：

```bash
bash cicd/01_rtsp_test.sh
bash cicd/02_ego_record.sh
bash cicd/03_godot_mujoco_device.sh
bash cicd/04_live_feed_e2e.sh
```

## 特殊注意事项

- XR Android export 只用于构建 APK；不要用 Godot desktop headless runtime 替代 XR 设备测试。
- 首次 Android export 可能超过 10 分钟，长构建可后台运行，但必须追踪 pid 和日志。
- Pico tracker 相关覆盖要显式标注“需要佩戴独立 tracker”，默认 smoke 不测。
- Live-feed H.264 需要 server/decoder 也支持 H.264，不仅仅是 headset 发送 descriptor。
- QA 脚本产物较大，提交前需要确认哪些 `runs/` 目录应纳入版本归档，哪些只作为本地证据保留。
- 测试内容除了新增功能点的测试用例，还应该保证基础设备测试"cicd/"下的测试脚本，都可以通过测试。
