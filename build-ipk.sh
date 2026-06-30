#!/bin/sh
# 手工组装 luci-app-webrtc-control 的 .ipk（纯文件包，无需 SDK / Docker）。
# 外层 gzip-tar + 内层 ustar（opkg busybox 解析器要求），用 macOS 自带 bsdtar 即可，产物在 ./dist/。
set -e

PKG=luci-app-webrtc-control
VER=1.0.2
REL=1

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/dist"
BUILD=$(mktemp -d)
DATA="$BUILD/data"
CTRL="$BUILD/control"
mkdir -p "$DATA" "$CTRL" "$OUT"

export COPYFILE_DISABLE=1   # 抑制 macOS ._AppleDouble

# ---------- data 树（安装后布局）----------
cp -a "$HERE/root/." "$DATA/"
mkdir -p "$DATA/www/luci-static"
cp -a "$HERE/htdocs/luci-static/." "$DATA/www/luci-static/"

# 目录与权限
find "$DATA" -type d -exec chmod 0755 {} +
find "$DATA" -type f -exec chmod 0644 {} +
chmod 0755 "$DATA/etc/init.d/webrtc-control" \
           "$DATA/etc/uci-defaults/40_luci-webrtc-control" \
           "$DATA/usr/libexec/rpcd/webrtc-control" \
           "$DATA/usr/share/webrtc-control/apply.sh" \
           "$DATA/usr/share/webrtc-control/resolve-stun.sh"

ISIZE=$(du -sk "$DATA" | awk '{print $1*1024}')

# ---------- control 文件 ----------
cat > "$CTRL/control" <<EOF
Package: $PKG
Version: $VER-$REL
Depends: libc, luci-base, firewall4, kmod-nft-core, resolveip
Source: package/$PKG
SourceName: $PKG
Section: luci
License: GPL-3.0-or-later
Maintainer: hongzhebin <hongzhebin079@gmail.com>
Architecture: all
Installed-Size: $ISIZE
Description: LuCI support for WebRTC Control (network-level anti IP-leak).
 Block WebRTC STUN/ICE at the router with nftables DPI, port and DNS
 filters; whitelist devices, scope by firewall zone, integrate with passwall.
 DNS layer needs dnsmasq-full (nftset); it self-disables otherwise.
EOF

printf '/etc/config/webrtc-control\n' > "$CTRL/conffiles"

cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload >/dev/null 2>&1
if [ -f /etc/uci-defaults/40_luci-webrtc-control ]; then
	( . /etc/uci-defaults/40_luci-webrtc-control ) >/dev/null 2>&1 && \
		rm -f /etc/uci-defaults/40_luci-webrtc-control
fi
exit 0
EOF

cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/webrtc-control stop >/dev/null 2>&1
/etc/init.d/webrtc-control disable >/dev/null 2>&1
exit 0
EOF

cat > "$CTRL/postrm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload >/dev/null 2>&1
exit 0
EOF

chmod 0755 "$CTRL/postinst" "$CTRL/prerm" "$CTRL/postrm"
chmod 0644 "$CTRL/control" "$CTRL/conffiles"

# ---------- 组装 ipk ----------
# 必须用 ustar 格式：opkg 的 busybox tar 解不了 macOS 默认的 pax 扩展头。
TAR="tar --format ustar --uid 0 --gid 0 --uname root --gname root"
$TAR -C "$CTRL" -czf "$BUILD/control.tar.gz" .
$TAR -C "$DATA" -czf "$BUILD/data.tar.gz" .
printf '2.0\n' > "$BUILD/debian-binary"

echo "inner archive sizes:"
ls -l "$BUILD/debian-binary" "$BUILD/control.tar.gz" "$BUILD/data.tar.gz"

IPK="$OUT/${PKG}_${VER}-${REL}_all.ipk"
rm -f "$IPK"

# 外层用 gzip-tar（经典 ipkg 格式）。OpenWRT/KWRT 的 opkg 是静态 busybox 解析器，
# 实测它要的是 tar.gz 外层而非 ar 归档；成员顺序固定 debian-binary→control→data，
# 同样用 ustar 避免 pax 扩展头。
$TAR -C "$BUILD" -czf "$IPK" ./debian-binary ./control.tar.gz ./data.tar.gz

rm -rf "$BUILD"
echo "built: $IPK"
ls -l "$IPK"
