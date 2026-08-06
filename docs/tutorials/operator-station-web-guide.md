# Operator Station 网页启动手册

Station 负责网页、Agent 配对、任务记录和预览。完整数据保存在各数采电脑，
Station 只保存数据库、元数据和网页预览。

- SSH 主机：`4090station`
- 仓库：`/home/evophys/code/operator-github`
- 服务：`operator-web-station.service`
- 端口：`6153`

## 第一次安装或更新

```bash
ssh 4090station
cd /home/evophys/code/operator-github
bash web/deploy/station/install.sh
```

脚本会安装依赖、构建网页、保留现有配置和数据，并重启服务。为了让用户退出登录
后服务仍能自动启动，管理员只需执行一次：

```bash
sudo loginctl enable-linger evophys
```

## 日常管理

```bash
systemctl --user status operator-web-station --no-pager
systemctl --user restart operator-web-station
systemctl --user stop operator-web-station
journalctl --user -u operator-web-station -f
```

## 打开网页

同一局域网：

```text
http://10.10.99.89:6153/collectors
```

公网访问必须使用 SSH 公钥和隧道：

```bash
ssh -N -L 6153:127.0.0.1:6153 4090station
```

保持终端打开，再访问 `http://127.0.0.1:6153/collectors`。不要把 6153 端口直接
暴露到公网。

## 配置和数据

- Station 配置：`~/.config/operator-station/station.env`
- SQLite 数据库：`~/operator-data/operator.db`
- 网页预览：`~/operator-data/collector-previews`
- ModelScope 私有仓库：`chenghy666/test`

ModelScope token 只写入 `station.env` 的 `OPERATOR_MODELSCOPE_TOKEN`，不要写入
代码、文档、网页、命令参数或截图。保存后执行：

```bash
chmod 600 ~/.config/operator-station/station.env
systemctl --user restart operator-web-station
```

浏览器接口、任务参数和日志不会返回 token。当前部署使用“数采 ID + 6 位 PIN”
登录；某个 ID 首次登录时自动创建，PIN 只以 scrypt 加盐哈希保存。Agent、任务和
数据条目均按账号隔离。旧版共享的 `Dev User` 数据仍保留在数据库中，但普通数采账号
不可见，也不会被自动删除或分配。

当前局域网部署仍使用 HTTP，只适合可信局域网；公网必须走 SSH 隧道，或先部署
HTTPS。

## Agent 接入

```text
operator-collector configure http://<Station局域网IP>:6153
```

重启 Agent，使用数采 ID 和 PIN 登录网页后批准配对。0.1.4 安装包已经包含 ADB、FFmpeg、Python 和
ModelScope 上传组件，无需数采员单独配置。

## 故障检查

```bash
systemctl --user is-active operator-web-station
journalctl --user -u operator-web-station -n 100 --no-pager
curl -I http://127.0.0.1:6153/collectors
ss -ltn | grep ':6153'
```

- 服务不是 `active`：查看日志后重新运行安装脚本。
- Agent 离线：确认 Agent 的 Station 地址、网络或 SSH 隧道。
- 磁盘不足：检查 `~/operator-data`，不要删除 SQLite 文件。
