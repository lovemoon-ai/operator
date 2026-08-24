#!/usr/bin/env python3
"""
Wuji Gloves -> live 3D hand skeleton + tactile visualization (auto-detects 1..N gloves).

Renders per glove: 3D skeleton (press highlights) on top; below it a tactile
panel with per-zone press bars and per-zone taxel strips (baseline-subtracted).

触觉数据来自 `tactile_zones`。注意 `tactile_binary` / `tactile_residual` /
`tactile_point_cloud` 这三个 topic 存在但默认不发布任何帧 —— 订阅它们不会报错，
面板只会永远空着，别用。

Usage:
    python dual_glove_viz.py             # window with every glove found
    python dual_glove_viz.py --save out.png --secs 6
    python dual_glove_viz.py --no-tactile        # 只看骨架
"""

import argparse
import os
import signal
import sys
import threading
import time

import numpy as np
import matplotlib
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D  # noqa: F401

FINGERS = {
    "thumb":  [0, 1, 2, 3, 4],
    "index":  [0, 5, 6, 7, 8],
    "middle": [0, 9, 10, 11, 12],
    "ring":   [0, 13, 14, 15, 16],
    "pinky":  [0, 17, 18, 19, 20],
}
PALM = [5, 9, 13, 17]
COLORS = {"thumb": "#E8734A", "index": "#4A9BE8", "middle": "#4AE88F",
          "ring": "#E8C84A", "pinky": "#B84AE8"}
BG = "#12141a"

# 触觉分区。实测每区的传感点数（768 个原始点里 219 个恒为 -1 = 无效）:
#   thumb 60 / index 54 / middle 60 / ring 54 / pinky 55 / palm 308
ZONES = ["thumb", "index", "middle", "ring", "pinky", "palm"]
ZONE_COLORS = dict(COLORS, palm="#8892a6")

INVALID = -1.0     # 传感器无效值，必须先剔除再统计
TOUCH_MIN = 0.12   # 高于基线多少才算“真的被按了”（低于此视为噪声）
DEAD_MAX = 0.02    # 整段会话原始峰值低于此 = 该分区无输出（好的分区静息就有 0.13+）


class TactileBuffer:
    """触觉分区数据 + 自动基线标定。

    为什么要基线: 手套静息摊在桌上时，各区读数 p95 已达 ~0.2、峰值能到 1.00
    （自重、桌面反作用力、零点漂移）。直接按 0~1 上色会一直显示“在被按”。
    启动时先采一段静息基线，之后只显示高于基线的部分。
    """

    def __init__(self, baseline_secs=2.0):
        self._lock = threading.Lock()
        self._cur = {z: 0.0 for z in ZONES}     # 各区当前峰值（原始）
        self._raw = {z: None for z in ZONES}    # 各区当前逐点数组（已剔无效）
        self._base = {z: 0.0 for z in ZONES}    # 各区静息基线
        self._seen = {z: 0.0 for z in ZONES}    # 各区历史最大值（用于死区判定）
        self._samples = {z: [] for z in ZONES}
        self._t0 = time.time()
        self._baseline_secs = baseline_secs
        self._ready = False
        self._n = 0

    def push(self, msg):
        with self._lock:
            self._n += 1
            calibrating = (time.time() - self._t0) < self._baseline_secs
            for z in ZONES:
                try:
                    v = np.asarray(list(getattr(msg, z)), dtype=np.float64)
                except Exception:
                    continue
                v = v[v != INVALID]           # 剔除无效传感点
                if v.size == 0:
                    continue
                pk = float(v.max())
                self._cur[z] = pk
                self._raw[z] = v
                self._seen[z] = max(self._seen[z], pk)
                if calibrating:
                    self._samples[z].append(pk)
            if not calibrating and not self._ready:
                for z in ZONES:
                    s = self._samples[z]
                    # 用 p99 而非 max 作基线，避免个别尖峰把基线抬太高
                    self._base[z] = float(np.percentile(s, 99)) if s else 0.0
                self._ready = True

    def _norm(self, val, z):
        base = self._base[z]
        head = max(0.15, 1.0 - base)          # 基线之上的可用量程
        return np.clip((val - base) / head, 0.0, 1.0)

    def press(self):
        """返回各区 0~1 的“按压强度”（已扣除基线）。未标定完返回 None。"""
        with self._lock:
            if not self._ready:
                return None
            return {z: float(self._norm(self._cur[z], z)) for z in ZONES}

    def strips(self, bins=64):
        """各区逐点数据按 bins 分箱 -> (len(ZONES), bins) 图像。

        不猜测 768 个触点的二维物理排布（无 ground truth，画成 24x32 网格
        会让人读出并不存在的空间信息）。这里只做一件有依据的事：
        把每个分区自己的触点序列压成一条等宽条带，看得出区内哪一段在受力。
        """
        with self._lock:
            if not self._ready:
                return None
            img = np.full((len(ZONES), bins), np.nan)
            for r, z in enumerate(ZONES):
                v = self._raw[z]
                if v is None or v.size == 0:
                    continue
                edges = np.linspace(0, v.size, bins + 1).astype(int)
                for c in range(bins):
                    a, b = edges[c], max(edges[c + 1], edges[c] + 1)
                    seg = v[a:min(b, v.size)]
                    if seg.size:
                        img[r, c] = self._norm(float(seg.max()), z)
            return img

    def dead_zones(self):
        """整段会话内原始读数从未超过 DEAD_MAX 的分区 —— 触觉传感器无输出。

        判据不能写成 `== 0.0`：实测坏掉的分区会输出 0.005 这种极小的噪声底
        （右手 ring 实测 603 帧 max=0.005），精确等零会漏判。
        对照：同款好的分区静息就能到 0.13~0.90。
        """
        with self._lock:
            if self._n < 30:
                return []
            return [z for z in ZONES if self._seen[z] < DEAD_MAX]

    def seen(self):
        """各区整段会话的原始峰值（未扣基线）—— 用来区分「静息」和「坏了」。"""
        with self._lock:
            return dict(self._seen)

    def baseline(self):
        with self._lock:
            return dict(self._base) if self._ready else None

    def ready(self):
        with self._lock:
            return self._ready


def press_color(t):
    """按压强度 -> 颜色。暗红 -> 橙 -> 白热。"""
    t = float(np.clip(t, 0.0, 1.0))
    if t < 0.5:
        u = t / 0.5
        return (0.35 + 0.65 * u, 0.12 + 0.35 * u, 0.10 + 0.05 * u)
    u = (t - 0.5) / 0.5
    return (1.0, 0.47 + 0.53 * u, 0.15 + 0.85 * u)



class SkeletonBuffer:
    def __init__(self):
        self._lock = threading.Lock()
        self._pts = None
        self._n = 0
        self._conf = None

    def set_conf(self, conf):
        with self._lock:
            self._conf = conf

    def get_conf(self):
        with self._lock:
            return None if self._conf is None else list(self._conf)

    def set(self, pts):
        with self._lock:
            self._pts, self._n = pts, self._n + 1

    def get(self):
        with self._lock:
            return (None, 0) if self._pts is None else (self._pts.copy(), self._n)


def connect_all(sns=None, baseline_secs=2.0):
    """Scan and subscribe to every Wuji Glove found. Returns list of panels."""
    from wuji_sdk import SdkManager, DeviceType

    mgr = SdkManager.instance()
    devices = mgr.scan()
    gloves = [d for d in devices if d.device_type == DeviceType.WujiGlove]
    if sns:
        gloves = [d for d in gloves if d.sn in sns]
    print(f"scan: {len(devices)} device(s), {len(gloves)} glove(s)")
    if not gloves:
        print("\n没有发现手套。检查：")
        print("  - 手套是否上电（绿灯）")
        print("  - 手套网线是否接到了电脑的 USB 网卡上")
        print("  - ip neigh show | grep 192.168.1.")
        sys.exit(1)

    gloves.sort(key=lambda d: d.sn)
    panels, subs = [], []
    for i, d in enumerate(gloves):
        g = mgr.connect(sn=d.sn, device_name=f"glove{i}")
        side = str(g.hand_side().get())
        fw = str(g.version().get())
        print(f"  connected {d.sn}  side={side}  fw={fw}  addr={d.address}")
        buf = SkeletonBuffer()

        def make_cb(b):
            def cb(skel):
                b.set(np.array([[j.pose.position[0], j.pose.position[1],
                                 j.pose.position[2]] for j in skel.joints],
                               dtype=np.float32))
            return cb

        cb = make_cb(buf)
        sub = g.hand_skeleton().subscribe_with_callback(cb)
        subs.append(sub)

        def make_conf_cb(b):
            def ccb(msg):
                try:
                    b.set_conf([float(f.confidence) for f in msg.fingers])
                except Exception:
                    pass
            return ccb

        subs.append(g.hand_joint_angles().subscribe_with_callback(make_conf_cb(buf)))

        # 触觉分区。实测可用的只有 tactile(768点) 和 tactile_zones(6区)；
        # tactile_binary / tactile_residual / tactile_point_cloud 三个 topic
        # 存在但默认不发布任何帧（需要先做 calibrate_tactile），别订阅它们，
        # 否则面板会永远空着还不报错。
        tac = TactileBuffer(baseline_secs=baseline_secs)
        try:
            def make_zone_cb(t):
                def cb(msg):
                    try:
                        t.push(msg)
                    except Exception:
                        pass
                return cb

            subs.append(g.tactile_zones().subscribe_with_callback(make_zone_cb(tac)))
        except Exception as e:
            print(f"  {d.sn}: tactile_zones 不可用（{e}），触觉面板将留空")
            tac = None

        label = side.split(".")[-1].replace("HandSide", "") or side
        p = {"buf": buf, "tac": tac, "sn": d.sn, "side": label, "addr": d.address,
             "glove": g, "cb": cb, "sub": sub, "resubs": 0}
        panels.append(p)
    return panels, subs


def start_watchdog(panels, stop, stall_secs=4.0):
    """Re-subscribe any glove whose stream goes silent.

    A session dropped by the device (e.g. a stale session from a previous
    process timing out) kills the subscription without killing the handle,
    so the stream freezes forever. Detect that and re-attach.
    """

    def run():
        last = {p["sn"]: (0, time.time()) for p in panels}
        while not stop.wait(1.0):
            now = time.time()
            for p in panels:
                _, n = p["buf"].get()
                prev_n, prev_t = last[p["sn"]]
                if n != prev_n:
                    last[p["sn"]] = (n, now)
                    continue
                if now - prev_t < stall_secs:
                    continue
                print(f"[watchdog] {p['side']} {p['sn']} stalled "
                      f"{now - prev_t:.1f}s -> re-subscribing", flush=True)
                try:
                    p["sub"].close()
                except Exception:
                    pass
                try:
                    p["sub"] = p["glove"].hand_skeleton().subscribe_with_callback(p["cb"])
                    p["resubs"] += 1
                except Exception as e:
                    print(f"[watchdog] re-subscribe failed: {e}", flush=True)
                last[p["sn"]] = (n, now)

    threading.Thread(target=run, daemon=True).start()


def style_axes(ax):
    ax.set_facecolor(BG)
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        axis.pane.set_facecolor(BG)
        axis.pane.set_edgecolor("#2a2f3a")
        axis.label.set_color("#8892a6")
    ax.tick_params(colors="#4a5260", labelsize=6)


CONF_MIN = 0.02  # below this the device is not actually tracking the finger


def draw(ax, pts, artists=None, conf=None, press=None):
    """Draw/refresh a skeleton.

    conf  —— 无信号的手指灰显（EMF 链路问题）
    press —— 各区按压强度 0~1，受力的手指发亮加粗（触觉）
    """
    if artists is None:
        artists = {"bones": {}, "palm": None, "tips": {}}
        for name in FINGERS:
            (ln,) = ax.plot([], [], [], "-o", color=COLORS[name], lw=2.5, markersize=4)
            artists["bones"][name] = ln
            # 指尖受力光点，压力越大越亮越大
            (tp,) = ax.plot([], [], [], "o", color=COLORS[name], markersize=0,
                            alpha=0.0, markeredgewidth=0)
            artists["tips"][name] = tp
        (pl,) = ax.plot([], [], [], "-", color="#8892a6", lw=2.0)
        artists["palm"] = pl
    for fi, (name, idx) in enumerate(FINGERS.items()):
        p = pts[idx]
        ln = artists["bones"][name]
        ln.set_data(p[:, 0], p[:, 1])
        ln.set_3d_properties(p[:, 2])
        ok = conf is None or fi >= len(conf) or conf[fi] >= CONF_MIN
        f = 0.0 if not press else float(press.get(name, 0.0))
        touched = ok and f > TOUCH_MIN
        if not ok:
            ln.set_color("#3a3f4a")
        elif touched:
            ln.set_color(press_color(f))          # 受力 -> 暖色高亮
        else:
            ln.set_color(COLORS[name])
        ln.set_linestyle("-" if ok else ":")
        ln.set_alpha(1.0 if ok else 0.55)
        ln.set_linewidth(2.5 + 4.0 * f if touched else 2.5)

        tp = artists["tips"][name]
        tip = p[-1]
        if touched:
            tp.set_data([tip[0]], [tip[1]])
            tp.set_3d_properties([tip[2]])
            tp.set_markersize(8 + 26 * f)
            tp.set_color(press_color(f))
            tp.set_alpha(0.30 + 0.45 * f)
        else:
            tp.set_markersize(0)
            tp.set_alpha(0.0)
    pp = pts[PALM]
    artists["palm"].set_data(pp[:, 0], pp[:, 1])
    artists["palm"].set_3d_properties(pp[:, 2])
    pf = 0.0 if not press else float(press.get("palm", 0.0))
    if pf > TOUCH_MIN:
        artists["palm"].set_color(press_color(pf))
        artists["palm"].set_linewidth(2.0 + 4.0 * pf)
    else:
        artists["palm"].set_color("#8892a6")
        artists["palm"].set_linewidth(2.0)
    c = pts.mean(axis=0)
    r = max(float(np.abs(pts - c).max()), 0.05) * 1.15
    ax.set_xlim(c[0] - r, c[0] + r)
    ax.set_ylim(c[1] - r, c[1] + r)
    ax.set_zlim(c[2] - r, c[2] + r)
    return artists


def style_2d(ax):
    ax.set_facecolor(BG)
    for s in ax.spines.values():
        s.set_color("#2a2f3a")
    ax.tick_params(colors="#8892a6", labelsize=7)


def draw_tactile(ax_bar, ax_strip, tac, artists=None, press=None):
    """触觉面板：左=各区按压强度柱状图，右=区内触点分箱条带。

    两个面板都显示扣除静息基线后的值。手套摊在桌上时各区读数 p95 已达 ~0.2，
    不扣基线会一直显示“在被按”。

    press —— 传入则用它代替当前瞬时值（--save 用整段采样的峰值）。
    """
    if press is None:
        press = None if tac is None else tac.press()
    strips = None if tac is None else tac.strips()
    dead = [] if tac is None else tac.dead_zones()
    raw = {} if tac is None else tac.seen()

    if artists is None:
        artists = {}
        bars = ax_bar.bar(range(len(ZONES)), [0] * len(ZONES),
                          color=[ZONE_COLORS[z] for z in ZONES])
        ax_bar.set_ylim(0, 1.0)
        ax_bar.set_xticks(range(len(ZONES)))
        # 不转 45°：旋转后的标签会戳到下面条带面板的标题上。
        # 分区名下面条带的 y 轴已经按同样顺序标过了，这里只要短标签够认。
        ax_bar.set_xticklabels(ZONES, fontsize=6.5)
        ax_bar.axhline(TOUCH_MIN, color="#5a6270", lw=0.8, ls="--")
        ax_bar.set_title("zone press  (baseline-subtracted)",
                         color="#c8d0de", fontsize=8)
        style_2d(ax_bar)
        artists["bars"] = bars
        artists["labels"] = [
            ax_bar.text(i, 0.02, "", ha="center", va="bottom", fontsize=6.5,
                        color="#c8d0de", family="monospace")
            for i in range(len(ZONES))]

        im = ax_strip.imshow(np.zeros((len(ZONES), 64)), aspect="auto",
                             vmin=0, vmax=1, cmap="inferno",
                             interpolation="nearest")
        ax_strip.set_yticks(range(len(ZONES)))
        ax_strip.set_yticklabels(ZONES, fontsize=7)
        ax_strip.set_xticks([])
        ax_strip.set_title("taxels within zone  (binned by index)",
                           color="#c8d0de", fontsize=8)
        style_2d(ax_strip)
        artists["im"] = im
        artists["note"] = ax_strip.text(
            0.5, -0.14, "", transform=ax_strip.transAxes, ha="center",
            fontsize=6.5, color="#7f8a9c", family="monospace")

    if press is None:
        for lb in artists["labels"]:
            lb.set_text("")
        artists["labels"][0].set_text("calibrating baseline...")
        return artists

    for i, z in enumerate(ZONES):
        v = press[z]
        b = artists["bars"][i]
        b.set_height(v)
        b.set_color(press_color(v) if v > TOUCH_MIN else ZONE_COLORS[z])
        b.set_alpha(1.0 if z not in dead else 0.25)
        # 静息时也把原始峰值写出来 —— 扣完基线后「没被按」和「传感器坏了」
        # 都是 0，光看柱子高度分不出来；raw peak 能。
        if z in dead:
            txt, col = "DEAD", "#ff6b6b"
        elif v > TOUCH_MIN:
            txt, col = f"{v:.2f}", "#c8d0de"
        else:
            txt, col = f"pk{raw.get(z, 0.0):.2f}", "#5a6270"
        artists["labels"][i].set_text(txt)
        artists["labels"][i].set_color(col)

    if strips is not None:
        artists["im"].set_data(np.nan_to_num(strips, nan=0.0))
    # 静息时条带整片是黑的（扣完基线本来就没东西）。不加说明的话，
    # 截图里「没受力」和「面板坏了」长得一模一样。
    if dead:
        artists["note"].set_text("NO TACTILE: " + ", ".join(dead))
        artists["note"].set_color("#ff6b6b")
    elif not any(press[z] > TOUCH_MIN for z in ZONES):
        artists["note"].set_text("no contact - squeeze the glove to light this up")
        artists["note"].set_color("#5a6270")
    else:
        artists["note"].set_text("")
    return artists


def run_viz(panels, tactile=True):
    n = len(panels)
    tactile = tactile and any(p["tac"] is not None for p in panels)
    rows = 3 if tactile else 1
    fig = plt.figure(figsize=(6 * n, 9 if tactile else 5.5))
    fig.canvas.manager.set_window_title(f"Wuji Gloves - {n} hand(s) live")
    fig.patch.set_facecolor(BG)
    grid = fig.add_gridspec(rows, n,
                            height_ratios=[3.0, 1.3, 1.0] if tactile else [1.0])

    for i, p in enumerate(panels):
        ax = fig.add_subplot(grid[0, i], projection="3d")
        style_axes(ax)
        ax.set_title(f"{p['side']}  |  {p['sn']}", color="#c8d0de", fontsize=10)
        p["ax"] = ax
        p["ax_bar"] = fig.add_subplot(grid[1, i]) if tactile else None
        p["ax_strip"] = fig.add_subplot(grid[2, i]) if tactile else None
        p["artists"] = None
        p["tart"] = None
        p["hud"] = ax.text2D(0.02, 0.95, "", transform=ax.transAxes,
                             color="#c8d0de", family="monospace", fontsize=9)
        p["last_n"], p["tlast"], p["fps"] = 0, time.time(), 0.0

    def update(_):
        now = time.time()
        for p in panels:
            pts, cnt = p["buf"].get()
            if pts is None or len(pts) < 21:
                p["hud"].set_text("waiting for frames...")
                continue
            dt = now - p["tlast"]
            if dt >= 0.5:
                p["fps"] = (cnt - p["last_n"]) / dt
                p["last_n"], p["tlast"] = cnt, now
            conf = p["buf"].get_conf()
            tac = p["tac"]
            press = None if tac is None else tac.press()
            p["artists"] = draw(p["ax"], pts, p["artists"], conf, press)
            if p["ax_bar"] is not None:
                p["tart"] = draw_tactile(p["ax_bar"], p["ax_strip"], tac,
                                         p["tart"])
            extra = f"   re-sub x{p['resubs']}" if p["resubs"] else ""
            if conf:
                bad = [n for i, n in enumerate(FINGERS) if i < len(conf)
                       and conf[i] < CONF_MIN]
                if bad:
                    extra += "\nNO SIGNAL: " + ", ".join(bad)
            if tac is not None:
                dz = tac.dead_zones()
                if dz:
                    extra += "\nNO TACTILE: " + ", ".join(dz)
            p["hud"].set_text(f"frames {cnt:>6}   {p['fps']:5.1f} Hz{extra}")

    from matplotlib.animation import FuncAnimation
    anim = FuncAnimation(fig, update, interval=33, cache_frame_data=False)
    plt.tight_layout()
    plt.show()
    return anim


def save_sheet(panels, path, secs, tactile=True):
    """Headless: capture `secs` of motion, write a contact sheet (rows=gloves)."""
    time.sleep(0.5)
    # 等静息基线标定完再开始采，否则前几秒 press() 全是 None，
    # 峰值统计会漏掉这段。
    tw = time.time() + 8.0
    while time.time() < tw and any(p["tac"] is not None and not p["tac"].ready()
                                   for p in panels):
        time.sleep(0.1)
    tactile = tactile and any(p["tac"] is not None for p in panels)
    caps = {p["sn"]: [] for p in panels}
    # 各区整段采样内的峰值按压 —— 留证据时比某一瞬间的读数有用得多，
    # 「整段都没超过 0」才是触觉分区无输出的判据。
    peaks = {p["sn"]: {z: 0.0 for z in ZONES} for p in panels}
    t_end = time.time() + secs
    while time.time() < t_end:
        for p in panels:
            pts, _ = p["buf"].get()
            pr = None if p["tac"] is None else p["tac"].press()
            if pr:
                for z in ZONES:
                    peaks[p["sn"]][z] = max(peaks[p["sn"]][z], pr[z])
            if pts is not None:
                caps[p["sn"]].append((pts, pr))
        time.sleep(1 / 60)

    cols, rows = (6 if tactile else 4), len(panels)
    fig = plt.figure(figsize=(3.5 * cols, 3.6 * rows))
    fig.patch.set_facecolor(BG)
    for r, p in enumerate(panels):
        got = caps[p["sn"]]
        if not got:
            print(f"{p['sn']}: no frames"); continue
        picks = [got[i] for i in np.linspace(0, len(got) - 1, 4).astype(int)]
        disp = float(np.abs(np.array(got[-1][0]) - np.array(got[0][0])).max())
        conf = p["buf"].get_conf()
        bad = [] if not conf else [n for i, n in enumerate(FINGERS)
                                   if i < len(conf) and conf[i] < CONF_MIN]
        dz = [] if p["tac"] is None else p["tac"].dead_zones()
        note = f"  max disp {disp*1000:.1f} mm"
        if bad:
            note += "   NO SIGNAL: " + ", ".join(bad)
        if dz:
            note += "   NO TACTILE: " + ", ".join(dz)
        print(f"{p['sn']} ({p['side']}): {len(got)} frames, max disp {disp*1000:.1f} mm"
              + (f"   NO SIGNAL: {', '.join(bad)}" if bad else "")
              + (f"   NO TACTILE: {', '.join(dz)}" if dz else ""))
        for c, (pts, pr) in enumerate(picks):
            ax = fig.add_subplot(rows, cols, r * cols + c + 1, projection="3d")
            style_axes(ax)
            draw(ax, pts, None, conf, pr)
            ax.set_title(f"{p['side']} t{c}", color="#c8d0de", fontsize=8)
            if c == 0:
                # 把缺信号的手指写在图上 —— --save 常用来留证据报障，
                # 光靠「某根手指变灰了」在截图里不够明确。
                ax.text2D(0.0, -0.08, f"{p['side']}  {p['sn']}{note}",
                          transform=ax.transAxes, fontsize=7.5,
                          color="#ff6b6b" if (bad or dz) else "#7f8a9c",
                          family="monospace")
        if tactile:
            # 最后两列：分区峰值按压 + 区内触点分箱条带
            ax_bar = fig.add_subplot(rows, cols, r * cols + 5)
            ax_strip = fig.add_subplot(rows, cols, r * cols + 6)
            draw_tactile(ax_bar, ax_strip, p["tac"], None,
                         press=peaks[p["sn"]] if p["tac"] else None)
            ax_bar.set_title(f"{p['side']} tactile peak", color="#c8d0de",
                             fontsize=8)
    plt.tight_layout()
    plt.savefig(path, dpi=105, facecolor=BG)
    print(f"-> wrote {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sn", nargs="*", default=None, help="only these serials")
    ap.add_argument("--save", default=None, help="headless: write PNG contact sheet")
    ap.add_argument("--secs", type=float, default=6.0)
    ap.add_argument("--baseline-secs", type=float, default=2.0,
                    help="启动时采集静息基线的时长；这段时间内手套要保持不受力")
    ap.add_argument("--no-tactile", action="store_true",
                    help="只画 3D 骨架，不画触觉面板")
    a = ap.parse_args()

    if a.save:
        matplotlib.use("Agg")

    panels, subs = connect_all(a.sn, baseline_secs=a.baseline_secs)
    if not a.no_tactile:
        print(f"采集静息基线 {a.baseline_secs:.1f}s —— 保持手套不受力…")
    stop = threading.Event()
    start_watchdog(panels, stop)

    def _bye(*_):
        # Close subscriptions BEFORE dying so the device does not keep a stale
        # session alive (a stale session times out later and tears down the
        # next process's subscription). Raising an exception here does not
        # escape the GUI event loop, so exit hard once cleanup is done.
        stop.set()
        for pp in panels:
            try:
                pp["sub"].close()
            except Exception:
                pass
        try:
            plt.close("all")
        except Exception:
            pass
        os._exit(0)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, _bye)
        except Exception:
            pass

    try:
        if a.save:
            save_sheet(panels, a.save, a.secs, tactile=not a.no_tactile)
        else:
            run_viz(panels, tactile=not a.no_tactile)
    finally:
        stop.set()
        for s in [p["sub"] for p in panels]:
            try:
                s.close()
            except Exception:
                pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
