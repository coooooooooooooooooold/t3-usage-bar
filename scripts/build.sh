#!/bin/bash
# 编译 T3UsageBar：Intel + Apple 芯片通用版，最低 macOS 14，打包成 dist/T3UsageBar-版本号.zip（附 sha256）。
# 用法：./scripts/build.sh            （版本号默认 0.1.0）
#       VERSION=0.2.0 ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="T3UsageBar"
DISPLAY="T3 用量栏"
BUNDLE_ID="app.t3usagebar"
VERSION="${VERSION:-0.1.0}"
MIN_OS="14.0"

# 选一个和当前编译器匹配的 SDK：优先系统默认，编不过时可以手动指定 SDK=/path/to/MacOSX.sdk
SDK="${SDK:-$(xcrun --show-sdk-path)}"

BUILD=build; DIST=dist; APP="$BUILD/$NAME.app"
rm -rf "$BUILD" "$DIST"; mkdir -p "$BUILD" "$DIST" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  echo "编译 $ARCH …"
  swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos$MIN_OS" Sources/UsageBar.swift -o "$BUILD/UsageBar-$ARCH"
done
lipo -create "$BUILD/UsageBar-arm64" "$BUILD/UsageBar-x86_64" -output "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/logos "$APP/Contents/Resources/logos"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 没有 Apple 开发者证书，只做本地签名（ad-hoc）；别人第一次打开需要右键「打开」
codesign --force --deep -s - "$APP"

ZIP="$DIST/$NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
echo "完成：$ZIP（$(du -h "$ZIP" | cut -f1)）"
