#!/usr/bin/env bash
# 将 Flutter Linux 构建产物打包为 .deb 与 .tar.xz。
# 由 .github/workflows/release.yml 的 build-linux job 调用（GitHub ubuntu x64 runner）。
#
# 前置：flutter build linux --release 已完成，bundle 位于 build/linux/<arch>/release/bundle。
# 用法：bash installer/linux/package_linux.sh <版本号 x.y.z>
set -euo pipefail

VER="${1:?用法: package_linux.sh <版本号>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARCH_FLUTTER="x64"        # GitHub ubuntu runner 为 x64
ARCH_DEB="amd64"
BUNDLE="build/linux/${ARCH_FLUTTER}/release/bundle"
if [ ! -d "$BUNDLE" ]; then
  echo "ERROR: 未找到 bundle 目录: $BUNDLE" >&2
  exit 1
fi
if [ ! -x "$BUNDLE/daro" ]; then
  echo "ERROR: bundle 中缺少可执行文件 daro" >&2
  exit 1
fi

mkdir -p release
OUT_DEB="release/daro-${VER}-linux-${ARCH_DEB}.deb"
OUT_TAR="release/daro-${VER}-linux-${ARCH_FLUTTER}.tar.xz"

# ---- 1. 便携 tar.xz（解压后直接 ./daro 运行）----
echo "== > 生成 tar.xz =="
rm -f "$OUT_TAR"
TARSTAGE="$(mktemp -d)"
PKGDIR="$TARSTAGE/daro-${VER}-linux-${ARCH_FLUTTER}"
mkdir -p "$PKGDIR"
cp -R "$BUNDLE"/. "$PKGDIR"/
echo "运行方式：解压后执行 ./daro（依赖系统库 libgtk-3、libsqlite3）" > "$PKGDIR/README.txt"
tar -cJf "$OUT_TAR" -C "$TARSTAGE" "daro-${VER}-linux-${ARCH_FLUTTER}"
rm -rf "$TARSTAGE"

# ---- 2. .deb ----
echo "== > 生成 .deb =="
rm -f "$OUT_DEB"
ROOTFS="$(mktemp -d)"
install -d -m 0755 "$ROOTFS/DEBIAN"
install -d -m 0755 "$ROOTFS/opt/daro"
install -d -m 0755 "$ROOTFS/usr/bin"
install -d -m 0755 "$ROOTFS/usr/share/applications"
install -d -m 0755 "$ROOTFS/usr/share/icons/hicolor/256x256/apps"
install -d -m 0755 "$ROOTFS/usr/share/doc/daro"

cp -R "$BUNDLE"/. "$ROOTFS/opt/daro"/

cat > "$ROOTFS/DEBIAN/control" <<EOF
Package: daro
Version: ${VER}
Architecture: ${ARCH_DEB}
Maintainer: daro contributors <noreply@example.com>
Section: utils
Priority: optional
Depends: libgtk-3-0, libsqlite3-0
Homepage: https://github.com/SpringHgui/daro
Description: 轻量级桌面数据库管理工具
 A lightweight desktop database management tool built with Flutter.
 Supports MySQL/MariaDB, PostgreSQL, SQL Server, SQLite and Access(ODBC).
EOF

cat > "$ROOTFS/usr/bin/daro" <<'EOF'
#!/bin/sh
exec /opt/daro/daro "$@"
EOF
chmod 0755 "$ROOTFS/usr/bin/daro"

cat > "$ROOTFS/usr/share/applications/daro.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=daro
GenericName=Database Manager
Comment=轻量级桌面数据库管理工具
Exec=daro
Icon=daro
Terminal=false
Categories=Development;Database;
StartupWMClass=daro
EOF

# 从矢量 logo 渲染应用图标；转换失败也不阻塞打包（桌面会退回默认图标）。
SVG="assets/icons/app_logo.svg"
ICON="$ROOTFS/usr/share/icons/hicolor/256x256/apps/daro.png"
if command -v convert >/dev/null 2>&1 && [ -f "$SVG" ]; then
  if convert -background none -density 300 "$SVG" -resize 256x256 "$ICON" 2>/dev/null; then
    echo "已生成图标: $ICON"
  else
    echo "WARN: SVG 转 PNG 失败，跳过图标" >&2
    rm -f "$ICON"
  fi
else
  echo "WARN: 无 convert 或缺少 SVG，跳过图标" >&2
fi

printf 'See https://github.com/SpringHgui/daro\n' > "$ROOTFS/usr/share/doc/daro/README"

dpkg-deb --root-owner-group --build "$ROOTFS" "$OUT_DEB"
rm -rf "$ROOTFS"

echo "== > 完成 =="
ls -lh release/daro-*linux*
