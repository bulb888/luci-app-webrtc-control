# SPDX-License-Identifier: GPL-3.0-or-later
#
# luci-app-webrtc-control
# 在 OpenWRT (fw4/nftables) 上于网络层拦截 WebRTC STUN/ICE，防止真实 IP 泄露。
# 目标平台：OpenWRT 22.03+ / KWRT 25.12（fw4 + LuCI JS 客户端）。

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for WebRTC Control (network-level anti IP-leak)
LUCI_DESCRIPTION:=Block WebRTC STUN/ICE at the router with nftables DPI, \
	port and DNS filters; whitelist devices, scope by firewall zone, \
	and integrate with passwall (force-through-proxy or drop).
LUCI_DEPENDS:=+firewall4 +kmod-nft-core +resolveip
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-webrtc-control
PKG_VERSION:=1.0.2
PKG_RELEASE:=1
PKG_MAINTAINER:=hongzhebin <hongzhebin079@gmail.com>
PKG_LICENSE:=GPL-3.0-or-later

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
