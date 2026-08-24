#!/usr/bin/env python3
"""
Wuji Glove 传感器体检 —— 逐通道判断每根手指是否真的在出数据。

新手套到手、或怀疑某根手指不对劲时跑这个。它比肉眼看可视化可靠得多：
可视化里一根「死掉」的手指仍然会被画出来（解算器输出固定默认姿态），
看起来只是「不太动」，很容易被当成没戴好。

检查项:
  1. emf_poses    —— 5 个 EMF 接收线圈通道的位置向量模长。恒为 0 = 该通道无输出
  2. confidence   —— 每根手指的置信度。官方文档: <0.9 不可信, <0.8 环境干扰严重
  3. 骨长          —— 从 hand_skeleton 反算每指 4 段骨长，排除几何模型问题
  4. 静止位移      —— 关节在整段采样内的位移。逐位恒定 = 解算器在输出固定默认值
  5. 关节角摆幅    —— 静止时的角度变化。几十度的摆幅 = 垃圾数据

判据可靠性: 只有 [1][2] 是死通道的可靠判据。
一根通道死掉后，[4][5] 既可能表现为「冻结在默认姿态」(位移恒 0)，
也可能表现为「大幅乱摆」(位移上百 mm、角度摆幅 ~100°) —— 两种都实际见过，
取决于解算器状态，不要拿它们当主判据。

退出码: 存在硬件故障时为 1；只有环境/使用类提示时为 0。

用法:
    python glove_healthcheck.py              # 检查扫到的所有手套
    python glove_healthcheck.py --secs 10    # 采样更久
    python glove_healthcheck.py --sn WG1K... # 只查一只
"""

import argparse
import sys
import time

import numpy as np

FINGERS = {
    "thumb":  [0, 1, 2, 3, 4],
    "index":  [0, 5, 6, 7, 8],
    "middle": [0, 9, 10, 11, 12],
    "ring":   [0, 13, 14, 15, 16],
    "pinky":  [0, 17, 18, 19, 20],
}
NAMES = list(FINGERS)

# 官方文档阈值
CONF_UNTRUSTED = 0.9   # emf_poses confidence 低于此值即不可信
CONF_INTERFERE = 0.8   # 低于此值说明环境干扰严重
CONF_DEAD = 1e-9       # 恒为 0 = 通道无输出，与「低」是两回事


def collect(glove, secs, cap):
    """同时采 emf_poses / hand_skeleton / hand_joint_angles。"""
    emf, skel, ang = [], [], []
    subs = [
        glove.emf_poses().subscribe_with_callback(
            lambda m: emf.append(m) if len(emf) < cap else None),
        glove.hand_skeleton().subscribe_with_callback(
            lambda m: skel.append(m) if len(skel) < cap else None),
        glove.hand_joint_angles().subscribe_with_callback(
            lambda m: ang.append(m) if len(ang) < cap else None),
    ]
    time.sleep(secs)
    for s in subs:
        try:
            s.close()
        except Exception:
            pass
    return emf, skel, ang


def report(sn, side, emf, skel, ang):
    print(f"\n{'=' * 72}")
    print(f"  {side.upper():<6} {sn}")
    print(f"  采样: emf={len(emf)}  skeleton={len(skel)}  angles={len(ang)}")
    print(f"{'=' * 72}")

    problems = []   # 硬件故障 —— 决定退出码
    warnings = []   # 环境/使用问题 —— 只提示，不算故障
    dead = []       # 确认无输出的 EMF 通道

    # --- 1. EMF 通道模长 -------------------------------------------------
    if emf:
        m = emf[len(emf) // 2]
        print("\n[1] EMF 接收线圈通道 (emf_poses)")
        for i, p in enumerate(m.poses):
            v = np.array([p.pose.position[0], p.pose.position[1],
                          p.pose.position[2]])
            n = float(np.linalg.norm(v))
            tag = ""
            if n < CONF_DEAD:
                tag = "   <== 恒为 0，该通道无输出"
                problems.append(f"EMF ch{i} ({NAMES[i]}) 无输出")
                dead.append(NAMES[i])
            print(f"     ch{i} {NAMES[i]:<7} |n|={n:.5f}{tag}")

    # --- 2. 每指置信度 ---------------------------------------------------
    if ang:
        conf = np.array([[float(f.confidence) for f in fr.fingers]
                         for fr in ang]).mean(0)
        print("\n[2] 每指置信度  (官方: <0.9 不可信, <0.8 环境干扰严重)")
        for i, nm in enumerate(NAMES):
            c = conf[i]
            if c < CONF_DEAD:
                tag = "   <== 恒为 0，无数据（非「低」，是「没有」）"
                problems.append(f"{nm} confidence=0")
            elif c < CONF_INTERFERE:
                tag = "   <  环境干扰"
            elif c < CONF_UNTRUSTED:
                tag = "   <  偏低"
            else:
                tag = ""
            print(f"     {nm:<7} {c:.4f}{tag}")
        if 0 < float(np.median(conf)) < CONF_INTERFERE:
            warnings.append("整体置信度偏低：戴上手套、手距发射线圈 30cm 内、远离金属")

    # --- 3/4. 骨长与静止位移 ---------------------------------------------
    if skel:
        A = np.array([[[j.pose.position[0], j.pose.position[1],
                        j.pose.position[2]] for j in fr.joints]
                      for fr in skel], dtype=np.float64)
        print("\n[3] 骨长(mm) 与 [4] 静止位移(mm)  —— 位移逐位为 0 = 输出固定默认姿态")
        print(f"     {'finger':<8}{'bone1':>7}{'bone2':>7}{'bone3':>7}{'bone4':>7}"
              f"  |{'关节位移(相对首帧)':>22}")
        for nm, idx in FINGERS.items():
            P = A[:, idx, :]
            bl = [np.linalg.norm(P[:, k + 1] - P[:, k], axis=1).mean() * 1000
                  for k in range(4)]
            disp = [float(np.abs(P[:, k] - P[0, k]).max() * 1000) for k in range(1, 5)]
            frozen = sum(1 for d in disp if d == 0.0)
            tag = ""
            if frozen >= 3:
                tag = "  <== 关节冻结"
                problems.append(f"{nm} 关节输出为固定默认值")
            if min(bl[1:]) < 5:
                tag += "  <== 骨长异常"
                problems.append(f"{nm} 骨长异常")
            print(f"     {nm:<8}" + "".join(f"{b:7.1f}" for b in bl)
                  + "  |" + " ".join(f"{d:5.3f}" for d in disp) + tag)

    # --- 5. 关节角摆幅 ---------------------------------------------------
    if ang:
        print("\n[5] 静止时关节角摆幅(deg)  —— 注: 非拇指仅前 4 槽有效，第 5 槽恒为 0 占位")
        for i, nm in enumerate(NAMES):
            F = np.array([[float(v) for v in fr.fingers[i].angles] for fr in ang])
            rng = np.degrees(F.max(0) - F.min(0))
            valid = rng if nm == "thumb" else rng[:4]
            if valid.max() > 10:
                if nm in dead:
                    # 通道已死，乱摆是它的后果，不另算一条故障
                    tag = "   <== 乱摆（EMF 通道无输出的后果，非独立故障）"
                else:
                    tag = "   <== 静止时乱摆"
                    warnings.append(
                        f"{nm} 静止时关节角摆动 {valid.max():.1f}°（先排除环境干扰再怀疑硬件）")
            else:
                tag = ""
            print(f"     {nm:<7} " + " ".join(f"{r:6.2f}" for r in rng) + tag)

    # --- 结论 -------------------------------------------------------------
    print(f"\n{'-' * 72}")
    if problems:
        print("  硬件故障:")
        for p in dict.fromkeys(problems):
            print(f"    - {p}")
    if warnings:
        print("  提示（环境/使用，不是硬件故障）:")
        for w in dict.fromkeys(warnings):
            print(f"    - {w}")
    if not problems and not warnings:
        print("  未发现异常。")
    elif not problems:
        print("\n  未发现硬件故障。")

    # 只有确实存在死通道时才给报障指引
    if dead:
        print(f"\n  {'、'.join(dead)} 的 EMF 链路完全无输出（|n| 恒为 0 且 confidence 恒为 0）。")
        print("  注意：死通道对应的手指在骨架里可能表现为「冻结在默认姿态」，")
        print("  也可能表现为「大幅乱摆」——两种都见过，不要靠这个判断，以 [1][2] 为准。")
        print("  软件无法区分「出厂标定数据缺失」与「接收线圈物理损坏」，")
        print("  两者的 corrected amplitude 都是 0。按官方排障页先查线圈物理损坏，")
        print("  再带证据报 support@wuji.tech。")
    print(f"{'-' * 72}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sn", default=None)
    ap.add_argument("--secs", type=float, default=6.0)
    ap.add_argument("--cap", type=int, default=1500)
    a = ap.parse_args()

    from wuji_sdk import SdkManager, DeviceType

    mgr = SdkManager.instance()
    gloves = [d for d in mgr.scan() if d.device_type == DeviceType.WujiGlove]
    if a.sn:
        gloves = [d for d in gloves if d.sn == a.sn]
    if not gloves:
        print("没有扫到手套。先跑 check_gloves.sh 排查网络层。")
        sys.exit(1)

    bad = 0
    for i, d in enumerate(sorted(gloves, key=lambda x: x.sn)):
        g = mgr.connect(sn=d.sn, device_name=f"hc{i}")
        side = str(g.hand_side().get())
        print(f"\n连接 {d.sn} side={side} fw={g.version().get()} addr={d.address}")
        emf, skel, ang = collect(g, a.secs, a.cap)
        if report(d.sn, side, emf, skel, ang):
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
