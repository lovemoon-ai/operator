# 官方来源与样例定位

本次阅读日期 2026-09-08。以下main分支URL会变；实际执行前核对本机SDK版本和源码，不因线上接口存在就宣称本机支持。未将本机SDK提交版本与线上main做过一致性验证。

## 宇树

- G1-D产品规格（底盘双深度与头/腕相机分别列项）：
  https://www.unitree.com/G1-D
- G1-D手臂例程（LowCmd/LowState、关节映射、CRC）：
  https://github.com/unitreerobotics/unitree_sdk2/blob/main/example/g1/g1d/g1d_arm_example.cpp
- G1-D升降高度闭环例程：
  https://github.com/unitreerobotics/unitree_sdk2/blob/main/example/g1/g1d/g1d_height_control.cpp
- G1-D AGV例程：
  https://github.com/unitreerobotics/unitree_sdk2/blob/main/example/g1/g1d/g1_agv_client_example.cpp
- AgvClient头文件（Move与HeightAdjust的不同单位）：
  https://github.com/unitreerobotics/unitree_sdk2/blob/main/include/unitree/robot/g1/agv/g1_agv_client.hpp
- XR遥操作官方工程，仅作架构背景，不意味着所有版本支持本机G1-D：
  https://github.com/unitreerobotics/xr_teleoperate
- 宇树文档中心：
  https://support.unitree.com/main/en
  本次访问详细文档时返回567/Access Restricted。不能声称已经读到G1-D完整维修接线手册，也不要绕过访问限制。

## 思岚

- 官方REST定义：
  https://docs-en.slamtec.com/opt/swagger-conf.json
  本机同版本定义曾可从 http://192.168.123.163:1448/js/spec.js 读取；优先确认本机支持的路径/请求格式。
- Web Portal默认登录、基础诊断：
  https://wiki.slamtec.com/display/SD/KBSW180153+SLAMWARE+Web+Portal+Function+Overview+1
- Web Portal新版说明、Debug Access与固件注意：
  https://wiki.slamtec.com/display/SD/KBSW200811+SLAMWARE+Web+Portal+Function+Overview+2
- 自行集成深度相机（仅集成方案参考，不是G1-D用户访问许可）：
  https://wiki.slamtec.com/pages/viewpage.action?pageId=32342031
- Athena2.0等手册资料入口：
  https://wiki.slamtec.com/display/SD/Overseas+Help+Center
  Athena2.0不是这台定制ares2-ys，不拿其端口图或参数直接改G1-D。

## 研究方式

遵守远程约束：在远程Ubuntu用HTTP或浏览器阅读官方页面、GitHub源码、公开Confluence API及PDF；下载资料只保存远程。
本次Google在远程不可达、Bing曾返回无关结果、百度要求验证；不要把请求成功当搜索证据，也不要拿无关结果凑结论。官方GitHub也未找到与此台G1-D完全对应且已验证的深度报警修复案例。

## 证据冲突优先处理

本会话用户提供了G1-D底盘深度相机仅供内部导航的产品使用约束。一般Slamware手册介绍可集成深度相机，不推翻这个特定产品约束。若将来厂家明确提供新的正式接口，再核对机型/固件并更新技能。
