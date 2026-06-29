#!/bin/bash
# SSRVPN Android 构建脚本
set -e
cd "$(dirname "$0")"

echo "=== 清理旧构建 ==="
flutter clean

echo "=== 获取依赖 ==="
flutter pub get

echo "=== 静态分析 ==="
flutter analyze

echo "=== 运行测试 ==="
flutter test

echo "=== 构建 Release APK ==="
flutter build apk --release

echo "=== 复制 APK 到项目根目录 ==="
cp build/app/outputs/flutter-apk/app-release.apk ./SSRVPN.apk

echo "=== 完成 ==="
echo "APK: $(pwd)/SSRVPN.apk"
ls -lh ./SSRVPN.apk
