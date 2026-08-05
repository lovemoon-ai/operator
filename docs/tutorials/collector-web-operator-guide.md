# Operator 数据采集员手册

适用于 Windows、Ubuntu/Linux 和 macOS。数采员只使用 Agent、网页和 Quest，
不需要登录 Station 服务器，也不需要修改 Operator 代码。

## 开始前

向负责人领取：

- 与电脑系统匹配的 **Operator Collector Agent** 安装包；
- Station 地址（局域网地址或 SSH 登录方式）；
- 本机数据保存目录；
- ModelScope 数据集仓库名，格式为 `组织名/数据集名`。

Quest 必须已安装 Operator、开启开发者模式和 USB 调试。电脑还需要 ADB；如需
生成兼容预览和上传，负责人还应配置 FFmpeg、`ms-hub` 及 ModelScope 登录。
网页“工作站状态”会显示这些工具是否可用。

## 1. 安装 Agent

只执行自己系统对应的一节。

### Windows

1. 双击 `OperatorCollector-<版本>-setup.exe`。
2. 按安装向导完成安装；Agent 会自动启动并加入当前用户的开机启动。
3. Windows 防火墙询问时允许专用网络访问。

检查 Agent：

```powershell
& "$env:LOCALAPPDATA\OperatorCollector\operator-collector.cmd" status
```

### Ubuntu/Linux

```bash
sudo apt install ./operator-collector_<版本>_amd64.deb
systemctl --user enable --now operator-collector
systemctl --user status operator-collector --no-pager
```

### macOS

双击 `OperatorCollector-<版本>.pkg` 并完成安装。内部未签名测试包可能被 macOS
拦截，此时联系负责人处理，不要自行关闭系统安全保护。

安装后注销并重新登录一次；也可以手动加载：

```bash
launchctl bootstrap "gui/$(id -u)" \
  /Library/LaunchAgents/com.lovemoon.operator-collector.plist 2>/dev/null || true
```

检查 Agent：

```bash
/usr/local/bin/operator-collector status
```

## 2. 连接 Station 网站

### 与 Station 在同一局域网

下面以 `10.10.99.89` 为例；实际地址以负责人提供的为准：

```text
http://10.10.99.89:6153/collectors
```

每台电脑第一次使用时，只需执行一次下面的设置。只看自己电脑系统对应的小节。

#### Windows

打开 **PowerShell**，执行：

```powershell
& "$env:LOCALAPPDATA\OperatorCollector\operator-collector.cmd" configure `
  http://10.10.99.89:6153
```

执行成功后，结束任务管理器中安装目录
`%LOCALAPPDATA%\OperatorCollector` 下运行的 `python.exe`，再从开始菜单点击
“启动 Operator Collector”。

#### Ubuntu/Linux

打开终端，执行：

```bash
operator-collector configure http://10.10.99.89:6153
systemctl --user restart operator-collector
```

#### macOS

打开“终端”，执行：

```bash
/usr/local/bin/operator-collector configure http://10.10.99.89:6153
launchctl kickstart -k "gui/$(id -u)/com.lovemoon.operator-collector"
```

设置成功时会看到：

```text
Station URL saved: http://10.10.99.89:6153
```

以后只有 Station 地址变化、改用其他 Station，或切换为 SSH 隧道时，才需要重新执行
`configure`。

### 通过公网 SSH 连接

保持下面的终端窗口一直打开：

```bash
ssh -N -L 6153:127.0.0.1:6153 4090station
```

Agent 保持默认地址 `http://127.0.0.1:6153`，浏览器打开：

```text
http://127.0.0.1:6153/collectors
```

### 第一次配对

Agent 首次启动会打开配对页。登录网站并批准这台电脑，回到“数据采集”页面，
确认工作站显示“在线”。配对只需完成一次。

在“工作站设置”中填写并保存：

- **数据保存目录**：导入后数据存放的位置；
- **本地已有数据集目录**：不连接 Quest 时要扫描的位置；
- **Quest 录制根目录**：不知道时可先留空，连接后再确认；
- **ModelScope 数据集仓库**：必须是 `组织名/数据集名`，不能填本机路径。

## 3. 连接 Quest 并采集

1. 用可传输数据的 USB 线连接 Quest。
2. 戴上 Quest，允许 USB 调试。
3. 检查连接：

   ```text
   adb devices -l
   ```

   必须显示 `device`；`unauthorized` 表示还没有在头显中授权。
4. 网页确认工作站“在线”、Quest“已连接”，点击“启动 Ego”。
5. Ego 打开后可以拔掉 USB；录制不依赖电脑或 Wi-Fi。
6. 停止录制并等待 Quest 明确提示保存完成，再重新连接 USB。
7. 点击“扫描 Quest”。如不知道路径，可执行：

   ```text
   adb shell "find /sdcard -type f -name '*.mp4' 2>/dev/null"
   adb shell "find /sdcard -type f -name 'manifest.json' 2>/dev/null"
   ```

   把 MP4 所在目录填入“Quest 录制根目录”，保存后重新扫描。

## 4. 导入、检查、标签和上传

1. 在“Quest 中的录制”找到刚录制的数据，点击“读取并校验”。
2. 如确实需要释放 Quest 空间，可勾选“校验并保存成功后删除 Quest 原数据”。
   只有电脑端校验成功后才会删除对应源数据。
3. 等待“校验通过”，检查前两分钟内每 20 秒抽取的预览图、manifest 和 sidecars。
4. 输入短标签，例如 `wash`，点击“保存标签并重命名”。目录会变成类似：
   `20260804_wash_020030902`。
5. 确认网页显示 ModelScope“已登录”，勾选一条或多条已标记数据，再点击
   “批量上传到私有仓库”。
6. 等待任务显示“已完成”；失败时保留本地数据并把错误截图交给负责人。

不连接 Quest 时，填写“本地已有数据集目录”，点击“扫描本地数据”，后续预览、
标签和上传步骤完全相同。

> 不要只复制 MP4，也不要手动修改或删除 manifest、sidecars 和 Quest 原文件。

## 5. 停止或卸载 Agent

卸载 Agent 不会删除“数据保存目录”里的数据。

### Windows

临时停止：在任务管理器中结束安装目录
`%LOCALAPPDATA%\OperatorCollector` 下运行的 `python.exe`。

彻底卸载：打开“设置 → 应用 → 已安装的应用”，卸载 **Operator Collector**。
如需同时清除配对信息，再删除：

```text
%APPDATA%\Operator Collector\config.json
```

### Ubuntu/Linux

```bash
systemctl --user disable --now operator-collector
sudo apt remove operator-collector
```

如需同时清除配对信息：

```bash
rm -f "$HOME/.config/operator-collector/config.json"
```

### macOS

临时停止：

```bash
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.lovemoon.operator-collector.plist" \
  2>/dev/null || true
launchctl bootout "gui/$(id -u)" \
  /Library/LaunchAgents/com.lovemoon.operator-collector.plist \
  2>/dev/null || true
```

彻底卸载：

```bash
rm -f "$HOME/Library/LaunchAgents/com.lovemoon.operator-collector.plist"
rm -f "$HOME/Library/Application Support/Operator Collector/bin/operator-collector"
sudo rm -f /Library/LaunchAgents/com.lovemoon.operator-collector.plist
sudo rm -f /usr/local/bin/operator-collector
sudo pkgutil --forget com.lovemoon.operator-collector
```

如需同时清除配对信息：

```bash
rm -f "$HOME/Library/Application Support/Operator Collector/config.json"
```

## 常见问题

- **工作站离线**：确认 Agent 已启动、Station 地址正确，并刷新网页。
- **Quest 未连接**：重新插线，在 Quest 内允许 USB 调试。
- **扫描不到数据**：确认录制已保存，并检查 Quest 录制根目录。
- **FFmpeg/ModelScope 未找到**：联系负责人配置，原始数据仍可正常读取和保存。
- **校验或上传失败**：不要删除任何原文件，保存错误截图并联系负责人。
