#!/bin/bash
# 构建 QoderBar.app
#
# 注意：默认 MacOSX27 SDK 把 SwiftUI 的 @State 等属性包装器宏化了，
# 但 Command Line Tools 未附带宏插件 (libSwiftUIMacros.dylib)，会导致
# "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"。
# 因此强制使用 MacOSX26.5 SDK 构建。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SDK" ]; then
    echo "错误：找不到 SDK $SDK" >&2
    echo "可用的 SDK：" >&2
    ls /Library/Developer/CommandLineTools/SDKs/ >&2
    exit 1
fi

CONFIG="${1:-release}"
echo "==> 构建 ($CONFIG, SDK: $(basename "$SDK"))"
SDKROOT="$SDK" swift build -c "$CONFIG"

BIN=".build/$CONFIG/QoderBar"
APP="dist/QoderBar.app"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QoderBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# 分发合规：随包附带许可证
cp LICENSE "$APP/Contents/Resources/LICENSE"

echo "==> 签名 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> 完成: $ROOT/$APP"
