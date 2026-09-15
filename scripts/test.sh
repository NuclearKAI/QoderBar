#!/bin/bash
# 运行单元测试（SDK 处理与 build-app.sh 相同）
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

export SDKROOT="$SDK"
# CLT 的 Testing.framework 与 lib_TestingInterop.dylib 不在默认搜索路径中，运行时需显式指定
export DYLD_FRAMEWORK_PATH="/Library/Developer/CommandLineTools/Library/Developer/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="/Library/Developer/CommandLineTools/Library/Developer/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# CLT 的 Testing 宏插件位于 plugins/testing 子目录，需额外加入插件搜索路径
PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGIN_DIR" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
fi
exec swift test "$@"
