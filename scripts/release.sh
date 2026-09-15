#!/bin/bash
# 打包发布产物：dist/QoderBar-<version>.zip（可直接上传 GitHub Releases）
#
# 用法：
#   ./scripts/release.sh                  # 构建 + 打包（ad-hoc 签名）
#   SIGN_IDENTITY="Developer ID Application: Xxx (TEAMID)" ./scripts/release.sh
#                                         # 用 Developer ID 签名（hasardened runtime），便于后续公证
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-app.sh" release

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> 使用 Developer ID 签名（hardened runtime）"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" dist/QoderBar.app
    codesign --verify --verbose=2 dist/QoderBar.app
else
    echo "==> 未设置 SIGN_IDENTITY，使用 build-app.sh 的 ad-hoc 签名"
    echo "    提示：用户首次打开需右键 → 打开（或在 系统设置 → 隐私与安全性 中允许一次）"
fi

ZIP="dist/QoderBar-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent dist/QoderBar.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "==> 完成: $ROOT/$ZIP"
echo "    上传该 zip 到 GitHub Releases 即可；用户解压后拖入「应用程序」。"
