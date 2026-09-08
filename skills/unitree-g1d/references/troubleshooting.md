# 故障、维护和关机

## 底盘只读接口

通过机器人访问 http://192.168.123.163:1448；Python urllib 使用 ProxyHandler({}) 避免将机器人私网请求发到代理。
- /api/core/system/v1/robot/health
- /api/core/system/v1/robot/info
- /api/core/motion/v1/speed
- /api/core/system/v1/power/status
- /api/core/sensors/v1/masks
- /api/core/system/v1/laserscan
- /api/core/slam/v1/localization/pose
- /api/core/slam/v1/localization/odopose
- /api/core/slam/v1/localization/quality

保留完整 baseError 和布尔标志；本机曾 hasDepthCameraDisconnected=false 但 baseError 仍有深度警告。不能只读一个布尔位，也不能把 DDS 的 state=4 当故障码。

| 报警 | 十六进制 / 十进制 | 本次经验 |
|---|---|---|
| system emergency stop | 0x02010100 / 33620224 | 真正急停会阻断驱动；Unitree API仍可能返回0 |
| motor brake released | 0x02010700 / 33621760 | 刹车释放开关需现场恢复正常位置 |
| depth camera disconnect | 0x01040A00 / 17041920 | level=1；会间歇消失/出现，尚未解决 |

急停/刹车物理开关不能通过此软件流程拨动；用户说已解除后读当前状态再继续。不要 DELETE 报警或禁用保护来绕过驱动锁。用户承认人工遥控解释了历史“非命令移动”，不代表未来所有异常都由遥控造成。

## 深度报警：已排除与未证实

本次 /sensors/v1/masks=[]。调用 depth/:enable {enable:true} 成功；软重启导航服务成功，但报警仍反复出现。没有更改相机标定、安装相机驱动或刷固件。

正确后续是原厂导航健康状态、内部相机/驱动/链路日志及维护资料。用户访问不到两颗相机是产品设计限制。一般 USB供电、连接、驱动、配置都是可能分支，尚不能确定其一；不要把另一型号手册当G1-D接线图，不盲目修改 teleimager 或装 RealSense 驱动。

## Web Portal

机器人内访问 http://192.168.123.163/。
官方公开默认凭据 admin / admin111，本次已验证有效。它只适用于未改密码的后台，不是SSH/系统密码。
- 官方登录：POST /service/system/login，表单 name、pw。
- 登录需要cookie；保存到远程专用目录并限制0600，勿打印cookie、加入skill、打包或提交。
- 身份验证失败后不枚举其他默认密码。
- /admin/diagnosis.html：诊断界面。
- POST /service/system/diagnosis，表单 diagnosis=enable/disable；完成后恢复原状态。
- GET /service/system/diagnosis/status；GET /service/system/diagnosis/msg；后者可能返回 JSON null，应正常处理。
- 通用诊断图层不保证向用户暴露 G1-D 底盘深度流，见 cameras.md。
- /admin/root.html 的 Debug Access 要求设备专用 Challenge Response；普通后台密码不能替代。厂家权限/令牌未取得就停止该分支，不绕过。
- 不替用户给厂家发邮件/工单，除非明确授权。

远程Ubuntu可用只绑定loopback的SSH隧道：
```bash
ssh -M -S /home/duino/ws/g1d-depth-diagnostics/web-tunnel.sock \
 -fN -o BatchMode=yes -o ExitOnForwardFailure=yes \
 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
 -L 127.0.0.1:18080:192.168.123.163:80 unitree@192.168.124.50
```
先检查已有同目的隧道/端口，勿覆盖其他用途。浏览器入口 http://127.0.0.1:18080/login.html 在**远程Ubuntu**，不是用户本地电脑的localhost。诊断原目录可能有cookie，不整体打包。

## 重启

仅在用户请求维护所需且已确认底盘停止、没有进行中操作时使用：
POST /api/core/system/v1/power/:restartmodule
JSON {"mode":"RestartModeSoft"} 只重启导航服务。
其他枚举 RestartModeHard、RestartModeBase 影响更大，不能随意替代。
本次软重启约19秒恢复接口，期间超时/HTTP500与短暂雷达掉线，随后雷达恢复；深度报警仍在。等待并验证，不在超时后盲目重发多次重启。重启后重新建立位姿参考，不沿旧里程计继续运动。

## 软件关机

用户明确请求关机时，本次成功用：
POST /api/core/system/v1/power/:shutdown
JSON {"shutdown_time_interval":0,"restart_time_interval":0}
返回HTTP200 true，随后机器人SSH离线。此证据说明软件关机链路执行；仅SSH离线本身不能证明所有电源轨均断电。
关机前收尾正在进行的控制及负载支撑。若请求只谈某个软件进程，不自动关闭整机。普通SSH reboot/shutdown缺权限时不要猜sudo密码。

## 旧资料位置（可能不再存在）

远程Ubuntu /home/duino/ws/g1d-depth-diagnostics：
diagnostic-results.json、live-diagnosis-summary.json、live-diagnosis.jsonl.gz、final-status.json、research/findings.md。
其中早期README/findings可能把“未读到深度帧”当故障证据；以本技能保留的用户纠正为准。当前警告状态须重新读取，不能用旧final-status.json冒充现在。
