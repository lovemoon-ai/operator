# G1-D 双臂 MuJoCo 遥操沙箱

这个目录把真机从调试链路中移除，用一个固定底盘的 G1-D 上半身模型验证：

- 左右 Grip 分别锁存对应手柄和机器人末端参考位姿；
- OpenXR `(右, 上, 后)` 到机器人 `(前, 左, 上)` 的坐标变换；
- 以按下 Grip 时的头部 yaw 归一化移动方向；
- 两条 7-DoF 手臂独立 IK、关节限位和速度限制；
- Grip 首帧保持原控制目标，避免重力下坠；
- 可选重力前馈（MuJoCo `qfrc_bias`，对应 Unitree 官方方案中的 RNEA `tau_ff`）。

模型直接使用 Unitree 官方 BSD-3-Clause G1 29-DoF MJCF 与 mesh（`assets/g1/`，来源 `unitreerobotics/unitree_mujoco`，提交 `1eb6642e3f3fdfb7fb13a9794fd6a2dd93ea0e7d`，许可证见 `assets/g1/LICENSE`）。派生模型 `assets/g1/g1_dual_arm.xml` 去掉了浮动基座：pelvis 固定在世界中，腿和腰由位置执行器保持直立，只驱动两条 7-DoF 手臂；`g1_29dof_official.xml` 是未修改的官方原件，便于对照。

## 自动验证

```bash
cd examples/unitree-g1d/mujuco
make test
```

测试不需要头显，会覆盖零位移 Grip、重新 Grip 无跳变、坐标轴、双臂同时前移，以及单臂操作时另一条手臂保持。

## 连接 Quest

```bash
cd examples/unitree-g1d/mujuco
make run
```

操作方式：

- 按住左/右 Grip：控制对应机械臂；
- 同时按住两个 Grip：控制双臂；
- 左手柄 X：准备姿势（肘稍外开、小臂朝前）；
- 左手柄 Y：初始化姿势（双臂自然下垂）；
- Trigger 当前只记录在命令中，简化模型不模拟 BrainCo 手指。

无图形环境使用 `make run-headless`。如果头显不在本机自动发现的网段，可运行：

```bash
uv run python teleop.py --discovery-target 192.168.124.255
```

`--no-gravity-compensation` 可关闭重力前馈，用于复现纯 PD 的下沉并检查 Grip 目标连续性。
