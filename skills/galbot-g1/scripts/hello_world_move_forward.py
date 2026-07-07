"""
Hello World: 让 Galbot (G1) 底盘依次执行：
  1) 前进 5 厘米
  2) 后退 5 厘米
  3) 原地顺时针旋转 30 度

要点：
- move_straight_to 的目标位姿是相对“当前 base_link”的（odom 系，单位米），
  格式 [x, y, z, qx, qy, qz, qw]，不做避障——运行前请确保周围无障碍。
  由于每段都相对当前位姿，顺序执行即可自然叠加。
- 旋转方向：绕 +Z 轴，俯视逆时针为正 yaw；顺时针即负 yaw。
  顺时针 30° => yaw = -30°，四元数 [0,0,sin(yaw/2),cos(yaw/2)]。
- 运动前导航子系统必须先“就绪”(is_localized)，否则指令会被拒
  并返回 (False, 'WAIT_INITIALIZED')。
"""

from galbot_sdk.g1 import GalbotNavigation, GalbotRobot
from galbot_sdk.g1 import ControlStatus, G1ControllerName
import numpy as np
import time
import sys


def move(nav, target, desc, timeout=20, ready_timeout=15, retry_gap=0.5):
    """执行一段相对运动并检查返回值。

    注意：is_localized() 为 True 只代表“定位就绪”，导航运动执行器可能仍在
    异步初始化，此时下发指令会返回 (False, 'WAIT_INITIALIZED') —— 指令并未
    执行（机器人没动），所以可以安全重试。这里把 WAIT_INITIALIZED 当作
    “稍后重试”，直到就绪或超时；只有其它状态才判定为真失败。
    """
    print(f"{desc} ...")
    goal = np.array(target, dtype=float)
    deadline = time.time() + ready_timeout
    while True:
        ok, status = nav.move_straight_to(goal, is_blocking=True, timeout=timeout)
        if ok:
            nav.stop_navigation()
            print(f"  结果: success=True, status={status}")
            return
        if "WAIT_INITIALIZED" in str(status) and time.time() < deadline:
            print(f"  子系统未就绪({status})，{retry_gap}s 后重试…")
            time.sleep(retry_gap)
            continue
        # 其它错误，或等待就绪超时 —— 真失败
        nav.stop_navigation()
        print(f"  {desc} 失败: success={ok}, status={status}，终止。")
        sys.exit(1)


# 1. 初始化机器人与导航模块
robot = GalbotRobot()
robot.init()

nav = GalbotNavigation()
nav.init()
print("初始化完成")

try:
    # 2. 切换到底盘位姿控制器
    if robot.switch_controller(G1ControllerName.CHASSIS_POSE_CTRL) != ControlStatus.SUCCESS:
        print("切换底盘控制器失败！")
        sys.exit(1)
    print("底盘控制器就绪")

    # 3. 重定位，让导航就绪（带 15s 超时，避免死循环）
    init_pose = np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0])
    t0 = time.time()
    while not nav.is_localized():
        nav.relocalize(init_pose)
        time.sleep(0.5)
        if time.time() - t0 > 15:
            print("重定位超时！")
            sys.exit(1)
    print("导航已就绪 (is_localized)")

    # 4. 顺时针 30° 的四元数
    yaw = -np.deg2rad(30.0)          # 顺时针为负
    q_cw30 = [0.0, 0.0, np.sin(yaw / 2.0), np.cos(yaw / 2.0)]

    # 5. 依次执行三段动作（每段相对当前位姿）
    move(nav, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], "前进 5 厘米")
    move(nav, [-0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], "后退 5 厘米")
    move(nav, [0.0, 0.0, 0.0] + q_cw30, "原地顺时针旋转 30 度")

    print("全部动作完成")
finally:
    # 6. 无论成功与否都安全下电、释放资源（避免异常时段错误）
    robot.request_shutdown()
    robot.wait_for_shutdown()
    robot.destroy()
    print("资源已释放")
