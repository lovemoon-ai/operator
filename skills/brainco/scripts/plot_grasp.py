#!/usr/bin/env python3
"""Per-finger motor current through a grasp cycle. One measure per axis."""
import sys, csv, argparse
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e3e2dd"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
NAMES = ["Thumb", "Thumb aux", "Index", "Middle", "Ring", "Pinky"]

def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv"); ap.add_argument("out")
    ap.add_argument("--note", default="")
    ap.add_argument("--limits", default="")
    args = ap.parse_args()

    lines = list(open(args.csv))
    meta = {}
    for l in lines:
        if l.startswith("#"):
            for kv in l.lstrip("#").strip().split():
                if "=" in kv:
                    k, v = kv.split("=", 1); meta[k] = v
    rows = list(csv.DictReader([l for l in lines if not l.startswith("#")]))
    if not rows: print("no data"); return 1

    raw = args.limits or meta.get("max_current_ma", "1000")
    lim = [float(x) for x in raw.split(",")]
    if len(lim) == 1: lim = lim * 6

    t = [float(r["t_ms"]) / 1000.0 for r in rows]
    cur = [[float(r["cur%d" % f]) / 1000.0 * lim[f] for r in rows] for f in range(6)]
    pos = [[float(r["pos%d" % f]) for r in rows] for f in range(6)]
    phase = [r["phase"] for r in rows]
    state = [[r["state%d" % f] for r in rows] for f in range(6)]

    fig, (axA, axB, axC) = plt.subplots(
        3, 1, figsize=(13.5, 9.6), sharex=True,
        gridspec_kw={"height_ratios": [1.0, 2.3, 1.15], "hspace": 0.16})
    fig.patch.set_facecolor(SURFACE)

    spans, cp, start = [], phase[0], t[0]
    for i in range(1, len(phase)):
        if phase[i] != cp:
            spans.append((start, t[i], cp)); cp = phase[i]; start = t[i]
    spans.append((start, t[-1], cp))
    for a in (axA, axB, axC):
        a.set_facecolor(SURFACE)
        for k, (s, e, nm) in enumerate(spans):
            if k % 2 == 0: a.axvspan(s, e, color="#000000", alpha=0.035, lw=0, zorder=0)
            a.axvline(s, color=GRID, lw=1, zorder=1)
    for s, e, nm in spans:
        axA.annotate(nm, xy=((s + e) / 2, 1.10), xycoords=("data", "axes fraction"),
                     ha="center", va="bottom", fontsize=10, color=INK2)

    for f in range(6):
        axA.plot(t, cur[f], color=SERIES[f], lw=1.4, label=NAMES[f], zorder=4)
        axB.plot(t, cur[f], color=SERIES[f], lw=2, zorder=4, solid_capstyle="round")
        axC.plot(t, pos[f], color=SERIES[f], lw=2, zorder=4, solid_capstyle="round")

    # detail window from robust percentiles, so single-sample transients don't set the scale
    allv = [v for f in range(6) for v in cur[f]]
    hi = max(abs(pct(allv, 0.012)), abs(pct(allv, 0.988))) * 1.45
    axB.set_ylim(-hi, hi)
    clipped = 0
    for f in range(6):
        for i, v in enumerate(cur[f]):
            if abs(v) > hi:
                axB.plot([t[i]], [hi if v > 0 else -hi], marker="^" if v > 0 else "v",
                         ms=6, color=SERIES[f], mec=SURFACE, mew=1, clip_on=False, zorder=6)
                clipped += 1

    for f in range(6):
        for i in range(1, len(t)):
            if state[f][i] == "STALL" and state[f][i - 1] != "STALL":
                axA.axvline(t[i], color=SERIES[f], lw=1.5, ls=":", zorder=5)

    # direct labels (relief rule) anchored in the baseline phase, where series separate best
    base_i = max(1, sum(1 for p in phase if p == "baseline") // 2)
    span = 2 * hi; used = []
    for f in range(6):
        y = cur[f][base_i]
        while any(abs(y - u) < span * 0.055 for u in used): y += span * 0.055
        used.append(y)
        axB.plot([t[0] - 0.10], [y], marker="o", ms=7, color=SERIES[f],
                 mec=SURFACE, mew=1.5, clip_on=False, zorder=7)
        axB.annotate(NAMES[f], xy=(t[0] - 0.22, y), va="center", ha="right", fontsize=10,
                     color=INK, annotation_clip=False, zorder=7)

    for a in (axA, axB):
        a.axhline(0, color=INK2, lw=1, alpha=0.45, zorder=2)
    axA.set_ylabel("current, full range\n(mA)", fontsize=10.5, color=INK)
    axB.set_ylabel("current, detail  (mA)", fontsize=11, color=INK)
    axC.set_ylabel("position\n(0 open - 1000 closed)", fontsize=10.5, color=INK)
    axC.set_xlabel("time (s)", fontsize=11, color=INK)

    side = "right hand" if meta.get("slave") == "127" else "left hand"
    fig.text(0.135, 0.975, "BrainCo Revo2 %s - per-finger motor current through a grasp cycle%s"
             % (side, args.note), fontsize=14.5, color=INK, ha="left", va="top")
    fig.text(0.135, 0.945,
             "turbo %s  |  current limit %g mA (thumb %g)  |  %d Hz  |  positive = closing direction"
             % ("ON" if meta.get("turbo") == "1" else "OFF", lim[2], lim[0],
                int(meta.get("hz", 100))),
             fontsize=10, color=INK2, ha="left", va="top")
    axA.annotate("start/stop transients - single-sample inrush and braking spikes",
                 xy=(0.995, 0.06), xycoords="axes fraction", ha="right", va="bottom",
                 fontsize=9.5, color=INK2)
    if clipped:
        axB.annotate("same data, rescaled to the sustained band; %d transient samples clipped "
                     "(triangles mark them, full extent in the panel above)" % clipped,
                     xy=(0.995, 0.035), xycoords="axes fraction", ha="right", va="bottom",
                     fontsize=9.5, color=INK2)

    for a in (axA, axB, axC):
        a.grid(True, axis="y", color=GRID, lw=1, zorder=1); a.set_axisbelow(True)
        for s in ("top", "right"): a.spines[s].set_visible(False)
        for s in ("left", "bottom"): a.spines[s].set_color(GRID)
        a.tick_params(colors=INK2, labelsize=10)
    leg = axA.legend(loc="lower left", bbox_to_anchor=(0, 1.30), frameon=False, fontsize=10,
                     ncol=6, handlelength=1.6, columnspacing=1.6, borderaxespad=0)
    for x in leg.get_texts(): x.set_color(INK)
    fig.subplots_adjust(left=0.135, right=0.975, top=0.845, bottom=0.075)
    fig.savefig(args.out, dpi=150, facecolor=SURFACE)
    print("wrote", args.out, "| detail window +-%.0f mA | clipped %d samples" % (hi, clipped))
    return 0

sys.exit(main())
