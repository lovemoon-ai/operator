# Quest 录制数据兼容与删除功能说明（Agent 0.1.6）

本文记录 Operator Collector Agent 0.1.6 对 Quest 录制数据扫描、导入和删除流程的
调整，供后续开发、部署和排查使用。数采员的日常操作仍以
`collector-web-operator-guide.md` 为准。

## 变更目标

- 保留新版 Quest APK 将录制写入 `/sdcard/DCIM/SpatialMP4` 的默认行为；
- 同时识别旧版使用的 `/sdcard/Movies/SpatialMP4`；
- 不迁移、不覆盖用户填写的 Quest 自定义扫描目录；
- 兼容新旧两种录制目录结构；
- 从网页精确删除指定的一条 Quest 录制；
- 录制必须先导入电脑，才能预览、打标签并上传 ModelScope。

## 扫描目录

Agent 每次扫描 Quest 时按下面顺序检查目录，并自动去重：

1. 用户填写的“Quest 自定义扫描目录”（如果有）；
2. `/sdcard/DCIM/SpatialMP4`；
3. `/sdcard/Movies/SpatialMP4`。

自定义目录只作为额外扫描位置保存。升级 Agent、保存设置或重新扫描都不会把它自动
改成 DCIM 或 Movies，也不会在两个标准目录之间迁移文件。

## 兼容的数据结构

### 新格式：录制文件都在 session 目录内

```text
/sdcard/DCIM/SpatialMP4/<session_id>/
├── <session_id>.mp4
├── manifest.json
└── 其他可选文件
```

新格式不强制要求 `sidecars/`。manifest 引用的可选文件在导入电脑后保持原有相对
路径，避免破坏引用关系。

### 旧格式：MP4 与 session 目录并列

```text
/sdcard/Movies/SpatialMP4/
├── <session_id>.mp4
└── <session_id>/
    ├── manifest.json
    └── sidecars/
```

旧格式的 sidecars 会完整导入到电脑端数据集的 `sidecars/` 目录。

只有同时找到目标 MP4 和 `manifest.json` 的录制才标记为完整。录制中的
`.partial.mp4` 会被忽略；不完整录制不能导入，也不能从网页删除。

## 导入、预览和上传流程

```text
Quest 扫描 → 导入电脑并校验 → 生成预览 → 打标签/重命名 → 上传 ModelScope
```

- Agent 使用扫描结果中的实际根目录、结构类型和源路径导入，不再仅依靠 session ID
  猜测位置；
- 新旧格式都会整理为电脑端可管理的数据集；
- 网页预览和 ModelScope 上传只读取电脑端数据；
- 0.1.6 暂不支持 Quest 直接上传 ModelScope；
- 断开 Quest 后，已经导入电脑的数据仍可继续预览、标记和上传。

## Quest 删除行为

网页提供两种删除方式：

1. 导入时勾选“校验并保存成功后删除 Quest 原数据”：只有电脑端复制及校验全部成功
   后才删除源数据；
2. 在“Quest 中的录制”列表点击“删除”：确认后直接永久删除该条 Quest 数据。

删除操作遵循以下限制：

- 必须由 0.1.6 或更新版 Agent 执行；
- 必须使用本次扫描返回的确切根目录和结构类型；
- 新格式只删除该条录制的 session 目录；
- 旧格式只删除该条录制对应的 MP4 和同名 session 目录；
- 不使用宽泛目录、通配符或模糊 session 匹配；
- 删除完成后自动重新扫描 Quest，及时刷新网页列表；
- 列表中的直接删除不可恢复，不能替代“先导入再删除”的日常流程。

## 升级与部署

Station 网页和 Collector Agent 必须配套更新。只升级 Station、但电脑仍运行 0.1.5
时，新扫描和 Quest 删除任务不能完整执行。

升级 Agent 后检查版本：

```text
operator-collector --version
```

应显示 `0.1.6`。安装新版会替换 Agent 程序；原有 Station 地址、配对信息和数据目录
配置仍保存在用户配置目录中。Station 更新后执行：

```bash
cd /home/evophys/code/operator-github
bash web/deploy/station/install.sh
curl -fsS http://127.0.0.1:6153/healthz
```

## 验证结果与边界

本次版本已完成：

- Collector Agent 单元测试 18 项；
- Station Web 测试 3 项；
- Next.js 生产构建；
- Python 静态编译检查；
- Station 服务部署及 `/healthz` 检查；
- macOS、Windows、Linux 0.1.6 安装包构建和版本校验。

自动化测试覆盖双标准目录、自定义目录、新旧结构、无 sidecars 的新格式、可选文件
相对路径保留以及精确源删除。真实 Quest 的 ADB 扫描和删除仍必须在设备连接、USB
调试已授权时做最终真机确认。

## 主要代码位置

- `collector-agent/src/operator_collector/jobs.py`：扫描、导入、校验和删除；
- `collector-agent/src/operator_collector/agent.py`：任务执行后刷新 Quest 扫描状态；
- `web/app/lib/collector-agents.ts`：Station 任务类型与状态更新；
- `web/app/app/collectors/CollectorDashboard.tsx`：路径说明、格式展示和删除入口；
- `collector-agent/tests/test_jobs.py`：新旧格式与删除安全测试。
