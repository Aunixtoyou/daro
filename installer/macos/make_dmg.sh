#!/usr/bin/env bash
# 将 Flutter macOS 构建产物打包为 universal .dmg + .zip。
# 由 .github/workflows/release.yml 的 build-macos job 调用。
#
# 前置：已用 `flutter build macos --release --config-only` + `xcodebuild ARCHS="x86_64 arm64"`
#       生成通用二进制，产物位于 build/macos/dd/Build/Products/Release/daro.app。
#
# 用法：bash installer/macos/make_dmg.sh <版本号 x.y.z>
set -euo pipefail

VER="${1:?用法: make_dmg.sh <版本号>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PRODUCTS="build/macos/dd/Build/Products/Release"
APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' | head -n1)"
if [ -z "$APP" ]; then
  echo "ERROR: 未找到 .app，构建可能失败。查找路径: $PRODUCTS" >&2
  exit 1
fi
APP_NAME="$(basename "$APP")"          # daro.app
echo "找到应用: $APP"

# 构建时用了 CODE_SIGNING_ALLOWED=NO，arm64 必须至少有 ad-hoc 签名才能启动，这里补上。
echo "== > ad-hoc 签名 =="
codesign --force --deep --sign - "$APP"

mkdir -p release
OUT_ZIP="release/daro-${VER}-macos-universal.zip"
OUT_DMG="release/daro-${VER}-macos-universal.dmg"

echo "== > 生成 zip（保留符号链接 -y）=="
rm -f "$OUT_ZIP"
( cd "$(dirname "$APP")" && zip -r -y -q "$ROOT/$OUT_ZIP" "$APP_NAME" )

echo "== > 生成 dmg =="
rm -f "$OUT_DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "daro ${VER}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT_DMG" >/dev/null
rm -rf "$STAGE"

echo "== > 完成 =="
ls -lh release/daro-*macos*
