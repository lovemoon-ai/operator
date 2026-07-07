---
name: galbot-g1
description: Galbot G1 真机（数采·训练·部署）参考资料与 Hello World 示例。当用户需要在 Galbot G1 上采集遥操数据、把 MCAP 转 LeRobot 训练、用 Galbot SDK 读取相机/同步观测、控制关节/夹爪/底盘或导航、部署 VLA 推理客户端，或跑通/排查 G1 Hello World（网络、SSH、SDK 依赖、WAIT_INITIALIZED 等）时使用。
---

# Galbot G1

Galbot G1 真机使用的参考资料集合，覆盖从**数据采集 → 数据转换与训练 → 真机部署**的完整流程，以及在真机上跑通第一个程序（Hello World）的实操与踩坑排查。

## 能力范围

- **认识机器人**：G1 规格与安全、关节组（6 组 / 23 自由度）、传感器、开箱开机联网、系统架构（应用层 / Galbot SDK / Embosa 通信 / HPU·Orin / XCU / 硬件层）。
- **数据采集**：遥操主从臂硬件连接与启动、手柄按键映射、遥操作流程与急停、MCAP 采集产物。
- **数据转换与训练**：`galbot-mcap2lerobot` 把 MCAP 转成 LeRobot 数据集、23 维 state/action 定义、数据集目录结构、可接入的训练框架。
- **真机部署 / SDK**：部署方式对比，核心 SDK 接口（`get_rgb_data` / `get_depth_data` / `get_synced_observation` / `set_joint_positions` / `set_gripper_command` / `set_joint_commands`）、建图导航、服务端+客户端 WebSocket 部署架构。
- **上手与排查**：底盘运动 Hello World 脚本，以及网络、SSH、Python/SDK 依赖、`WAIT_INITIALIZED`、段错误等常见问题的解决方案。
- GalbotSDK: https://github.com/GalaxyGeneralRobotics/GalbotSDK
- Galbot-G1 urdf: https://github.com/GalaxyGeneralRobotics/galbot_one_golf_description

## reference/ — 参考文档

- **`reference/real_robot_guide.md`** — 真机数采·训练·部署完整说明（Workshop Deck 转写）。查规格/关节组、遥操按键、MCAP→LeRobot 转换、SDK API 参数与示例、部署架构时看这份。
- **`reference/galbot_g1_hello_world_troubleshooting.md`** — G1 跑通 Hello World 踩坑记录。含环境速览与 11 个常见问题（网络不通、SSH 免密、Python 版本、SDK 部署与依赖、`WAIT_INITIALIZED` 竞态、段错误等）及一次性环境搭建脚本。真机部署遇到报错先查这份。

## scripts/ — 可运行示例

- **`scripts/hello_world_move_forward.py`** — 底盘运动 Hello World。依次执行「前进 5cm → 后退 5cm → 原地顺时针旋转 30°」，演示 `GalbotRobot` / `GalbotNavigation` 初始化、切换 `CHASSIS_POSE_CTRL` 控制器、`relocalize` + `is_localized` 就绪判定、`move_straight_to` 相对位姿运动，并处理 `WAIT_INITIALIZED` 重试与资源安全释放。
  - 运行前确保机器人周围无障碍（不做避障），并已按 troubleshooting 文档配好 SDK 环境。
  - 在机器人 xpu 上运行：`python3 scripts/hello_world_move_forward.py`
