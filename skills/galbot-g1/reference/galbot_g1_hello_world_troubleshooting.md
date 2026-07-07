# Galbot G1 跑通 Hello World 踩坑记录

> 目标：在 G1 机器人上用 Python SDK 写一个最简 hello world，让底盘前进 5cm（后续扩展为「前进 5cm → 后退 5cm → 原地顺时针转 30°」）。
>
> 结论：从「写脚本」到「真机真实运动」，机器人运行环境比预想复杂，前后解决了 **10 个问题**。本文逐个记录，供以后复现/排查。

## 环境速览

| 项 | 值 |
|---|---|
| 机器人 | G1，主机名 `galbot-xcu` |
| 连接 | `ssh root@172.16.63.24`（SSH 密钥 `~/.ssh/id_ed25519_dang217`） |
| 系统 | Ubuntu 18.04.5 LTS，aarch64 |
| 系统自带 Python | 3.6.9（不可用，见问题 3） |
| SDK | GalbotSDK V1.9.0，用 `linux-aarch64-gcc940` |
| 底盘服务 | `/data/bin/galbot_chassis_service`（常驻运行，SDK 的对接目标） |

**最终可用的运行环境（记住这三个路径即可）：**

- 解释器：`python3.8`
- `PYTHONPATH=/data/galbot/lib`
- `LD_LIBRARY_PATH=/data/galbot/lib:/data/lib`

机器人上已封装为启动器 `/data/galbot/run_hello.sh`，重跑只需：

```bash
ssh root@172.16.63.24 'cd /data/galbot && ./run_hello.sh hello_world_move_forward.py'
```

---

## 问题 1：机器人网络不通

**表现**
```
$ ssh root@172.16.63.24
ssh: connect to host 172.16.63.24 port 22: Operation timed out
$ ping -c3 172.16.63.24   # 100% packet loss
$ nc -z -w5 172.16.63.24 22 → PORT_22_CLOSED
```
本机 IP `172.16.53.221`，机器人 `172.16.63.24`，不在同一网段。

**原因**：机器人未开机/未联网，或本机未接入机器人所在网络（WiFi/网线/VPN）。

**解决步骤**
1. 确认机器人开机并联网。
2. 本机接入正确网络。
3. 复测连通：`ping -c3 172.16.63.24`，能通再继续。

---

## 问题 2：SSH 认证失败 & 免密登录

**表现**
```
root@172.16.63.24: Permission denied (publickey,password).
```
即使配了密钥，**默认 `ssh`（不带 `-i`）仍然失败**——因为本机有多把 key，默认会先试到被服务器拒绝的那把。

**原因**：机器人未配置该主机的免密；且默认 key 顺序不对。

**解决步骤**
1. 配一次免密（会提示输入一次机器人密码）：
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519_dang217.pub root@172.16.63.24
   ```
2. **之后所有 ssh/scp 必须显式指定该 key**：
   ```bash
   ssh -i ~/.ssh/id_ed25519_dang217 root@172.16.63.24
   ```
   逐个 key 测试可确认哪把有效（本例是 `id_ed25519_dang217`）。

> 附：连接时会有 `WARNING: connection is not using a post-quantum key exchange algorithm` 提示，纯属信息噪声，不影响功能，可忽略/过滤。

---

## 问题 3：Python 版本不匹配（3.6 vs 3.8+）

**表现**
```
$ python3 --version → Python 3.6.9
$ python3 -c "import galbot_sdk"
ModuleNotFoundError: No module named 'galbot_sdk'
```
SDK 的 Python 绑定文件只有 `cpython-38` ~ `cpython-314`：
```
galbot_sdk.cpython-38-aarch64-linux-gnu.so
galbot_sdk.cpython-39-...  ...  cpython-314-...
```
**没有 cpython-36**，所以系统自带的 Python 3.6 根本加载不了绑定。

**原因**：Ubuntu 18.04 自带 Python 3.6，而 SDK 要求 3.8–3.14。

**解决步骤**：官方源直接装 python3.8（无需第三方 PPA）：
```bash
ssh -i ~/.ssh/id_ed25519_dang217 root@172.16.63.24 \
  'DEBIAN_FRONTEND=noninteractive apt-get install -y python3.8 && python3.8 --version'
```

---

## 问题 4：部署 SDK 到机器人（rsync 失败 / 目录不存在）

**表现**
- 从 mac 用 rsync 推送报 `rsync: error: unexpected end of file`。
- scp 报 `remote mkdir "/data/galbot/lib/": No such file or directory`。

**原因**
1. zsh **不会对含空格的变量自动分词**，把 `ssh -o ... -i ...` 当成一个可执行文件名，导致 mkdir/rsync 的 `-e` 命令执行异常。
2. 远端目标目录 `/data/galbot/lib` 尚未创建（前面失败的 mkdir 也是栽在同一个变量分词问题上）。

**解决步骤**
1. 先建目录，**ssh 命令内联写全**（不要用 zsh 变量拼）：
   ```bash
   ssh -i ~/.ssh/id_ed25519_dang217 root@172.16.63.24 'mkdir -p /data/galbot/lib'
   ```
2. 用 scp 部署（比依赖远端 rsync 更稳）：
   ```bash
   LIB=galbot_sdk/linux-aarch64-gcc940/lib
   scp -q  -i ~/.ssh/id_ed25519_dang217 "$LIB"/libgalbot_sdk.so*   root@172.16.63.24:/data/galbot/lib/
   scp -qr -i ~/.ssh/id_ed25519_dang217 "$LIB"/python/galbot_sdk   root@172.16.63.24:/data/galbot/lib/
   ```

---

## 问题 5：缺 Fast-DDS 等 C++ 依赖（libfastcdr.so.2 等）

**表现**
```
ImportError: libfastcdr.so.2: cannot open shared object file: No such file or directory
```
`ldd libgalbot_sdk.so.1.9.0` 进一步显示一大串 not found：
`libfastcdr.so.2`、`libfastrtps.so.2.14`、`libboost_thread.so.1.71.0`、`libembosa*.so`、`libprotobuf.so.25`、`libopencv_*.so.409`、`libpcl_common.so.1.13` ……

**原因**：SDK 底层用 eProsima Fast-DDS 通信，还依赖 boost/protobuf/embosa/opencv/pcl。仓库的 `deps/` 只有清单不含二进制。但这些库**机器人上本就有**——常驻的 `galbot_chassis_service` 就在用，全部位于 `/data/lib`。

**解决步骤**：把 `/data/lib` 加进 `LD_LIBRARY_PATH`：
```bash
export LD_LIBRARY_PATH=/data/galbot/lib:/data/lib
```
加上后除 libstdc++ 外全部解析（libstdc++ 见问题 6）。

---

## 问题 6：libstdc++ 版本过低（缺 GLIBCXX_3.4.26）

**表现**
```
/usr/lib/aarch64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.26' not found
    (required by /data/galbot/lib/libgalbot_sdk.so.1.9.0)
```

**原因**：SDK 用 gcc 9.4 编译（路径名 `gcc940` 即此意），需要 `GLIBCXX_3.4.26`。Ubuntu 18.04 系统 libstdc++6 最高只到 8.4 / `GLIBCXX_3.4.25`。
**注意**：`apt install g++-9` **无效**——Ubuntu 每个系统只维护一个共享 `libstdc++6`，bionic 上限就是 8.4，装 g++-9 也不会升级它。

**解决步骤**：从更新的 Ubuntu（focal 20.04，gcc-10，含 `GLIBCXX_3.4.28 ⊇ 3.4.26`）取出 `libstdc++.so.6`，**隔离**放进 `/data/galbot/lib`，只给本进程用，**不替换系统库**（避免影响正在运行的底盘服务）：
```bash
cd /tmp
base=http://ports.ubuntu.com/ubuntu-ports/pool/main/g/gcc-10/
deb=$(curl -s "$base" | grep -oE 'libstdc\+\+6_10[^"]*_arm64\.deb' | sort -u | tail -1)
curl -sO "$base$deb"
dpkg-deb -x "$deb" lsx
# ⚠ 只取真正的 .so，别抓到同名的 *-gdb.py 脚本
so=$(find lsx -path '*aarch64-linux-gnu*' -name 'libstdc++.so.6.0.28' -type f)
cp "$so" /data/galbot/lib/
ln -sf libstdc++.so.6.0.28 /data/galbot/lib/libstdc++.so.6
# 校验
strings /data/galbot/lib/libstdc++.so.6 | grep GLIBCXX_3.4.26   # 应有输出
```
> 小坑：`find ... -name "libstdc++.so.6.0.*"` 会先匹配到 `libstdc++.so.6.0.28-gdb.py`（一个 Python 脚本），务必用 `-type f` 且限定路径 `aarch64-linux-gnu` 取真正的 ELF。

至此 `import galbot_sdk` 成功（`IMPORT_OK`），`robot.init()/nav.init()` 返回 True，`get_odom()` 能读到实时数据。

---

## 问题 7：pip 引导失败（缺 distutils）

**表现**
```
$ python3.8 get-pip.py
ModuleNotFoundError: No module named 'distutils.cmd'
$ python3.8 -m pip ... → No module named pip
```

**原因**：apt 装的 `python3.8` 是精简包，不含 `distutils`，get-pip 依赖它。

**解决步骤**：
```bash
apt-get install -y python3.8-distutils
curl -sO https://bootstrap.pypa.io/pip/3.8/get-pip.py   # 3.8 专用引导
python3.8 get-pip.py
```

---

## 问题 8：缺 numpy（move_straight_to 内部依赖）

**表现**
```
File "hello_world_move_forward.py", line 32, in <module>
    nav.move_straight_to(target, ...)
ModuleNotFoundError: No module named 'numpy'
```
即使把参数从 `np.array` 改成普通 Python list 也一样报错。

**原因**：`move_straight_to` 内部会对参数做 `np.asarray`，因此**即便传 list 也强制依赖 numpy**（比 `set_base_velocity` 严格，后者可直接吃 list）。

**解决步骤**（承问题 7 已装好 pip）：
```bash
python3.8 -m pip install numpy      # 拉 aarch64 manylinux wheel，自带 OpenBLAS
python3.8 -c "import numpy; print(numpy.__version__)"   # 1.24.4
```

---

## 问题 9：API 报成功但机器人不动（WAIT_INITIALIZED）★关键★

**表现**：脚本打印「到达目标」，但里程计几乎没变（位移 0.0mm）。捕获返回值后真相大白：
```
move_straight_to RETURN -> (False, 'WAIT_INITIALIZED')
nav status: NavigationTaskStatus.UNKNOWN
delta x = 0.0000 m
```
之所以「看起来成功」，是因为**原脚本没检查返回值**，无论结果都打印了「到达目标」。

**原因**：运动前**导航子系统必须先就绪（`is_localized`）**，否则指令被拒，返回 `WAIT_INITIALIZED`。

**解决步骤**：切控制器后、运动前，先重定位循环（把当前位姿设为原点），并且**务必检查返回值**：
```python
init_pose = np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0])
t0 = time.time()
while not nav.is_localized():
    nav.relocalize(init_pose)
    time.sleep(0.5)
    if time.time() - t0 > 15:
        sys.exit("重定位超时")

ok, status = nav.move_straight_to(target, is_blocking=True, timeout=20)
if not ok:
    sys.exit(f"运动失败: {status}")
```
加上后：`move_straight_to RETURN -> (True, 'SUCCESS')`，实测里程计位移 41.7mm ≈ 5cm，机器人**真实前进**。

---

## 问题 10：异常时段错误（Segmentation fault）

**表现**：脚本抛异常后（如问题 8/9），进程以
```
Segmentation fault
```
退出（exit code 139）。

**原因**：异常跳过了正常关闭流程（`request_shutdown`/`wait_for_shutdown`/`destroy`），SDK 上下文被强拆，在解释器退出阶段析构时崩溃。

**解决步骤**：把动作包在 `try/finally` 里，**保证无论成败都执行清理**：
```python
robot = GalbotRobot(); robot.init()
nav = GalbotNavigation(); nav.init()
try:
    # ... 切控制器 / 重定位 / 运动 ...
finally:
    robot.request_shutdown()
    robot.wait_for_shutdown()
    robot.destroy()
```

---

## 问题 11：偶发失败 —— is_localized 为 True 但仍 WAIT_INITIALIZED（竞态）★关键★

**表现**：同一个脚本**有时成功、有时失败**，且失败总发生在**第一条**运动指令：
```
导航已就绪 (is_localized)
前进 10 厘米 ...
  结果: success=False, status=WAIT_INITIALIZED
  前进 10 厘米 失败，终止。
```
（注意：这里 `is_localized()` 已经是 True，却仍返回 `WAIT_INITIALIZED`。）

**原因**：**时序竞态**。`is_localized()` 为 True 只代表“定位就绪”，但 `switch_controller` / `relocalize` 之后，**导航运动执行器仍在异步初始化**。定位一 True 就立刻下发第一条指令时：
- 系统“热”（上次刚跑过，已 warm-up）→ 被接受 → 成功；
- 系统“冷”（刚开机 / 控制器刚切换）→ 执行器没准备好 → 返回 `WAIT_INITIALIZED`。
所以偶发，且第一条指令最易中招。**问题 9 只解决了“忘记 relocalize”，本问题是 relocalize 之后仍存在的更深一层竞态。**

**解决步骤**：`WAIT_INITIALIZED` 表示指令**根本没执行**（机器人没动），因此可安全重试。把它当作“稍后重试”而非硬失败，直到就绪或超时：
```python
def move(nav, target, desc, timeout=20, ready_timeout=15, retry_gap=0.5):
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
        nav.stop_navigation()
        sys.exit(f"  {desc} 失败: {status}")
```
实测：冷启动时第一条指令命中一次 `WAIT_INITIALIZED`，0.5s 后重试即 `SUCCESS`，不再误终止。

> 提示：重试仅对 `WAIT_INITIALIZED`（未执行）安全；其它失败状态不要盲目重试。

---

## 运动 API 备忘（非报错，但易踩）

- `nav.move_straight_to([x,y,z,qx,qy,qz,qw], is_blocking, timeout)`：
  - 目标位姿**相对当前 base_link**（odom 系，单位米），**不做避障**——运行前确保周围无障碍。
  - 每次都相对当前位姿，因此多段动作顺序执行即可自然叠加。
  - 经验证**既能平移也能原地旋转**（纯朝向变化即原地转）。
  - 返回 `(success: bool, status: str)`，**必须检查**。
- 运动前必须 `robot.switch_controller(G1ControllerName.CHASSIS_POSE_CTRL)`。
- **旋转方向**：绕 +Z 轴，俯视逆时针为正 yaw，顺时针为负（REP-103）。顺时针 30° → `yaw=-30°`，四元数 `[0,0,sin(-15°),cos(-15°)]=[0,0,-0.2588,0.9659]`。实测朝向精确落在 -30.0°。
- 短距离开环运动存在控制容差/里程计漂移（如「前进 5cm→后退 5cm」净位移未必精确为 0）；需要精确回位可改用闭环的 `nav.navigate_to_goal(绝对目标点)`。

---

## 一次性环境搭建脚本（把问题 3~8 串起来）

在机器人上执行（已联网）：
```bash
# 3) python3.8
apt-get install -y python3.8 python3.8-distutils
# 7~8) pip + numpy
cd /tmp && curl -sO https://bootstrap.pypa.io/pip/3.8/get-pip.py && python3.8 get-pip.py
python3.8 -m pip install numpy
# 6) 从 focal 取 libstdc++.so.6.0.28（GLIBCXX_3.4.26）隔离放入 /data/galbot/lib
base=http://ports.ubuntu.com/ubuntu-ports/pool/main/g/gcc-10/
deb=$(curl -s "$base" | grep -oE 'libstdc\+\+6_10[^"]*_arm64\.deb' | sort -u | tail -1)
curl -sO "$base$deb" && dpkg-deb -x "$deb" lsx
cp "$(find lsx -path '*aarch64-linux-gnu*' -name 'libstdc++.so.6.0.28' -type f)" /data/galbot/lib/
ln -sf libstdc++.so.6.0.28 /data/galbot/lib/libstdc++.so.6

# 启动器：封装 4~6 的运行环境
cat > /data/galbot/run_hello.sh <<'EOF'
#!/bin/bash
export PYTHONPATH=/data/galbot/lib
export LD_LIBRARY_PATH=/data/galbot/lib:/data/lib:$LD_LIBRARY_PATH
exec python3.8 "$@"
EOF
chmod +x /data/galbot/run_hello.sh
```
（SDK 库本身用 problem 4 的 scp 从开发机推到 `/data/galbot/lib`。）
