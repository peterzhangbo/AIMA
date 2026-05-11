#!/usr/bin/env bash
# 将 SwiftPM 可执行文件包装为 .app bundle，供 macOS TCC（麦克风/屏幕录制）授权。
# 用法: ./scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
BIN_NAME="SummaryMeetingApp"
PRODUCT_NAME="AIMA"
APP_DIR=".build/${CONFIG}/${PRODUCT_NAME}.app"

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH=".build/${CONFIG}/${BIN_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "✗ 未找到可执行文件: ${BIN_PATH}" >&2
  exit 1
fi

echo "→ 组装 ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"
# Python 辅助脚本（diarize.py 等）打包进 bundle，供 DiarizeRunner 定位
# 通过 Bundle.main.resourceURL/scripts/diarize.py 查找；用无 trailing slash 的源路径避免目录嵌套
cp -r scripts "${APP_DIR}/Contents/Resources/"

# AppIcon
if [[ -f scripts/make_icon.swift ]]; then
  swift scripts/make_icon.swift "${APP_DIR}/Contents/Resources/AppIcon.icns" >/dev/null
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>${PRODUCT_NAME}</string>
  <key>CFBundleName</key><string>${PRODUCT_NAME}</string>
  <key>CFBundleExecutable</key><string>${BIN_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.saul.aima</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.21</string>
  <key>CFBundleVersion</key><string>21</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>录制你的讲话以生成会议纪要。</string>
  <key>NSScreenCaptureUsageDescription</key><string>捕获会议中的系统音频（对端声音）。</string>
</dict>
</plist>
PLIST

# 清理扩展属性（避免 codesign "resource fork/Finder information" 报错）
xattr -cr "${APP_DIR}"

echo "→ 临时签名 (ad-hoc)"
codesign --force --deep --sign - "${APP_DIR}"

echo "✓ 完成: ${APP_DIR}"
echo "启动: open \"${APP_DIR}\""
