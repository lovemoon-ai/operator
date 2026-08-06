#!/usr/bin/env bash
#
# Quest Pose Inference command sheet.
# Copy each block into a separate terminal. Do not run this file top to bottom,
# because both journalctl and make ship-quest keep following live logs.

# Terminal 1: restart the server and watch pose data.
cd /home/evophys/code/operator
sudo systemctl restart pose-inference.service
sudo journalctl -u pose-inference.service -f -o cat

# Open this URL in a browser and scan its QR code from Quest:
# http://10.10.99.72:63920/

# Terminal 2: verify Quest, rebuild/install the APK, and launch Pose Inference.
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME="$HOME/.local/share/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK="$ANDROID_HOME/ndk/28.1.13356709"
export PATH="$HOME/.local/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
cd /home/evophys/code/operator/xr
adb devices
make ship-quest MODE=pose_inference
