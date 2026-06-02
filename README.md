
## Develop

从 clone 到跑通端到端测试：

```bash
# 1. 拉取代码与子模块
git clone https://github.com/lovemoon-ai/operator
git submodule update --init --recursive

# 2. 安装测试依赖（macOS 示例）
brew install ffmpeg mediamtx android-platform-tools

# 3. 构建 Robot 侧（Rust）
cd robot && cargo build --release -p xr-bridge

# 4. 构建并安装 XR APK 到 Quest（首次需要）
cd ../xr && make build && make install

# 5. 跑端到端视频测试（需 Quest 连 adb 并开启开发者模式）
cd ..
bash tests/01_rtsp_test.sh --launch-app
```
