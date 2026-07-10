"""
Hello World: 让 Galbot (G1) 的折叠腿依次：
  1) 先「折叠躯干」—— leg 关节回到全折叠位（各关节下限）
  2) 再「直立」   —— leg 关节到官方直立预设（1:3:2 比例）

要点（均来自 SDK 参考与 URDF）：
- leg 关节组共 5 个：leg_joint1-5，单位 rad。URDF 限位：
    leg_joint1 [0.0, 0.9374]   leg_joint2 [0.0, 2.5847]   leg_joint3 [0.0, 2.3262]
    leg_joint4 [-1.5906, 1.5906]  leg_joint5 [-0.1645, 0.1645]
  joint1~3 的下限都是 0.0 —— 全 0 即「腿完全折叠 / 躯干降到最低」的收纳姿态。
- 直立姿态官方预设 = [0.5, 1.5, 1.0, 0.0, 0.0]，恰好满足文档建议的
  leg_joint1:leg_joint2:leg_joint3 = 1:3:2。
- 控制方式：切到 LEG_PVT_CTRL 后用 set_joint_positions(...) 低速点位控制，
  内部生成带速度限制的平滑轨迹，阻塞等待到位或超时。
- ⚠ 折叠会让躯干整体下降；运行前确保机器人上方/四周无障碍、双臂无夹碰风险，
  并已旋开背部急停（否则控制器会返回 FAULT）。
"""

import sys
import time

from galbot_sdk.g1 import GalbotRobot, ControlStatus, G1ControllerName

# 只控制 leg 关节组（5 维）
LEG_GROUP = ["leg"]
# 折叠：尽量低的收纳位，但保持可达。leg_joint1~3 硬下限是 0，但 joint2 实测
# 只能压到 ~0.076 rad（负载/硬限位），下发精确 0 会因“永不收敛”而 TIMEOUT，
# 故取一个略高于地板的可达折叠位（仍保持 1:3:2 比例）。
FOLD_LEG = [0.04, 0.12, 0.08, 0.0, 0.0]   # 折叠 / 收纳（躯干降到最低附近）
# 直立最高：保持 1:3:2，用 leg_joint2≈2.5（其硬上限 2.5847，留 ~0.08rad 余量），
# 即 scale=2.5/3≈0.8333 -> [0.8333, 2.5, 1.6667]。留余量是为了让指令“可达并收敛”，
# 避免顶到硬上限被阻塞硬压而再次触发过流/堵转故障。
STAND_LEG = [0.8333, 2.5, 1.6667, 0.0, 0.0]  # 直立（最高，1:3:2）

SPEED_RAD_S = 0.12                         # 低速，安全
TIMEOUT_S = 30.0
ARRIVE_TOL_RAD = 0.12                      # 到位容差：TIMEOUT 但已足够接近即算到位


def read_leg(robot, tag):
    try:
        pos = robot.get_joint_positions(LEG_GROUP, [])
        print(f"  [{tag}] leg = {[round(float(p), 4) for p in pos]}")
    except Exception as e:  # 读取失败不致命
        print(f"  [{tag}] 读取 leg 关节失败: {e!r}")


def switch_to_leg_ctrl(robot, ready_timeout=15.0, retry_gap=0.5):
    """切到 LEG_PVT_CTRL。WAIT_INITIALIZED 视为“稍后重试”，FAULT 给出急停提示。"""
    deadline = time.time() + ready_timeout
    while True:
        status = robot.switch_controller(G1ControllerName.LEG_PVT_CTRL)
        if status == ControlStatus.SUCCESS:
            print("腿部控制器就绪 (LEG_PVT_CTRL)")
            return
        if "WAIT_INITIALIZED" in str(status) and time.time() < deadline:
            print(f"  控制器未就绪({status})，{retry_gap}s 后重试…")
            time.sleep(retry_gap)
            continue
        if status == ControlStatus.FAULT:
            print("切换腿部控制器返回 FAULT —— 通常是背部急停被按下 / 电机未使能。")
            print("请确认：旋开急停按钮、底盘上电使能、四周无障碍，再重跑。")
        else:
            print(f"切换腿部控制器失败: {status}")
        sys.exit(1)


def leg_arrived(robot, target):
    """读取当前 leg 与 target 比较，全部关节在容差内即视为到位。"""
    try:
        pos = [float(p) for p in robot.get_joint_positions(LEG_GROUP, [])]
    except Exception:
        return False
    if len(pos) < len(target):
        return False
    err = max(abs(pos[i] - target[i]) for i in range(len(target)))
    print(f"  最大关节误差 = {round(err, 4)} rad (容差 {ARRIVE_TOL_RAD})")
    return err <= ARRIVE_TOL_RAD


def move_leg(robot, target, desc):
    print(f"{desc} -> {target} ...")
    status = robot.set_joint_positions(
        target, LEG_GROUP, [], True, SPEED_RAD_S, TIMEOUT_S
    )
    if status == ControlStatus.SUCCESS:
        print(f"  结果: status={status}")
        return
    # TIMEOUT 可能是“到了硬限位附近但没精确收敛”，用位置容差二次判定
    if status == ControlStatus.TIMEOUT and leg_arrived(robot, target):
        print(f"  结果: status={status}，但已在容差内到位，视为成功")
        return
    print(f"  {desc} 失败: status={status}，终止。")
    sys.exit(1)


# 1. 初始化
robot = GalbotRobot()
if not robot.init():
    print("robot.init() 失败！")
    sys.exit(1)
time.sleep(1.0)
print("初始化完成")

try:
    read_leg(robot, "起始")

    # 2. 切换到腿部点位控制器
    switch_to_leg_ctrl(robot)

    # 3. 先折叠躯干
    move_leg(robot, FOLD_LEG, "折叠躯干（回收纳位）")
    read_leg(robot, "折叠后")
    time.sleep(1.0)

    # 4. 再直立
    move_leg(robot, STAND_LEG, "直立（1:3:2 预设）")
    read_leg(robot, "直立后")

    print("全部动作完成")
finally:
    # 5. 无论成败都安全下电、释放资源（避免异常时段错误）
    robot.request_shutdown()
    robot.wait_for_shutdown()
    robot.destroy()
    print("资源已释放")
