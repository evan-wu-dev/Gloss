#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Gloss.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# 用固定证书签名：ad-hoc 签名每次构建身份都变，辅助功能授权会失效要重新勾选。
SIGNING_IDENTITY="${SIGNING_IDENTITY:-7D27009940D2F162DF9A11BC72748C2591BFD0A9}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gloss-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP_DIR/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
    "$PROJECT_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/Gloss" \
    -framework AppKit -framework Carbon -framework ApplicationServices -framework AVFoundation -framework NaturalLanguage -framework SwiftUI -framework ServiceManagement
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Gloss</string>
<key>CFBundleIdentifier</key><string>local.wufan.live-translate</string>
<key>CFBundleName</key><string>Gloss</string>
<key>CFBundleDisplayName</key><string>Gloss</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSHasLocalizedDisplayName</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# 应用图标：assets/AppIcon-1024.png 缩出各尺寸，打成 icns。
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP_DIR/Contents/Resources"
for size in 16 32 128 256 512; do
    sips -z $size $size "$PROJECT_DIR/assets/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$PROJECT_DIR/assets/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
# 显示名：中文系统叫「字里行间」，其他语言叫 Gloss。
for lang in en zh-Hans zh-Hant ja ko es fr de; do
    name="Gloss"
    [[ "$lang" == zh-* ]] && name="字里行间"
    mkdir -p "$APP_DIR/Contents/Resources/$lang.lproj"
    printf 'CFBundleDisplayName = "%s";\nCFBundleName = "%s";\n' "$name" "$name" > "$APP_DIR/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --verify --deep --strict "$APP_DIR"
"$APP_DIR/Contents/MacOS/Gloss" --self-test
printf 'Built: %s\n' "$APP_DIR"
