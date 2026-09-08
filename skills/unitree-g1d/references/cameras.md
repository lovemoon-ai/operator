# 相机：可访问范围与照片

## 必须保留的用户纠正

**G1-D 底盘两颗深度相机不支持用户直接连接使用，只供内置导航程序使用。**

正确判断：
- 用户接口无深度主题/数据、通用 Web Portal 没有深度扫描消息，不能证明相机损坏或两颗都断开。
- health 中的 `depth camera disconnect` 是真实由底盘报告的警告；其具体原因和相机编号还需要原厂内部诊断。
- 本次诊断曾采到54条激光和108条基础传感器消息、零条深度消息；**“零深度消息→硬件故障”这一旧推断已被用户纠正，不能再引用为故障定论**。
- 报警没有可用设备编号时，不回答“左相机坏了”“两个都读不到”。
- 不拿其他 Slamware 自行集成方案的 publishDepthCamFrame 要求直接修改 G1-D 出厂导航；不向底盘伪造深度数据来消警。

## 相机分类

官网 G1-D 底盘列两颗深度相机；头部一套高清双目、手腕两颗高清相机另列。实物可能缺可选设备，先枚举。头部图像可用不说明底盘深度可用。

## 已实测头部链路

机器人端：
- 服务 teleimager.service
- 配置 /home/unitree/unitree_eai_environment/service/teleimager/cam_config_server.yaml
- Python /home/unitree/miniconda3/envs/tv/bin/python
- ZMQ SUB tcp://127.0.0.1:55555，订阅空前缀，CONFLATE=1
- 历史头部数据：原始 JPEG，解码480×1280×3，左右目并排，30fps配置，UVC类型，serial_number=01.00.00

`remote_probe.py capture-head` 会创建新的接收时间和独立文件。保存原始 frame 字节；不要生成或编辑图片冒充机器人实拍。时间标记是接收时间，除非帧协议提供硬件时间戳，不称相机曝光时间。

历史恢复：缺失的左右腕相机导致 teleimager 重启，备份后仅把两个 wrist 配置的 enable_zmq/enable_webrtc 设 false，头部设置保持。备份路径：
/home/unitree/unitree_eai_environment/service/teleimager/cam_config_server.yaml.before-camera-fix-20260907-230913

该修复只针对当时腕相机缺失，**不能当深度断连的修复**；下次若用户装了腕相机，不自动禁用。检查配置当前内容及服务日志，不覆盖整份配置。UVC 可通过 libusb 占用设备，/dev/video* 缺失本身也不是相机断开的证据。

## 前后照片与工具展示

- 同一任务第一段真正移动前保存 before；最终停稳后保存 after。
- 中断后续走仍保留原始 before；各段额外照片可以独立记录。
- 新任务不能固定引用历史 before.jpg。照片过暗只能报告图像质量，不能断言无障碍。
- 图片中有人、物体位置变化，可能来自现场人员移动，不单凭两张照片量化机器人位移。
- 单张图像不是实时防撞保障；实机运动还需要当前环境监控和适用保护。

Conductor 大输出可能截断。使用 image-chunk 返回 `chunk/offset/total_chars/sha256`，按 offset 拼接，确认长度及同一文件hash，再以工具支持的 image(dataURL) 展示。
只在 functions 内存组装，不在本地保存或使用本地 image 工具。必要时分批并发读取，各会话返回 session_id 时继续轮询，不把它当失败重复拍照。
