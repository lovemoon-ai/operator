# SO-101 MuJoCo 仿真场景（pick-and-place）

参考 [ggando.com/blog/so101-rl-lift](https://ggando.com/blog/so101-rl-lift)，本目录搭建了一个本地可运行的
[SO-101 / SO-ARM101](https://github.com/TheRobotStudio/SO-ARM100) 机械臂 MuJoCo 仿真场景，包含：

- 一张木质 **桌子**（1.0 × 0.7 m，桌面高 0 m，桌腿落到 z = -0.75 m 的地面）
- 安装在桌面上的 **SO-101 6-DoF 机械臂**（base_so101_v2，使用官方 STS-3215 servo 参数）
- 桌面上一个 4 cm 的 **红色立方体**（free joint，可被夹取/移动）
- 安装在夹爪上的 **腕部相机** `wrist_cam`（沿用 menagerie 模型自带的相机/相机支架）
- 桌子侧面的 **第三视角相机** `side_cam`（targetbody 模式，自动对准红色方块）
- 额外正前方第三视角 `front_cam`

模型来源：[google-deepmind/mujoco_menagerie · robotstudio_so101](https://github.com/google-deepmind/mujoco_menagerie/tree/main/robotstudio_so101)（Apache-2.0），仅作微改并叠加桌子/方块/相机。

---

## 目录结构

```
mujuco-arm-so101/
├── README.md                       # 本文件
├── Makefile                        # make env / make run-sim / make render ...
├── requirements.txt                # Python 依赖
├── sim_so101.py                    # 仿真入口（viewer / render / smoketest）
└── assets/so101/
    ├── so101.xml                   # 来自 menagerie 的 SO-101 模型（含 wrist_cam）
    ├── scene_original.xml          # menagerie 自带的极简场景（参考用）
    ├── scene_pickplace.xml         # ★ 本仓库的主场景（桌子+方块+第三视角）
    └── assets/                     # 19 个 STL mesh 文件（由 prepare.sh 拉取，未提交进仓）
```

模型加载入口是 `assets/so101/scene_pickplace.xml`，该 XML `<include>` 了 `so101.xml`，
并在世界中加入桌子、红色方块以及第三视角相机。

> **关于 STL mesh**：19 个 STL 总计约 17 MB，未提交进 git。`./prepare.sh` 会从上游
> [`mujoco_menagerie`](https://github.com/google-deepmind/mujoco_menagerie/tree/main/robotstudio_so101/assets)
> （Apache-2.0）拉取并放进 `assets/so101/assets/`，**钉到具体 commit** 保证可复现。
> `make run-sim` / `smoketest` / `render` / `pick` 都会先自动跑一次（幂等，已下载好就秒过）。
> 如果只想自己手动准备：`./prepare.sh` / `./prepare.sh --check` / `./prepare.sh --force`。

---

## 一、安装 MuJoCo（macOS / Linux）

> Windows 也可，但本目录脚本在 macOS 14（Apple Silicon, Python 3.11/3.13）上验证通过。

### 推荐：用 Makefile + uv 一键搞定

本目录用 [`uv`](https://docs.astral.sh/uv/) 管理 Python 环境（比 `python -m venv + pip` 快很多）。
依赖声明在 `pyproject.toml`，确切版本锁在 `uv.lock`（已提交到仓库，保证可重复构建）。

```bash
# 第一次：安装 uv（如果还没装）
brew install uv                                       # macOS
# 或: curl -LsSf https://astral.sh/uv/install.sh | sh # 跨平台

cd examples/mujuco-arm-so101
make env          # uv sync — 根据 uv.lock 创建 .venv 并安装锁定版本
make run-sim      # 启动 MuJoCo 交互式查看器
```

可用 target：

| 命令 | 作用 |
| --- | --- |
| `make env` | `uv sync` — 让 `.venv` 与 `uv.lock` 完全一致（幂等，毫秒级） |
| `make env-recreate` | 删除并重建 `.venv` |
| `make prepare-assets` | 从上游 menagerie 拉 19 个 STL（幂等） |
| `make lock` | `uv lock` — 改了 `pyproject.toml` 后重新生成 `uv.lock` |
| `make upgrade` | `uv sync --upgrade` — 在 `pyproject.toml` 版本范围内升级所有依赖 |
| `make run-sim` | `uv run python sim_so101.py viewer` |
| `make smoketest` | `uv run python sim_so101.py smoketest` |
| `make render` | `uv run python sim_so101.py render --steps 200 --out renders` |
| `make pick` | `uv run python pick_cube.py --out renders` |
| `make clean` | 删除 `.venv` 与 `renders/` |

可用环境变量覆盖：`make env PYTHON_VERSION=3.12 VENV=.venv312`。

### 不通过 Makefile 直接用 uv

```bash
cd examples/mujuco-arm-so101
uv sync                                       # 装锁定版本
uv run python sim_so101.py viewer             # 跑任意脚本
uv run mjpython sim_so101.py bridge --viewer  # macOS GUI bridge（详见下文）
uv add  "scipy>=1.14"                         # 加依赖（会自动重新生成 uv.lock）
uv remove pillow                              # 移除依赖
```

### 备选方案：纯手工 venv（不推荐，不锁版本）

```bash
cd examples/mujuco-arm-so101
python3 -m venv .venv
source .venv/bin/activate          # macOS / Linux
# .venv\Scripts\activate           # Windows PowerShell
pip install --upgrade pip
# 从 pyproject.toml 抠出依赖手动装
pip install "mujoco>=3.2.0" "numpy>=1.26" "pillow>=10.0"
```

依赖说明（pyproject.toml 里也有）：

| 包 | 用途 |
| --- | --- |
| `mujoco` | MuJoCo 物理引擎 + Python 绑定 + `mujoco.viewer` 交互查看器 |
| `numpy` | 数值/数组 |
| `pillow` | 离线渲染时把 numpy 图像写成 PNG |

> MuJoCo 3.x 已自带预编译的物理库与 OpenGL 渲染后端，无需另外下载 dmg / tar 安装包。

### 3. （可选）单独获取 SO-101 模型

`assets/so101/` 下已经包含运行所需的 XML + STL，无需任何额外下载。
若需自己更新到最新版，可执行：

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/google-deepmind/mujoco_menagerie.git
cd mujoco_menagerie && git sparse-checkout set robotstudio_so101
# 然后把 robotstudio_so101/{assets, so101.xml} 覆盖到 examples/mujuco-arm-so101/assets/so101/
```

---

## 二、运行仿真

`sim_so101.py` 提供三种模式，统一使用 `assets/so101/scene_pickplace.xml`。

### 模式 1：交互式 3D 查看器（GUI，推荐先试这个）

```bash
make run-sim                       # 推荐
# 或手动：
python sim_so101.py viewer
```

启动后会打开 `mujoco.viewer.launch_passive` 的窗口，默认相机为侧面第三视角。
内置快捷键：

| 操作 | 作用 |
| --- | --- |
| 鼠标左键拖拽 | 旋转 |
| 鼠标右键拖拽 | 平移 |
| 滚轮 | 缩放 |
| **Tab** | 在场景相机之间循环（`side_cam` → `front_cam` → `wrist_cam` → free） |
| **空格** | 暂停 / 继续物理仿真 |
| **退格 / Backspace** | 复位到 keyframe `home` |
| **Ctrl + 拖拽 body** | 直接施加扰动力（可以推动红色方块） |

仿真步长 `timestep = 0.005 s`，按真实时间播放。

### 模式 2：离线渲染（无显示器/服务器/批量出图）

把所有相机渲染成 PNG（默认 1280 × 720）：

```bash
make render                        # 推荐
# 或手动 / 自定义分辨率：
python sim_so101.py render --steps 200 --out renders
python sim_so101.py render --width 1920 --height 1080 --out renders_hd
```

输出文件：`renders/side_cam.png`、`renders/front_cam.png`、`renders/wrist_cam.png`。

### 模式 3：自检（确认环境/模型 OK）

```bash
make smoketest                     # 推荐
# 或手动：
python sim_so101.py smoketest
```

预期输出（关键项）：

```
nq / nv    : 13 / 12
nbody      : 11
nu (act.)  : 6
cameras    : ['side_cam', 'front_cam', 'wrist_cam']
actuators  : ['shoulder_pan', 'shoulder_lift', 'elbow_flex',
              'wrist_flex', 'wrist_roll', 'gripper']
red_cube z = 0.0200 m
OK
```

---

## 三、控制接口（写自己的策略）

6 个位置控制器（`<position>` actuator），按下面的顺序读写
`data.ctrl[i]`，弧度制：

| 索引 | 名称 | range (rad) |
| --- | --- | --- |
| 0 | `shoulder_pan` | -1.92 ~ 1.92 |
| 1 | `shoulder_lift` | -1.75 ~ 1.75 |
| 2 | `elbow_flex` | -1.69 ~ 1.69 |
| 3 | `wrist_flex` | -1.66 ~ 1.66 |
| 4 | `wrist_roll` | -2.74 ~ 2.84 |
| 5 | `gripper` | -0.17 ~ 1.75（+ 表示张开） |

最小可用样例：

```python
import mujoco, numpy as np
m = mujoco.MjModel.from_xml_path("assets/so101/scene_pickplace.xml")
d = mujoco.MjData(m)
mujoco.mj_resetDataKeyframe(m, d, mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_KEY, "home"))

for t in range(2000):
    d.ctrl[:] = np.array([0.0, -1.0 + 0.3*np.sin(t*0.005),
                          1.0, 0.0, 0.0, 0.5])
    mujoco.mj_step(m, d)

# 读 wrist_cam 图像
with mujoco.Renderer(m, height=480, width=640) as r:
    r.update_scene(d, camera="wrist_cam")
    rgb = r.render()  # numpy uint8 (480, 640, 3)
```

红色方块的 free joint 名称为 `red_cube_freejoint`，body 名 `red_cube`，
可通过 `data.qpos[joint_id : joint_id+7]` 读 (x,y,z,qw,qx,qy,qz) 状态。

### 自动抓取 demo（IK + 关节空间插值）

`pick_cube.py` 是一个完整的 pick demo，逻辑：

1. 加载场景，复位到 `home` keyframe。
2. 用阻尼最小二乘 IK 解出 3 个 Cartesian 路点（`gripperframe` site 在木块上方/上面/抬起处），并约束夹爪 outward 轴（site 局部 +X）对齐世界 -Z，让爪尖朝下。
3. 用 smoothstep 缓动在关节空间内插值，把 ctrl 平滑送到每个目标关节角；位置控制器 (`<position>` actuator) 自然完成跟踪。
4. 在 4 个阶段（approach / at_cube / grasped / lifted）分别截图保存。

直接运行：

```bash
make pick
# 输出：
#   final cube z = 0.1545  (table top is z = 0)
#   ✓ cube lifted off the table.
#   renders/pick_01_approach_side_cam.png
#   renders/pick_02_at_cube_side_cam.png
#   renders/pick_03_grasped_side_cam.png
#   renders/pick_04_lifted_side_cam.png
#   renders/pick_{side,front,wrist}_cam.png   # 最终姿态
```

想要换抓取目标，编辑 `assets/so101/scene_pickplace.xml` 里 `red_cube` 的 `pos`，
或在 `pick_cube.py` 里直接覆盖 `cube_pos`。

---

## 四、常见问题

- **macOS 上 `mujoco.viewer` 启动后窗口黑屏 / 卡死**：必须从 *terminal*（不是 nohup / launchd）启动；
  并保证 Python 是 universal2 / arm64 版（系统自带或 Homebrew Python 都可）。
- **`offscreen rendering not available` / 渲染崩溃**：在无显示器服务器上运行
  `render` 模式时，需要设置 `MUJOCO_GL=egl`（Linux + NVIDIA）或 `MUJOCO_GL=osmesa`（无 GPU）。
- **方块掉到桌子下面**：检查 `scene_pickplace.xml` 里 `red_cube` 的初始 `pos` 第三个分量
  是否 ≥ 立方体半边长 0.02。
- **要换桌面贴图 / 改桌子尺寸**：直接编辑 `scene_pickplace.xml` 里的 `<body name="table">` geom
  即可，不会影响 menagerie 的原始 `so101.xml`。

---

## 五、参考链接

- 官方模型仓库：<https://github.com/google-deepmind/mujoco_menagerie/tree/main/robotstudio_so101>
- SO-ARM 上游：<https://github.com/TheRobotStudio/SO-ARM100>
- RL lift 任务参考博客：<https://ggando.com/blog/so101-rl-lift>
- MuJoCo Python 文档：<https://mujoco.readthedocs.io/en/stable/python.html>
