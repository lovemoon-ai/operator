# 连接与环境

## 已观测到的设备布局

这些是历史配置，操作前验证可达性和身份。

| 层 | 地址 / 路径 | 说明 |
|---|---|---|
| SSH 机器人开发计算单元 | unitree@192.168.124.50 | Wi-Fi 地址；远程 Ubuntu 曾可用密钥登录 |
| 同一计算单元内部接口 | eth0 = 192.168.123.164 | DDS 例程在机器人上曾使用 eth0 |
| 底盘控制器 | 192.168.123.163 | Slamtec ares2-ys，REST 1448、Web Portal 80 |
| 主控制地址 | 192.168.123.161 | 记录中 SSH 端口拒绝连接，不能假定可用 |
| C++ SDK | /home/unitree/unitree_sdk2 | 已部署的 SDK 才代表本机实际可编译接口 |
| Python SDK | /home/unitree/unitree_sdk2_python | 不保证包含 G1-D 所有接口 |
| 可用 Python 环境（历史） | /home/unitree/miniconda3/envs/tv/bin/python | 有 cyclonedds、OpenCV、ZMQ；系统 Python 曾缺 DDS 模块 |

固件历史读数：softwareVersion=6.3.1-rc5-3399-cx+20260305，configurationVersion=6.2.2-rtm-ys，hardwareVersion=7.0。版本号不同本身不证明不兼容。不要给定制 ares2-ys 刷普通其他型号固件。

## 跨层参数与输出

用 Python `subprocess.run([...])` 传参数；必须组装远端 shell 字符串时用 `shlex.quote`。在 functions JavaScript 中可用：
```js
const q = s => "'" + s.replace(/'/g, "'\\''") + "'";
```
JSON.stringify 只是序列化，不是 shell 转义；不能将其直接当 shell 引号，尤其含反引号、美元符号和多行内容时。

不要并发修改同一设备控制状态。只读查询可以批量并行。

输出曾只保留约 64 KB 尾部。完整 JSON/JPEG 不一定能一次传完；图像每块 30000 个 base64 字符。在模型内存组装并展示，不在本地落盘。工具 timeout 不等于远端动作已停止。

## 连不上时

SSH timeout、connection refused、认证失败是不同结果。最多做有界的可达性/身份检查；明确无法读到当前机器人状态，不伪造检查结果。
- 不猜密码，不将 Web Portal 密码当 SSH 密码。
- 无 sudo NOPASSWD 时，不通过其他程序漏洞绕过。
- 不改网络接口/IP/防火墙来“试试”，避免切断唯一连接。
- 机器人离线仍可在远程 Ubuntu 整理源码、手册及离线测试；标记未做实机验证。

远程 Ubuntu 本身通常能上网，机器人未必有外网路由；官方文档请求放在 Ubuntu。远程没有 rg 时回退 grep/find，不把缺 rg 当机器人故障。
