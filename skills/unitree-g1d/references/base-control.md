# 底盘：定距移动与停止

## 正确接口

官方 G1-D：`unitree::robot::g1::AgvClient`，`Init()` 后使用：
- `Move(vx, 0, vyaw)`：纵向速度及转向，横移参数不支持。
- `Move(0, 0, 0)`：停止命令。
- 对机器人内执行的 DDS 程序，历史网卡 eth0，domain 0。

官方头文件声称 vx 单位 m/s、vyaw 单位 rad/s，但这台机器的低速反馈与输入曾明显不一致。**不能把某次输入→速度映射当标定值。** 本次输入 0.04 曾触发实际速度 >0.08 的停止保护；输入 0.010 曾产生约 0.02–0.06 m/s，输入 0.008 曾不动。这些只是历史观测，不是建议直接复用的速度。

官方源与示例见 sources.md。发布一次成功回执不证明电机动了。

## 读取实际状态

- DDS `rt/agv/odom`，类型 `nav_msgs::msg::dds_::Odometry_`，头文件 `unitree/idl/ros2/Odometry_.hpp`。
- 不把 `SportModeState` 类型套到 `odommodestate` 猜解结构。
- REST `/api/core/motion/v1/speed` 返回实际速度。
- REST `/api/core/slam/v1/localization/pose` 与 `.../odopose` 的原点不一定相同，不能跨源混算。
- 定距控制选择一种经过验证、不中途重置的里程计源。地图定位质量历史为 0，因此当时没有使用地图目标 MoveTo。
- 位姿时间戳必须前进、字段有限、四元数合理，并检查接收年龄；仅订阅到了主题不代表数据有效。

起点 (x0,y0,yaw0)，当前 (x,y)：
```text
forward = (x-x0)*cos(yaw0) + (y-y0)*sin(yaw0)
lateral = -(x-x0)*sin(yaw0) + (y-y0)*cos(yaw0)
remaining = target - forward
```
负目标表示相对于该起点的后退；后退需要检查后方空间，不能复用前方扫描条件。

## 实施流程

- 当前 health 无驱动错误、急停、刹车释放等阻断；读实际速度，并确认已有控制者是否还在操作。
- 检查实际行驶方向的扫掠空间，包括机器人上半身/负载外廓。激光雷达只覆盖其扫描范围，不能推定 3D 空间全清。
- 用户此前允许忽略深度断连警告，是这次受看护低速遥控的上下文，不是自动导航/任何新任务的永久豁免。
- 起步前确认能发送停止、收到新鲜反馈，取得单一控制锁，记录绝对起点、目标、容差、速度限制、截止时间、告警策略。
- 控制循环必须有限时，带停止收尾；无进展用滚动窗口判断，不只在启动 5 秒时检查一次。
- 监测前向/侧向/偏航变化、实测速度、障碍及数据年龄。失联、异常、SIGINT/SIGTERM 均走停止流程。
- 设置与动作相符的航向控制或偏差保护。正向速度、零角速度并不保证真实航向恒定。
- 临近目标考虑停止后的滑行。命令未产生运动时不能盲目持续等待或跳到大速度。
- 停止后重复有限次零速指令，检查有效回执和实际零速度，再独立采样确认停稳。
- 超时或异常时报告已完成距离，先定位异常再决定继续；不是抬高阈值来规避保护。

历史临时程序采用：位姿接收年龄 <0.25s、速度上限 0.08m/s、侧偏 0.025m、偏航 0.08rad、8 次间隔40ms零速停止。**这不是厂家安全限值/通用参数，也不是完整安全控制器。** 历史 0.35/0.40m 半宽和 0.60/0.85m 障碍距离只针对当时短距离场景；新姿态/新距离重新评估。

无深度数据时，雷达“没发现障碍”不能替代人员确认上方/低处空间。多次重试仍出现控制竞争或异常反馈时暂停并澄清真实输入来源。

## 续走与验收

同一条“前进 1 米”被保护中断，续走只能补 **1 米减去原起点累计位移**；不能从新起点再走 1 米。若机器人被人工移动/转向，先澄清原目标是否仍有效，不能沿旧方向自动补走。

上一次已完成的命令后，用户新发“再前进 1 米”则取新起点，与同一次任务续走不同。

每次保存独立目录和报告：run_id、原始起点/朝向、控制段起点、最终位姿/速度、累计前向与侧向位移、回执、保护原因、前后照片路径和接收时间。照片间有人工移动或时间跨度时如实说明。

## 历史代码：只作参考，绝不直接执行

机器人目录：/home/unitree/ws/g1d-30cm-capture
文件：move5.cpp、move30.cpp、move30_slow.cpp、move30_trim.cpp、move1m.cpp，以及 capture_move*.py。
- 一些续走源码写死了当时 x/y/yaw；一些包装器固定引用 20260908 的旧 before.jpg。
- 部分示例是特定段落 deadline、目标距离和阈值，不能改文件名就当新任务。
- 使用前读完整源码与包装器，移除旧起点/旧照片，重新审核目标和停止路径。
- 不把旧二进制的名字当作功能证明。

历史构建方式（仅当实际 SDK 路径与架构验证一致）：
```bash
c++ -std=c++17 -O2 \
 -I/home/unitree/unitree_sdk2/include \
 -I/home/unitree/unitree_sdk2/thirdparty/include \
 -I/home/unitree/unitree_sdk2/thirdparty/include/ddscxx \
 CONTROL_SOURCE.cpp \
 -L/home/unitree/unitree_sdk2/thirdparty/lib/aarch64 \
 -Wl,-rpath,/home/unitree/unitree_sdk2/thirdparty/lib/aarch64 \
 /home/unitree/unitree_sdk2/lib/aarch64/libunitree_sdk2.a \
 -lddsc -lddscxx -lpthread -o CONTROL_BINARY
```
编译成功只是构建检查，不是运动验证；本 skill 不附带自动执行的实机移动脚本。
