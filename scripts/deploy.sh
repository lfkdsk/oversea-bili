#!/bin/bash
# 部署脚本。
#   ./scripts/deploy.sh device      安装到已配对的 Apple TV(默认)
#   ./scripts/deploy.sh sim         安装到 tvOS 模拟器
#   ./scripts/deploy.sh testflight  归档并上传 App Store Connect(需 App Store Connect API key)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-device}"
SCHEME=OverseaBili
DEVICE_ID=00008110-0002055E0E92801E          # xcodebuild destination(客厅 Apple TV)
DEVICECTL_ID=976B8E0E-3497-5294-B757-C6C05FE5A173
SIM_ID=F2C780D4-8ACA-4944-8B6B-5F382DF0955E

xcodegen generate >/dev/null

case "$MODE" in
sim)
  xcodebuild -project $SCHEME.xcodeproj -scheme $SCHEME \
    -destination "platform=tvOS Simulator,id=$SIM_ID" \
    -derivedDataPath build/DerivedData build | grep -E "error:|BUILD" || true
  xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_ID" build/DerivedData/Build/Products/Debug-appletvsimulator/$SCHEME.app
  xcrun simctl launch "$SIM_ID" com.lfkdsk.$SCHEME "${@:2}"
  ;;
device)
  xcodebuild -project $SCHEME.xcodeproj -scheme $SCHEME \
    -destination "platform=tvOS,id=$DEVICE_ID" \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
  xcrun devicectl device install app --device "$DEVICECTL_ID" \
    build/DerivedData/Build/Products/Debug-appletvos/$SCHEME.app
  xcrun devicectl device process launch --device "$DEVICECTL_ID" com.lfkdsk.$SCHEME
  ;;
testflight)
  # 构建号取当前时间,保证每次上传递增
  BUILD_NUMBER=$(date +%Y%m%d%H%M)
  xcodebuild -project $SCHEME.xcodeproj -scheme $SCHEME \
    -destination "generic/platform=tvOS" \
    -archivePath build/$SCHEME.xcarchive \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE" || true
  xcodebuild -exportArchive \
    -archivePath build/$SCHEME.xcarchive \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath build/export \
    -allowProvisioningUpdates
  echo "已上传 build $BUILD_NUMBER,到 App Store Connect 查看处理进度"
  ;;
*)
  echo "用法: $0 [device|sim|testflight]" >&2
  exit 1
  ;;
esac
