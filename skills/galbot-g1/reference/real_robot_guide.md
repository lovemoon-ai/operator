# Galbot G1 真机使用说明（数采 · 训练 · 部署）

> 来源：`workshop_web`（Galbot Workshop Deck）。本文覆盖从真机数据采集，到模型训练与真机部署的完整流程。

## 内容概要

1. **认识 Galbot** — 开箱与联网、机器人规格与传感器认知、HPU/XCU 与服务架构。
2. **数据采集** — 使用遥操主从臂完成真机数据采集，并在本地生成 MCAP 文件。
3. **数据转换与训练** — `galbot-mcap2lerobot` 把 MCAP 转成 LeRobot 数据集；再使用开源框架进行训练。
4. **真机部署** — 真机 Galbot SDK 的基础使用，以及部署客户端实际依赖的 SDK 读写接口。

---

## 1. 认识 Galbot

### 1.1 初识 Galbot G1 · 官方链接

- **开发者平台文档**（包含 G1、主从臂遥操设备使用说明和在线 SDK 文档）：<https://developer.galbot.com/>
- **Galbot SDK 下载地址**：<https://github.com/GalaxyGeneralRobotics/GalbotSDK>
- **G1 仿真模型文件**（URDF / MJCF / USD 等格式，适配 mujoco / isaac 等主流仿真平台）：<https://github.com/GalaxyGeneralRobotics/galbot_one_golf_description.git>

> 可用第三方工具 [URDF Studio](https://urdf.d-robotics.cc/gallery) 加载 G1 模型进行关节可视化。

#### Tips（重要）

1. 使用 Galbot 前，确保机器人周围没有障碍物，再旋开急停按钮进行控制。
2. 正式控制前，先在可视化软件中查看并理解各个关节运动的含义。
3. 腿部直立时，建议关节角比例设置为 `leg_joint1:leg_joint2:leg_joint3 = 1:3:2`。
4. 左臂和右臂保持相同的对称姿态时，对应关节角刚好互为相反数。
5. 遇到问题可咨询现场技术支持或查看[故障排查文档](https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/troubleshooting)。

#### 关节组列表

机器人关节组名称：`["head", "left_arm", "right_arm", "leg", "left_gripper", "right_gripper"]`

| 关节组名称 | 英文名 | 数量 | 关节名称列表 |
| --- | --- | --- | --- |
| 头部 | `head` | 2 | `head_joint1-2` |
| 腿部 | `leg` | 5 | `leg_joint1-5` |
| 左臂 | `left_arm` | 7 | `left_arm_joint1-7` |
| 右臂 | `right_arm` | 7 | `right_arm_joint1-7` |
| 左夹爪 | `left_gripper` | 1 | `left_gripper_joint1` |
| 右夹爪 | `right_gripper` | 1 | `right_gripper_joint1` |

### 1.2 机器人规格、安全与核心能力

**规格与安全**

- 整机约 85kg，双臂展开臂展约 1.9m，单臂额定负载约 5kg，防护等级 IP54，续航约 8 小时。
- 底盘最大速度 1.5m/s，操作禁区＝机器人运动可达范围，调试期间严禁进入。
- **急停按钮位于机身背部，按下即锁定运动（不断电），顺时针旋转解锁。**

**核心传感器与能力**

- 双目相机 + RGB/深度相机：视觉感知，是训练和部署的图像输入来源。
- 3D 激光雷达 + 超声传感器：导航与近距离避障。
- 双臂 7 自由度 + 末端夹爪/吸盘：完成抓取、搬运等操作动作。
- 折叠腿：可升降/折叠，兼具移动和收纳姿态。
- 底盘（可选）：360° 全向轮式底盘，提供移动能力。

### 1.3 开箱与开机

1. **开箱清点** — 检查机器人本体、随附充电器、防护泡沫和航空箱附件，确认无缺失、无损坏后再移动机器人。
2. **开机** — 先按下电池开关，确认电源指示灯点亮；再按下底盘前部整机开关机按钮，胸口屏亮起即为开机成功。

### 1.4 联网与 IP 记录

1. **连接 WiFi** — 在胸口屏进入「设置 → 网络」，选择课程 WiFi，输入密码并等待连接状态变为「已连接」。
2. **记录 Orin IP** — 切到「Network」标签页，记录 Orin 的 `wlan0` IP。后续 SSH、SDK 部署和推理客户端连接都使用这个地址。

### 1.5 架构认知：系统、通信与 SDK 的分层关系

用于建立调试视角：问题可能发生在应用代码、SDK、通信中间件、机载服务或底层硬件，不同层的排查入口不同。

**分层结构（自上而下）**

```
应用层  ── SDK API ──▶  Galbot SDK  ── Embosa: Topic/Service ──▶  HPU/Orin ⇄ XCU  ── 驱动/读取 ──▶  硬件层
```

- **应用层**：Workshop 脚本、VLA 推理客户端。开发者主要编写和调试这一层代码；它不直接控制电机，而是通过 SDK 发送请求。
- **Galbot SDK**：应用和底层能力之间的封装层，向上提供 Python API，向下调用感知、规划、控制、导航等机载服务。核心类：`GalbotRobot`、`GalbotMotion`、`GalbotNavigation`、`GalbotPerception`。
- **Embosa 通信**：机器人内部消息中间件。Topic 适合图像、状态等连续数据流；Service 适合状态查询、规划请求、控制确认等一次性请求。
- **HPU / Orin**：高性能计算单元。视觉感知、AI 推理、运动规划、导航和 VLA 部署主要运行在这里。
- **XCU**：实时控制计算单元，负责电机控制、关节执行、底层安全和确定性控制。**非必要不要直接修改 XCU 配置。**
- **硬件层**：双臂、腿部、夹爪、底盘、相机、雷达、超声等。SDK 指令最终会被转换成硬件可执行的动作或数据读取。

**关键提示**

- **Workshop 重点**：连接机器人、获取 RGB/同步观测、下发关节角、控制夹爪。
- **调试判断**：传感器/状态流优先看 Topic；控制/查询失败优先看 Service 和 SDK 日志。
- **部署提醒**：机器人侧 HPU/XCU 为 **ARM64**，PC 侧开发通常是 **x86_64**。

---

## 2. 数据采集

### 2.1 G1 遥操主从臂：数据采集的硬件基础

G1 遥操主从臂是配合银河通用 Galbot 机器人使用的遥操作设备，可实现 G1 全身关节遥操作，主臂与从臂等比例映射。

- 主臂（操作者持握）与从臂（机器人）关节一一对应、等比例映射。
- 可遥操作机器人 G1 全身关节，覆盖数据采集所需的动作范围。
- 广泛适用于机器人遥操作、数据采集、远程接管等场景。

### 2.2 硬件连接（主从臂、电脑、机器人）

- **主从臂**：电源延长线（DC 12V）供电，5M-USB 数据线（Type-A）连接电脑，用于主臂控制数据传输。
- **电脑**：网线（5m）连接机器人，接电脑充电器；建议另配移动固态硬盘导出数据。
- **机器人**：网线（5m）连接电脑，机器人充电器供电（电量充足时可不插电）。
- **电源**：主从臂电源、电脑充电器、机器人充电器均经地插 AC 220V + 5M 插排供电。
- **注意**：主臂 USB 数据线建议直插 PC 的 USB 端口，保证数据稳定，避免端口被其他串口通信占用。

### 2.3 启动电脑与主从臂，进入遥操任务

1. **启动配套电脑** — 确认硬件连接完成后开机。
2. **主从臂上电** — 拨动主从臂开机按钮，从「○」拨到「一」，完成主从臂上电启动。
3. **运行数采软件系统** — 电脑端登录 GALBOT 数采软件系统。
4. **进入遥操任务** — 进入已创建的遥操任务列表，选择任务开始操作。

### 2.4 遥操手柄常用按键与机器人状态对应关系

| 按键 | 功能说明 | 机器人状态 |
| --- | --- | --- |
| 左摇杆 | 上下控制躯干升降，左右控制底盘左转/右转 | 机器人升降、左转/右转 |
| 右摇杆 | 上下控制底盘前进/后退，左右控制底盘左/右平移 | 机器人前进/后退、左/右平移 |
| 左摇杆组合键 | 按住左摇杆，右摇杆控制头部上下俯仰和左右旋转 | 头部俯仰、左右旋转 |
| 右摇杆组合键 | 按住右摇杆，左摇杆左右控制腰部旋转，上下微调腰关节 | 腰部左右旋转、前后微调 |
| 急停键（左/右） | 单击急停，停止机械运动 | 机器人停止运动，姿态保持 |
| 手臂固定键（左） | 单击开始跟随遥操主臂运动，再次单击锁定 | 左臂跟随/锁定，锁定后主臂运动无效 |
| 手臂固定键（右） | 单击开始跟随遥操主臂运动，再次单击锁定 | 右臂跟随/锁定，锁定后主臂运动无效 |
| 轨迹记录键（左/右） | 长按 2s 开始录制；单击对数据分段；长按 2s 结束录制 | 语音播报"开始录制/成功/结束录制" |
| 轨迹取消键（左/右） | 录制中单击标记当前步骤为失败；长按 2s 取消本条数据（不上传） | 语音播报"失败/取消" |
| 扳机键（左） | 控制左夹爪闭合/张开，行程量对应夹爪开合量 | 左夹爪闭合/张开 |
| 扳机键（右） | 控制右夹爪闭合/张开，行程量对应夹爪开合量 | 右夹爪闭合/张开 |

### 2.5 遥操作过程：穿戴主臂，对齐姿态后再开始控制

1. **穿戴主臂** — 将小臂套进遥操主从臂 4 关节位置的松紧带里，握住手柄，使小臂能灵活带动 4 关节及其他关节运动。
2. **对齐姿态** — 将遥操主臂摆放到与机器人接近的姿态，减少启动瞬间的大幅跳变。
3. **手臂固定键启动** — 单击手臂固定键，等机器人手臂移动到跟遥操主臂完全一致后，即可控制机器人 7 个关节灵活运动，配合手柄按键对全身进行运动控制。

### 2.6 停止遥操与急停

**正常停止**

- 单击手臂固定键，即可停止手臂运动。
- 此时在电脑端的数采软件系统中，可以正常退出遥操。

**紧急停止**

- 遥操过程中发生任何异常或机器人不可控情况，立即拍机器人背部的「急停键」处理。
- 急停不会断电，只锁定运动；确认周边安全后再解锁恢复。

### 2.7 采集结果：本地 MCAP 文件

录制完成后，数采软件会在本地目录保存 `.mcap` 文件；后续数据转换和训练从这些文件开始。

| 文件 | 说明 |
| --- | --- |
| `FIN.mcap` | 数采原始保存文件，未做时间戳对齐，通常用于保留原始记录。 |
| `SYNC.mcap` | 完成时间戳对齐后的 MCAP 文件，**后续转换和训练通常使用这个文件**。 |
| `CANCELED.mcap` | 录制过程中按下取消录制后保存的文件，通常不作为训练数据使用。 |

---

## 3. 数据转换与训练

### 3.1 从 MCAP 转成 LeRobot（galbot-mcap2lerobot）

遥操采集软件录制的是 MCAP 格式，训练框架需要 LeRobot 数据格式。转换工具仓库：<https://github.com/GalaxyGeneralRobotics/galbot-mcap2lerobot>

**MCAP vs LeRobot**

| 维度 | MCAP（采集） | LeRobot（训练） |
| --- | --- | --- |
| 组织方式 | 按 topic 顺序记录消息流 | 按 episode + frame 组织成表 |
| 时间对齐 | 各 topic 独立时间戳，未对齐 | 每帧图像与状态严格对齐 |
| 存储形式 | 单一 `.mcap` 文件 | `*.parquet` + `*.mp4` + `*.json` |
| 能否直接训练 | 不能，需先解析 | 能，训练框架直接加载 |

**转换三步**

1. **解析 MCAP** — 按 topic 拆成图像缓冲区、状态缓冲区、相机内参缓冲区三类数据；用 MCAP 内嵌的 protobuf schema 动态解码。
2. **时间对齐** — 以主相机（默认前置头部左目）时间戳为基准帧率；关节状态线性插值，其余相机最近邻匹配，统一到 30fps。
3. **写入 episode** — 状态展开成 23 维向量、图像编码为 AV1 视频；多个 MCAP 并行处理后再合并、重排序号。

**Topic → 数据集字段映射**

| Topic | 数据集字段 | 分辨率 |
| --- | --- | --- |
| `/front_head_camera/left_color/image_raw` | `observation.images.front_head_camera_left_color` | 480×640（主时钟） |
| `/front_head_camera/right_color/image_raw` | `observation.images.front_head_camera_right_color` | 480×640 |
| `/left_arm_camera/color/image_raw` | `observation.images.left_arm_camera_color` | 480×640 |
| `/right_arm_camera/color/image_raw` | `observation.images.right_arm_camera_color` | 480×640 |
| `singorix/wbcs/sensor` | `observation.state` / `action` | 23 维关节状态 |

**State / Action 向量（23 维）**

拼接顺序：`leg(5) → head(2) → left_arm(7) → left_gripper(1) → right_arm(7) → right_gripper(1)`

| 分组 | 维度 | 索引区间 | 含义 |
| --- | --- | --- | --- |
| leg | 5 | [0, 5) | 底盘 / 腿部 |
| head | 2 | [5, 7) | 头部两自由度 |
| left_arm | 7 | [7, 14) | 左臂七关节 |
| left_gripper | 1 | [14, 15) | 左夹爪开合宽度 |
| right_arm | 7 | [15, 22) | 右臂七关节 |
| right_gripper | 1 | [22, 23) | 右夹爪开合宽度 |

**关键点**

- 合计 **23 维**，按固定顺序拼接；若维度错位，模型输出会驱动到错误关节。
- 夹爪原始值除以 1000，统一缩放为米级开合宽度，与真机 SDK 的夹爪指令（0~0.1 m）是同一套单位。
- 正因量纲一致，训练数据和真机部署天然对齐，无需二次换算。
- `action[t] = observation.state[t+1]`，最后一帧动作重复自身，是模仿学习最小闭环形式。

### 3.2 数据集产出结构（LeRobotDataset v2.1）

输出目录 `output_galbot/galbot_lerobot_dataset/` 下固定包含 `data/`、`videos/`、`meta/` 三部分，训练脚本按这套结构直接读取。

- **`data/`** — `chunk-000/episode_000000.parquet …`，每 episode 一个 parquet 文件，保存该 episode 每一帧的状态与动作。
- **`videos/`** — 按相机字段分文件夹，每个 episode 一段 mp4（AV1 编码，30fps）；4 路相机各自独立存放，与 parquet 里的帧序号一一对应。
- **`meta/`** — `info.json`（features/fps/robot_type）、`modality.json`（状态动作关节索引映射）、`episodes.jsonl`、`tasks.jsonl`、`episodes_stats.jsonl`。

**parquet 字段**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `timestamp` | float32 | 相对 episode 起始时间（秒） |
| `frame_index` | int64 | episode 内帧序号 |
| `index` | int64 | 全数据集全局帧序号 |
| `episode_index` | int64 | episode 编号 |
| `task_index` | int64 | 任务描述索引 |
| `observation.state` | list[float32] | 23 维关节位置 |
| `action` | list[float32] | 23 维动作（下一帧状态） |

### 3.3 模型训练

完成数据转换后，可基于 LeRobot 格式数据选择不同模型仓库进行训练；具体训练配置和命令以各仓库文档为准。

| 框架 | 说明 | 地址 |
| --- | --- | --- |
| LeRobot | Hugging Face 机器人学习数据集与策略训练工具链 | <https://github.com/huggingface/lerobot> |
| OpenPI | Physical Intelligence 开源的 VLA / 机器人策略训练与推理项目 | <https://github.com/Physical-Intelligence/openpi> |
| starVLA | 面向视觉语言动作模型训练和部署的开源项目 | <https://github.com/starVLA/starVLA> |
| RLinf | 用于强化学习和机器人策略训练的开源框架 | <https://github.com/RLinf/RLinf> |

- **训练代码示例**（基于 starVLA，展示如何将数采转换后的 LeRobot 数据适配加载）：<https://github.com/JackeyLa5/starVLA>
- **使用限制提示**：使用银河通用设备的选手，请避免使用其他商业公司的模型；仅允许使用非商用的研究机构 / 实验室模型，或自行研发的模型。

---

## 4. 真机部署

### 4.1 SDK 使用说明

本节讲客户端在推理时会直接或间接调用的 Galbot SDK 接口，而非部署客户端内部实现。

部署四步：
1. **选择部署方式** — 机器人端部署用于生产和低延迟；PC 端部署用于开发调试。
2. **初始化 SDK** — `GalbotRobot.init(enable_sensor_set, enable_sync_mode)` 建立通信与传感器接口。
3. **读取观测** — `get_rgb_data()` / `get_depth_data()` 用于单相机调试，`get_synced_observation()` 用于推理输入。
4. **下发动作** — `set_joint_positions()`、`set_gripper_command()`、`set_joint_commands()` 覆盖低频和流式控制。

#### 4.1.1 SDK 部署方式（机器人端 vs PC 端）

| 对比项 | 机器人端部署 | PC 端部署 |
| --- | --- | --- |
| 程序在哪里运行 | 机器人 HPU / Orin | 外部 PC |
| PC 是否需要装 SDK | 不需要 | 需要 |
| PC 如何访问 | 通过 `ssh` 登录机器人 | 通过网线连接机器人并配置有线网络 |
| 推荐用途 | 最终部署和真机演示 | 开发调试和快速迭代 |
| 适用场景 | 真机演示、低延迟控制、最终部署 | 开发调试、快速改代码、PC 侧工具链联调 |

- 机器人端部署官方文档：<https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/installation_robot_deployment>
- PC 端 Ubuntu 部署官方文档：<https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/installation_pc_ubuntu>

#### 4.1.2 `get_rgb_data()` — 获取单路 RGB 图像

```python
def get_rgb_data(camera_id: SensorType) -> dict
```

- **使用场景**：单相机联调、保存模型输入样例、检查相机画面是否遮挡、曝光异常或方向错误。
- **预期行为**：从指定 RGB 相机读取最新一帧彩色图像。成功时返回包含消息头、图像格式和压缩图像字节的字典。
- **注意事项**：相机必须在 `robot.init(enable_sensor_set)` 中启用。失败时返回空字典，部署客户端应跳过本轮推理。

**常用 RGB 相机**

| SensorType | Frame ID |
| --- | --- |
| `HEAD_LEFT_CAMERA` | `head_left_camera_color_optical_frame` |
| `HEAD_RIGHT_CAMERA` | `head_right_camera_color_optical_frame` |
| `LEFT_ARM_CAMERA` | `left_arm_camera_color_optical_frame` |
| `RIGHT_ARM_CAMERA` | `right_arm_camera_color_optical_frame` |

```python
# examples/python/galbot_robot/get_camera_data.py
from galbot_sdk.g1 import GalbotRobot, SensorType
import cv2, numpy as np, time

def decode_compressed_image(compressed_image):
    image_data = compressed_image["data"]
    if compressed_image["format"] == "rgb8":
        nparr = np.frombuffer(image_data, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if img is None:
            raise ValueError("Fail to Decode RGB Image")
        return img
    if compressed_image["format"] == "16UC1":
        depth_img = np.frombuffer(compressed_image["data"], dtype=np.uint16).copy()
        depth_img = depth_img.reshape((compressed_image["height"], compressed_image["width"]))
        return depth_img.astype(np.float32) / compressed_image["depth_scale"]
    raise ValueError(f"Unsupport data format: {compressed_image['format']}")

def main():
    robot = GalbotRobot()
    enable_sensor_set = {SensorType.LEFT_ARM_CAMERA, SensorType.LEFT_ARM_DEPTH_CAMERA}
    robot.init(enable_sensor_set)
    time.sleep(5)

    rgb_image_data = robot.get_rgb_data(SensorType.LEFT_ARM_CAMERA)
    if not rgb_image_data:
        print("No rgb image data!")
    else:
        img = decode_compressed_image(rgb_image_data)
        cv2.imwrite("rgb_image_data.jpg", img)

    robot.request_shutdown()
    robot.wait_for_shutdown()
    robot.destroy()

if __name__ == "__main__":
    main()
```

#### 4.1.3 `get_depth_data()` — 获取单路深度图像

```python
def get_depth_data(camera_id: SensorType) -> dict
```

- **使用场景**：检查目标物体距离、调试深度相机画面、验证抓取前的空间关系，或辅助排查视觉模型输入异常。
- **预期行为**：从指定深度相机读取最新深度图。成功时返回消息头、深度格式、缩放因子、图像宽高和压缩深度数据。
- **注意事项**：深度相机必须在 `robot.init(enable_sensor_set)` 中启用。深度值通常以 mm 或 m 表示，具体解释要结合 `format` 和 `depth_scale`。

**常用深度相机**

| SensorType | Frame ID |
| --- | --- |
| `LEFT_ARM_DEPTH_CAMERA` | `left_arm_camera_color_optical_frame` |
| `RIGHT_ARM_DEPTH_CAMERA` | `right_arm_camera_color_optical_frame` |

```python
# examples/python/galbot_robot/get_camera_data.py
from galbot_sdk.g1 import GalbotRobot, SensorType
import cv2, numpy as np, time

def decode_depth_image(image_data):
    depth_img = np.frombuffer(image_data["data"], dtype=np.uint16).copy()
    depth_img = depth_img.reshape((image_data["height"], image_data["width"]))
    return depth_img.astype(np.float32) / image_data["depth_scale"]

def main():
    robot = GalbotRobot()
    enable_sensor_set = {SensorType.LEFT_ARM_CAMERA, SensorType.LEFT_ARM_DEPTH_CAMERA}
    robot.init(enable_sensor_set)
    time.sleep(5)

    depth_data = robot.get_depth_data(SensorType.LEFT_ARM_DEPTH_CAMERA)
    if not depth_data or "data" not in depth_data:
        print("Depth camera not ready")
    else:
        depth_img_raw = decode_depth_image(depth_data)
        depth_img = cv2.normalize(depth_img_raw, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
        cv2.imwrite("depth_data.jpg", depth_img)

    robot.request_shutdown()
    robot.wait_for_shutdown()
    robot.destroy()

if __name__ == "__main__":
    main()
```

#### 4.1.4 `get_synced_observation()` — 获取同步观测（推理部署优先使用）

```python
def get_synced_observation(cameras: Sequence[SensorType], with_joint_state: bool = True) -> SyncedObservation
```

- **使用场景**：VLA 推理前构造 observation，一次读取多路相机和机器人关节状态，减少图像与状态之间的时间错位。
- **预期行为**：以 `cameras[0]` 作为锚定相机，其他相机帧和关节状态按最近邻时间戳对齐后返回。
- **注意事项**：初始化时必须启用同步模式 `robot.init(enable_sensor_set, True)`。输入无效或取数失败时返回 `None`。

**参数**

| 参数 | 类型 / 默认值 | 说明 |
| --- | --- | --- |
| `cameras` | `Sequence[SensorType]` | 需要同步的相机列表；第一个相机是时间戳锚点，且必须已启用。 |
| `with_joint_state` | `bool = True` | 是否包含按同一锚点时间戳匹配的最近邻关节状态。 |

```python
# examples/python/galbot_robot/get_synced_observation.py
import time
from galbot_sdk.g1 import (
    GalbotRobot, JointState, JointStateMessage, RgbData, SensorType, SyncedObservation,
)

NS_TO_MS = 1e-6

def main():
    robot = GalbotRobot()
    ok = robot.init(
        {SensorType.HEAD_LEFT_CAMERA, SensorType.LEFT_ARM_CAMERA, SensorType.RIGHT_ARM_CAMERA},
        True,  # enable_sync_mode
    )
    if not ok:
        robot.destroy(); return

    time.sleep(2)
    cameras = [
        SensorType.LEFT_ARM_CAMERA,   # anchor
        SensorType.RIGHT_ARM_CAMERA,  # nearest-neighbor
        SensorType.HEAD_LEFT_CAMERA,  # nearest-neighbor
    ]

    obs = robot.get_synced_observation(cameras, True)
    if not obs:
        robot.request_shutdown(); robot.wait_for_shutdown(); robot.destroy(); return

    rgb_map = obs.rgb_data_map
    anchor_frame = rgb_map.get(cameras[0], None)
    anchor_ts_ns = anchor_frame.header.timestamp_ns if anchor_frame is not None else None

    for cam in cameras:
        frame = rgb_map.get(cam, None)
        cam_ts_ns = frame.header.timestamp_ns if frame is not None else None
        # delta_to_anchor_ms = (cam_ts_ns - anchor_ts_ns) * NS_TO_MS

    joint_state = obs.joint_state
    joint_state_vec = joint_state.joint_state_vec if joint_state is not None else []
    for i, js in enumerate(joint_state_vec[:5]):
        print(js.joint_name, js.position, js.velocity, js.effort)

    robot.request_shutdown(); robot.wait_for_shutdown(); robot.destroy()

if __name__ == "__main__":
    main()
```

#### 4.1.5 `set_joint_positions()` — 设置关节目标角（低频点位控制）

```python
def set_joint_positions(joint_positions, joint_groups=[], joint_names=[],
                        is_blocking=True, speed_rad_s=0.2, timeout_s=15.0) -> ControlStatus
```

- **使用场景**：部署前回安全姿态、教学演示单组关节运动、模型闭环前低速验证一个小幅动作。
- **预期行为**：SDK 生成带速度限制的平滑轨迹，使指定关节移动到目标角度；阻塞模式下等待完成或超时。
- **注意事项**：不适合高频逐帧控制。`joint_positions` 数量必须与 `joint_names` 或 `joint_groups` 展开后的关节数量一致。

**参数**

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `joint_positions` | 必填 | 目标关节位置列表，单位 rad。 |
| `joint_groups` | `[]` | 关节组名称；未传 `joint_names` 时用于展开控制关节。 |
| `joint_names` | `[]` | 具体关节名称；提供后优先于 `joint_groups`。 |
| `is_blocking` | `True` | 是否等待运动完成或超时。 |
| `speed_rad_s` | `0.2` | 最大运动速度，单位 rad/s。 |
| `timeout_s` | `15.0` | 阻塞模式超时时间，单位 s。 |

```python
# examples/python/galbot_robot/set_joint_positions.py
import time
from galbot_sdk.g1 import GalbotRobot, ControlStatus

robot = GalbotRobot()
robot.init()
time.sleep(2)

# 用关节组控制
status = robot.set_joint_positions([0.2, 0.2], ["head"], [], True, 0.1, 10)
# 用关节名控制（优先）
status = robot.set_joint_positions([0.0, 0.0], [], ["head_joint1", "head_joint2"], True, 0.1, 10)
if status != ControlStatus.SUCCESS:
    print("Joint angle setting failed")

robot.request_shutdown(); robot.wait_for_shutdown(); robot.destroy()
```

#### 4.1.6 `set_gripper_command()` — 设置夹爪开口宽度（抓取类推理最常用）

```python
def set_gripper_command(end_effector, width_m, velocity_mps=0.03, effort=5, is_blocking=True) -> ControlStatus
```

- **使用场景**：模型输出夹爪宽度、固定抓取流程开合夹爪、验证训练数据中的 gripper 宽度与真机是否一致。
- **预期行为**：夹爪以给定速度和最大力限制移动到目标开口宽度，返回 `ControlStatus`；可用 `get_gripper_state()` 回读。
- **注意事项**：**G1 夹爪宽度范围为 0~0.12 m。MCAP 转换后的夹爪值已经是米，部署时不要再按毫米传入。**

**参数**

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `end_effector` | 必填 | `left_gripper` 或 `right_gripper`。 |
| `width_m` | 必填 | 目标夹爪开口宽度，单位 m，G1 范围 0~0.12。 |
| `velocity_mps` | `0.03` | 开合速度，单位 m/s，范围 (0, 0.2]。 |
| `effort` | `5` | 最大抓取力限制，范围 (0, 100]。 |
| `is_blocking` | `True` | 是否等待夹爪运动完成。 |

```python
# examples/python/galbot_robot/set_gripper_command.py
import time
from galbot_sdk.g1 import GalbotRobot, G1JointGroup, ControlStatus

robot = GalbotRobot()
robot.init()
time.sleep(2)

robot.set_gripper_command(G1JointGroup.left_gripper, 0.02, 0.05, 10, True)
robot.set_gripper_command(G1JointGroup.left_gripper, 0.1, 0.05, 10, True)

robot.request_shutdown(); robot.wait_for_shutdown(); robot.destroy()
```

#### 4.1.7 `set_joint_commands()` — 连续下发关节命令（执行 action chunk）

```python
def set_joint_commands(joint_commands, joint_groups=[], joint_names=[], time_from_start_s=0.0) -> ControlStatus
```

- **使用场景**：推理模型一次返回多步动作时，部署客户端按控制周期逐帧发送，形成连续控制。
- **预期行为**：接口面向高频指令流，不会从当前状态自动插值到第一帧目标，控制器会尽快驱动关节朝每帧目标移动。
- **注意事项**：第一条命令要避免与当前关节角差值过大。标准关节主要使用 `JointCommand.position`；夹爪 `position` 表示宽度。

**参数**

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `joint_commands` | 必填 | `JointCommand` 列表，顺序必须与目标关节顺序一致。 |
| `joint_groups` | `[]` | 要控制的关节组；未传 `joint_names` 时使用。 |
| `joint_names` | `[]` | 具体关节名称，优先于 `joint_groups`。 |
| `time_from_start_s` | `0.0` | 命令延迟执行时间；默认立即执行。 |

```python
# examples/python/galbot_robot/set_joint_commands_example.py
import time, math
from galbot_sdk.g1 import GalbotRobot, JointCommand

def head_high_frequency_control():
    control_frequency = 100.0  # Hz
    dt = 1.0 / control_frequency
    duration, amplitude, frequency = 4.0, 0.3, 0.5
    joint_groups, joint_names = ["head"], []

    joint_commands = [JointCommand(), JointCommand()]
    start_time = time.time()
    while True:
        current_time = time.time() - start_time
        if current_time > duration:
            break
        target_position = amplitude * math.sin(2 * math.pi * frequency * current_time)
        joint_commands[0].position = target_position
        joint_commands[1].position = target_position
        GalbotRobot().set_joint_commands(joint_commands, joint_groups, joint_names, 0.0)
        time.sleep(dt)

def main():
    robot = GalbotRobot()
    if not robot.init():
        return
    time.sleep(2)
    head_high_frequency_control()
    robot.request_shutdown(); robot.wait_for_shutdown(); robot.destroy()

if __name__ == "__main__":
    main()
```

#### 4.1.8 建图与导航（Mapping & Navigation）

- **建图入口**：建图属于上机准备流程，建议直接按官方例程完成地图采集、保存和验证。[官方建图与常规操作文档](https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/routine_operations)
- **导航接口**：地图可用后，在应用侧通过 SDK 的 `GalbotNavigation` 相关接口接入导航能力。[GalbotNavigation Python 示例](https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/examples_python#%E7%B1%BBgalbotnavigation)
- **部署关系**：导航通常负责把机器人移动到任务区域；到位后再切换到感知、关节控制、夹爪控制或 VLA 闭环执行。

| 接口 | 用途 |
| --- | --- |
| `nav.init()` | 初始化导航模块，必须在调用其他导航接口前完成。 |
| `nav.is_localized()` / `nav.get_current_pose()` | 确认机器人已在地图中定位，并读取当前地图位姿。 |
| `nav.check_path_reachability(goal, start)` | 导航前检查目标点是否可达。 |
| `nav.navigate_to_goal(...)` | 下发导航目标点，可阻塞或非阻塞执行。 |
| `nav.check_goal_arrival()` / `nav.stop_navigation()` | 轮询是否到达目标，或停止当前导航任务。 |

```python
from galbot_sdk.g1 import GalbotNavigation, GalbotRobot, ControlStatus, G1ControllerName
import numpy as np, time

nav = GalbotNavigation()
nav.init()
robot = GalbotRobot()
robot.init()

goal = np.array([0.5, 0.0, 0.0, 0, 0, 0.0, 1.0])

res = robot.switch_controller(G1ControllerName.CHASSIS_POSE_CTRL)
if res != ControlStatus.SUCCESS:
    raise RuntimeError("switch chassis controller failed")

nav.navigate_to_goal(goal, enable_collision_check=True, is_blocking=False, timeout=20)

start_time = time.time()
while not nav.check_goal_arrival():
    if time.time() - start_time > 20:
        nav.stop_navigation()
        raise TimeoutError("navigation timeout")
    time.sleep(0.5)

robot.request_shutdown(); robot.wait_for_shutdown(); robot.destroy()
```

#### 4.1.9 SDK 常用接口总结（推理部署客户端）

| 部署阶段 | SDK 接口 | 使用场景 | 预期行为 |
| --- | --- | --- | --- |
| 启动 | `init(enable_sensor_set, True)` | 启用模型需要的相机和同步观测。 | 初始化成功后才允许读写机器人。 |
| 图像输入 | `get_rgb_data(sensor)` | 单相机调试、保存样例帧。 | 返回压缩图像 dict。 |
| 深度输入 | `get_depth_data(sensor)` | 距离检查、几何感知和深度相机调试。 | 返回压缩深度图 dict，包含 format、depth_scale、宽高和 data。 |
| 同步输入 | `get_synced_observation(sensors, True)` | 推理前读取多相机和状态。 | 返回同步观测对象；为空则跳过本轮推理。 |
| 状态输入 | `get_joint_positions(...)` / 同步观测中的 `joint_state` | 构造模型 `observation.state`。 | 返回按关节名或关节组顺序排列的状态。 |
| 低频动作 | `set_joint_positions(...)` | 回初始姿态、单步验证。 | 按速度限制移动到目标角。 |
| 夹爪动作 | `set_gripper_command(...)` | 抓取/释放物体。 | 控制夹爪宽度、速度和力；可阻塞等待。 |
| 连续动作 | `set_joint_commands(...)` | 执行模型 action chunk。 | 逐帧发送 JointCommand，需要客户端控制周期。 |
| 退出 | `request_shutdown()` / `wait_for_shutdown()` / `destroy()` | 结束部署程序。 | 释放 SDK 连接和后台资源。 |

> SDK 还提供更多接口（关节/传感器状态查询、控制器权限管理、底盘与末端执行器、运动规划、导航、感知模块等）。完整参数与更多示例：[API Python 参考](https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/api_python_reference) · [Python 示例代码](https://developer.galbot.com/docs/SDK/1.9.0/g1/zh/examples_python)

### 4.2 网页控制工具（Web Debug Controller）

用于 SDK 调试的网页控制工具：通过 Web 控制机器人底盘运动，调用 SDK 查看图像、关节角等信息，并快速生成调试用到的数据。

- **仓库地址**：<https://github.com/JackeyLa5/galbot_controller_web>
- **工具定位**：适合开发调试阶段辅助定位问题，支持底盘运动控制、SDK 图像与关节角查看，并生成初始关节角、导航点位等调试数据。

### 4.3 真机部署（模型服务端 + 机器人客户端）

真机部署通常拆成模型服务端和机器人客户端；客户端通过 SDK 读取观测和执行动作，服务端负责模型推理，两者通过 **WebSocket** 通信完成闭环。

**模型服务端**

- 运行训练好的 VLA / policy 模型，接收机器人客户端发送的图像、关节状态和任务文本。
- 完成预处理、模型推理和动作后处理，返回可执行的 action chunk 或下一步目标动作。
- 通常部署在训练机器、GPU 工作站或具备推理能力的服务器上。

**机器人客户端**

- 运行在机器人 HPU / Orin 上，通过 Galbot SDK 读取相机图像、同步观测、关节状态等实时数据。
- 把 observation 发送给模型服务端，接收动作结果后调用 SDK 执行关节、夹爪或底盘控制。
- 客户端还负责动作初始化、控制频率、安全检查等部署侧逻辑。

**通信链路**

| 链路 | 方向 | 内容 |
| --- | --- | --- |
| WebSocket 请求 | 机器人客户端 → 模型服务端 | 图像、关节状态、任务文本、时间戳等 observation。 |
| WebSocket 响应 | 模型服务端 → 机器人客户端 | 模型预测动作、action chunk、调试信息或错误状态。 |
| SDK 读写 | 机器人客户端 → 机器人 | `get_synced_observation()` 读取观测，`set_joint_commands()` 执行动作。 |

- **客户端示例代码仓库**：<https://github.com/JackeyLa5/galbot_sdk_client_demo>
