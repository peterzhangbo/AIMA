#!/bin/bash
# build_release.sh — 构建生产版本 .app 并打包为 zip
# 用法：
#   ./scripts/build_release.sh                                                  # ad-hoc 签名（仅本机可运行）
#   SIGN_ID="Developer ID Application: ..." ./scripts/build_release.sh          # 开发者 ID 签名（别人能跑，但首启会有 Gatekeeper 警告）
#   SIGN_ID="..." NOTARY_PROFILE=AC_NOTARY ./scripts/build_release.sh           # 签名 + 公证 + staple（推荐分发）
#
# 公证前置：
#   1. 在 appleid.apple.com 创建 App-Specific Password
#   2. xcrun notarytool store-credentials "AC_NOTARY" \
#          --apple-id <Apple ID> --team-id <TEAMID> --password <app-specific-password>
#   之后只要传 NOTARY_PROFILE=AC_NOTARY 就能复用钥匙串里的凭据。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
cd "$ROOT"

APP_NAME="SummaryMeetingApp"         # 可执行文件名（保持不变，影响产物路径）
PRODUCT_NAME="AIMA"                  # 产品名（Dock / 菜单栏 / 窗口标题栏显示）
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo "dev")}"
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$PRODUCT_NAME.app"
ZIP_NAME="${PRODUCT_NAME}-${VERSION}.zip"

echo "→ swift build -c release"
swift build -c release

echo "→ 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/"
# 把 scripts 目录整体放到 Resources/scripts；DiarizeRunner 通过 Bundle.main.resourceURL/scripts/diarize.py 查找
cp -r scripts "$APP_DIR/Contents/Resources/"

# 生成并拷贝图标
echo "→ 生成 AppIcon.icns"
ICON_SRC="$ROOT/scripts/make_icon.swift"
ICON_OUT="$APP_DIR/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    swift "$ICON_SRC" "$ICON_OUT"
fi

# Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>       <string>com.aima.app</string>
    <key>CFBundleName</key>             <string>$PRODUCT_NAME</string>
    <key>CFBundleDisplayName</key>      <string>$PRODUCT_NAME</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleVersion</key>          <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
        <string>用于录制会议音频</string>
    <key>NSScreenCaptureUsageDescription</key>
        <string>用于采集系统音频（会议对端声音）</string>
    <key>LSUIElement</key>              <false/>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Entitlements（开发签名需要）
ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>              <false/>
    <key>com.apple.security.device.audio-input</key>       <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict>
</plist>
ENT

# 把 .app 复制到 /tmp（非 iCloud 路径）做签名/公证，避免 ~/Documents 的 iCloud Drive
# 持续给 bundle 添加 com.apple.FinderInfo / fileprovider.fpfs#P xattr 导致 codesign 失败。
WORK_DIR="$(mktemp -d)/release"
mkdir -p "$WORK_DIR"
echo "→ 将 .app 复制到 $WORK_DIR（绕过 iCloud Drive xattr）"
# ditto -X 显式跳过扩展属性 / ACL
/usr/bin/ditto --noextattr --noqtn "$APP_DIR" "$WORK_DIR/$PRODUCT_NAME.app"
# 兜底再清一次
xattr -cr "$WORK_DIR/$PRODUCT_NAME.app" 2>/dev/null || true
WORK_APP="$WORK_DIR/$PRODUCT_NAME.app"

# 签名
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$SIGN_ID" ]; then
    echo "→ 签名（Developer ID: $SIGN_ID）"
    # 公证要求：hardened runtime + secure timestamp
    codesign --force --deep --sign "$SIGN_ID" \
             --entitlements "$ENTITLEMENTS" \
             --options runtime \
             --timestamp \
             "$WORK_APP"
else
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "✗ NOTARY_PROFILE 已设置但缺少 SIGN_ID。公证必须用 Developer ID 签名。" >&2
        exit 1
    fi
    echo "→ ad-hoc 签名（本机运行）"
    codesign --force --deep --sign - \
             --entitlements "$ENTITLEMENTS" \
             "$WORK_APP"
fi

# 公证（可选）
if [ -n "$NOTARY_PROFILE" ]; then
    echo "→ 公证准备：打包临时 zip 提交"
    NOTARY_ZIP="$WORK_DIR/${PRODUCT_NAME}-notarize.zip"
    rm -f "$NOTARY_ZIP"
    # 用 ditto 打包以保留签名所需的属性（推荐做法）
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$NOTARY_ZIP"

    echo "→ 提交公证（profile: $NOTARY_PROFILE）— 这一步通常 1-3 分钟"
    if ! xcrun notarytool submit "$NOTARY_ZIP" \
             --keychain-profile "$NOTARY_PROFILE" \
             --wait; then
        echo "✗ 公证失败，可用以下命令查看最近一次提交日志：" >&2
        echo "    xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
        echo "    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
        rm -f "$NOTARY_ZIP"
        exit 1
    fi

    echo "→ Stapler 装订公证票据"
    xcrun stapler staple "$WORK_APP"
    xcrun stapler validate "$WORK_APP"

    rm -f "$NOTARY_ZIP"
fi

# 最终分发 zip：在 /tmp 里 ditto 打包（保留签名 + 票据），再把 zip 和 .app 都搬回 .build/release
echo "→ 打包 $ZIP_NAME"
TMP_ZIP="$WORK_DIR/$ZIP_NAME"
rm -f "$TMP_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$TMP_ZIP"

echo "→ 回搬产物到 $BUILD_DIR/"
rm -rf "$APP_DIR"
/usr/bin/ditto "$WORK_APP" "$APP_DIR"
mv "$TMP_ZIP" "$BUILD_DIR/$ZIP_NAME"

# 清理 /tmp 工作目录
rm -rf "$(dirname "$WORK_DIR")"

echo ""
echo "✓ 完成: $BUILD_DIR/$PRODUCT_NAME.app"
echo "  zip:   $BUILD_DIR/$ZIP_NAME"
echo "  版本:  $VERSION"
if [ -n "$NOTARY_PROFILE" ]; then
    echo "  状态:  已公证 + 装订（可分发，Gatekeeper 静默通过）"
elif [ -n "$SIGN_ID" ]; then
    echo "  状态:  已 Developer ID 签名（未公证；首启需右键打开）"
else
    echo "  状态:  ad-hoc 签名（仅本机可运行）"
fi
