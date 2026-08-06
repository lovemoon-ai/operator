# Operator Station 网页启动手册

Station 负责网页、Agent 配对、任务记录和预览。完整数据保存在各数采电脑，
Station 只保存数据库、元数据和网页预览。

本文适用于：

- SSH 主机：`4090station`
- 仓库：`/home/evophys/code/operator`
- 服务：`operator-web-station.service`
- 端口：`6153`

## 第一次安装或更新

```bash
ssh 4090station
cd /home/evophys/code/operator
bash web/deploy/station/install.sh
```

脚本会安装依赖、构建网页、创建配置并启动 systemd 用户服务。重复运行可用于更新，
不会删除现有配置和数据。

为了让用户退出登录后服务仍能自动启动，管理员只需执行一次：

```bash
sudo loginctl enable-linger evophys
```

## 日常启动和检查

```bash
systemctl --user start operator-web-station
systemctl --user status operator-web-station --no-pager
```

常用管理命令：

```bash
systemctl --user restart operator-web-station
systemctl --user stop operator-web-station
journalctl --user -u operator-web-station -f
```

网页代码更新后，重新运行安装脚本即可完成构建和重启：

```bash
cd /home/evophys/code/operator
bash web/deploy/station/install.sh
```

## 打开网页

同一局域网内使用 Station 的实际局域网 IP，例如：

```text
http://10.10.99.89:6153/collectors
```

公网访问必须使用 SSH 公钥和本地隧道：

```bash
ssh -N -L 6153:127.0.0.1:6153 4090station
```

保持隧道终端打开，然后访问：

```text
http://127.0.0.1:6153/collectors
```

不要在路由器上转发 `6153`，也不要把该端口直接暴露到公网。

## 配置和数据

- Station 配置：`~/.config/operator-station/station.env`
- SQLite、预览等运行数据：`~/operator-data`
- 网页端口：环境变量 `PORT`，默认 `6153`

ModelScope 上传固定使用私有仓库 `chenghy666/test`。负责人只需把 token 写入：

```text
~/.config/operator-station/station.env
```

变量名为 `OPERATOR_MODELSCOPE_TOKEN`。不要把 token 写入代码、文档、网页设置、
命令参数或截图。保存后执行：

```bash
chmod 600 ~/.config/operator-station/station.env
systemctl --user restart operator-web-station
```

Station 只会通过已配对 Agent 的认证心跳下发凭据；浏览器接口、任务参数和日志都
不会返回 token。当前局域网部署是 HTTP，因此只允许在可信局域网使用；公网或不
可信网络必须走 SSH 隧道，或先配置 HTTPS。

当前部署使用 `AUTH_BYPASS=1`，只适用于可信局域网和 SSH 隧道。若要公开提供
HTTPS 服务，必须先配置正式 SSO、HTTPS Cookie 和反向代理。

## Agent 接入

局域网 Agent 首次配置：

```text
operator-collector configure http://<Station局域网IP>:6153
```

重启 Agent 后，在浏览器打开的配对页批准该电脑。后续数据目录、Quest 路径和
预览操作均在 `/collectors` 页面设置。0.1.3 安装包已经包含 ADB、FFmpeg、Python
运行时和 ModelScope 上传组件；仓库固定为 `chenghy666/test`。

远程 Agent 通过 SSH 隧道连接时保持默认地址：

```text
http://127.0.0.1:6153
```

## 故障检查

```bash
systemctl --user is-active operator-web-station
journalctl --user -u operator-web-station -n 100 --no-pager
curl -I http://127.0.0.1:6153/collectors
ss -ltn | grep ':6153'
```

- 服务不是 `active`：查看日志后重新运行安装脚本。
- Station 本机可访问、其他电脑不可访问：检查局域网 IP、防火墙或 SSH 隧道。
- Agent 显示离线：先确认 Agent 使用的 Station 地址与网页地址一致。
- 磁盘空间不足：检查 `~/operator-data`，不要直接删除 SQLite 文件。
