#!/bin/sh
# WebRTC 控制：把 UCI 配置翻译成 nftables 规则。
#
#   apply.sh apply   读取 UCI，生成规则并加载（未启用则等同 clear）
#   apply.sh clear   移除全部规则
#
# 生成物：
#   /usr/share/nftables.d/ruleset-post/10-webrtc-control.nft   (fw4 每次 reload 自动加载)
#   /etc/crontabs/root 中一条 STUN 域名定时刷新任务
#
# DNS 层用自包含解析器（resolve-stun.sh）直接灌 nft 集合，
# 不依赖 dnsmasq —— 兼容 passwall 接管 DNS 的环境。

. /lib/functions.sh
. /lib/functions/network.sh

NFT_DIR=/usr/share/nftables.d/ruleset-post
NFT_FILE="$NFT_DIR/10-webrtc-control.nft"
RESOLVER=/usr/share/webrtc-control/resolve-stun.sh
CRON_FILE=/etc/crontabs/root
CRON_MARK="/usr/share/webrtc-control/resolve-stun.sh"

logmsg() { logger -t webrtc-control "$*"; }
ucg()    { uci -q get "webrtc-control.$1"; }

# 输入校验：白名单值会写进 nft 文件，必须校验，既挡注入也防非法值让整表加载失败。
# 先用 case 白名单字符集挡掉空格/大括号/分号等注入字符，再用正则校验格式。
valid_ipmask() { # IPv4/IPv6，可带 CIDR
	case "$1" in *[!0-9a-fA-F:./]*) return 1 ;; esac
	echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' && return 0
	case "$1" in *:*) echo "$1" | grep -qE '^[0-9a-fA-F:]+(/[0-9]{1,3})?$' && return 0 ;; esac
	return 1
}
valid_mac() {
	case "$1" in *[!0-9a-fA-F:]*) return 1 ;; esac
	echo "$1" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
}

# 取 WAN 出接口（IPv4 + IPv6 的 L3 设备）
get_wan_ifaces() {
	local n d out=""
	network_find_wan  n; network_get_device d "$n" && out="$out $d"
	network_find_wan6 n; network_get_device d "$n" && out="$out $d"
	echo $out
}

# 取某个防火墙 zone 的所有 L3 设备
zone_ifaces() {
	local zone="$1" sec net dev out=""
	for sec in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		[ "$(uci -q get firewall.$sec.name)" = "$zone" ] || continue
		for net in $(uci -q get firewall.$sec.network); do
			network_get_device dev "$net" && out="$out $dev"
		done
	done
	echo $out
}

# 空格分隔 -> 带引号逗号分隔（接口名集合，去重）
# 去重很重要：双栈时 wan 与 wan6 常解析到同一网卡，重复元素会让 nft -f 报错、整表加载失败。
ifset() {
	local first=1 e out=""
	for e in $(echo $1 | tr ' ' '\n' | sort -u); do
		[ -n "$e" ] || continue
		if [ "$first" = 1 ]; then out="\"$e\""; first=0; else out="$out, \"$e\""; fi
	done
	echo "$out"
}

# 空格分隔 -> 逗号分隔（IP / MAC 集合，去重）
plainset() {
	local first=1 e out=""
	for e in $(echo $1 | tr ' ' '\n' | sort -u); do
		[ -n "$e" ] || continue
		if [ "$first" = 1 ]; then out="$e"; first=0; else out="$out, $e"; fi
	done
	echo "$out"
}

# 声明一个 set（无论是否有元素都要声明，规则要引用）
emit_set() { # name type flags elements
	if [ -n "$4" ]; then
		echo "        set $1 { type $2;$3 elements = { $4 } }"
	else
		echo "        set $1 { type $2;$3 }"
	fi
}

# 维护 STUN 域名定时刷新的 cron 任务
set_cron() { # 1=启用 0=移除
	[ -f "$CRON_FILE" ] || touch "$CRON_FILE"
	sed -i "\|$CRON_MARK|d" "$CRON_FILE" 2>/dev/null
	if [ "$1" = "1" ]; then
		echo "*/30 * * * * $RESOLVER" >> "$CRON_FILE"
		/etc/init.d/cron enable >/dev/null 2>&1
		/etc/init.d/cron restart >/dev/null 2>&1
	else
		/etc/init.d/cron reload >/dev/null 2>&1
	fi
}

clear_all() {
	rm -f "$NFT_FILE"
	# fw4 reload 不会 flush 整个 ruleset，独立表得自己删
	nft delete table inet webrtc_control 2>/dev/null
	fw4 reload >/dev/null 2>&1
	set_cron 0
	logmsg "cleared"
}

apply_all() {
	local enabled mode dpi ports dns logopt all_zones
	enabled=$(ucg global.enabled);   [ -n "$enabled" ]   || enabled=0
	[ "$enabled" = "1" ] || { clear_all; return 0; }

	mode=$(ucg global.mode);         [ -n "$mode" ]      || mode=proxy
	dpi=$(ucg global.dpi);           [ -n "$dpi" ]       || dpi=1
	ports=$(ucg global.ports);       [ -n "$ports" ]     || ports=1
	dns=$(ucg global.dns);           [ -n "$dns" ]       || dns=1
	logopt=$(ucg global.log);        [ -n "$logopt" ]    || logopt=1
	all_zones=$(ucg global.all_zones); [ -n "$all_zones" ] || all_zones=1

	# 白名单：校验后按是否含冒号分流 v4 / v6（非法值跳过并记日志）
	local wl_ip4="" wl_ip6="" wl_mac="" item
	for item in $(ucg whitelist.ip); do
		valid_ipmask "$item" || { logmsg "跳过非法白名单 IP: $item"; continue; }
		case "$item" in
			*:*) wl_ip6="$wl_ip6 $item" ;;
			*)   wl_ip4="$wl_ip4 $item" ;;
		esac
	done
	for item in $(ucg whitelist.mac); do
		valid_mac "$item" || { logmsg "跳过非法白名单 MAC: $item"; continue; }
		wl_mac="$wl_mac $item"
	done

	# WAN 出接口
	local wanif; wanif=$(get_wan_ifaces)

	# 生效范围
	local tgtif="" z
	if [ "$all_zones" != "1" ]; then
		for z in $(ucg scope.zone); do
			tgtif="$tgtif $(zone_ifaces "$z")"
		done
		[ -n "$tgtif" ] || logmsg "warn: 已选范围但未解析到接口，本次不生效"
	fi

	# proxy 模式：仅丢弃从 WAN 直连出去的 STUN（被 passwall 代理的不经此路径）。
	# 检测不到 WAN 接口时退回全局拦截，避免静默失效。
	local wanq=""
	if [ "$mode" = "proxy" ] && [ -n "$wanif" ]; then
		wanq="oifname @wan_ifaces "
	elif [ "$mode" = "proxy" ]; then
		logmsg "warn: 未检测到 WAN 接口，proxy 模式退回全局拦截"
	fi

	local e_ip4 e_ip6 e_mac e_wan e_tgt
	e_ip4=$(plainset "$wl_ip4")
	e_ip6=$(plainset "$wl_ip6")
	e_mac=$(plainset "$wl_mac")
	e_wan=$(ifset "$wanif")
	e_tgt=$(ifset "$tgtif")

	mkdir -p "$NFT_DIR"
	{
		echo "# 由 webrtc-control apply.sh 自动生成，请勿手改"
		# 幂等惯用法：fw4 每次 reload 都会重新 include 本文件，
		# 但不会 flush 已存在的独立表；先建空表再删，确保每次都干净重建、不叠加规则。
		echo "table inet webrtc_control { }"
		echo "delete table inet webrtc_control"
		echo "table inet webrtc_control {"
		emit_set wl_ip4  ipv4_addr  " flags interval;" "$e_ip4"
		emit_set wl_ip6  ipv6_addr  " flags interval;" "$e_ip6"
		emit_set wl_mac  ether_addr ""                 "$e_mac"
		emit_set wan_ifaces    ifname "" "$e_wan"
		emit_set target_ifaces ifname "" "$e_tgt"
		echo "        set stun_block_ip4 { type ipv4_addr; flags timeout; }"
		echo "        set stun_block_ip6 { type ipv6_addr; flags timeout; }"
		echo "        chain forward {"
		echo "            type filter hook forward priority filter; policy accept;"
		echo "            ip saddr @wl_ip4 return"
		echo "            ip6 saddr @wl_ip6 return"
		echo "            ether saddr @wl_mac return"
		# 范围限定（fail-safe）：仅当真的解析到接口时才限定；
		# 否则不限定 = 对所有接口生效，避免配错时静默零防护。
		[ "$all_zones" != "1" ] && [ -n "$e_tgt" ] && echo "            iifname != @target_ifaces return"
		# 每层：可选的限速日志规则(防刷屏，10/分钟) + 始终丢弃规则。
		# 日志规则无 verdict，命中后落到下一条 drop 规则；限速超额时不命中、直接 drop 不记日志。
		if [ "$dpi" = "1" ]; then
			[ "$logopt" = "1" ] && echo "            ${wanq}meta l4proto udp @th,96,32 0x2112a442 limit rate 10/minute log prefix \"webrtc-drop-stun \""
			echo "            ${wanq}meta l4proto udp @th,96,32 0x2112a442 counter drop comment \"stun-dpi\""
		fi
		if [ "$ports" = "1" ]; then
			[ "$logopt" = "1" ] && echo "            ${wanq}udp dport { 3478, 5349, 19302-19309 } limit rate 10/minute log prefix \"webrtc-drop-port \""
			echo "            ${wanq}udp dport { 3478, 5349, 19302-19309 } counter drop comment \"stun-port\""
			[ "$logopt" = "1" ] && echo "            ${wanq}tcp dport { 3478, 5349 } limit rate 10/minute log prefix \"webrtc-drop-port \""
			echo "            ${wanq}tcp dport { 3478, 5349 } counter drop comment \"stun-port\""
		fi
		if [ "$dns" = "1" ]; then
			[ "$logopt" = "1" ] && echo "            ${wanq}ip daddr @stun_block_ip4 limit rate 10/minute log prefix \"webrtc-drop-dns \""
			echo "            ${wanq}ip daddr @stun_block_ip4 counter drop comment \"stun-dns\""
			[ "$logopt" = "1" ] && echo "            ${wanq}ip6 daddr @stun_block_ip6 limit rate 10/minute log prefix \"webrtc-drop-dns \""
			echo "            ${wanq}ip6 daddr @stun_block_ip6 counter drop comment \"stun-dns\""
		fi
		echo "        }"
		echo "    }"
	} > "$NFT_FILE"

	# 加载 nft 表（建好 set）
	fw4 reload >/dev/null 2>&1

	# DNS 层：自包含解析器填充 stun_block 集合 + cron 定时刷新（不依赖 dnsmasq）
	if [ "$dns" = "1" ]; then
		"$RESOLVER"
		set_cron 1
	else
		set_cron 0
	fi

	logmsg "applied (mode=$mode dpi=$dpi ports=$ports dns=$dns all_zones=$all_zones wan='$wanif')"
}

# 串行化：UI 保存、wan/wan6 双接口触发器可能近乎同时触发多次 reload，
# 并发跑会让 nft 表进入不一致状态。用 flock 确保同一时刻只跑一个。
exec 9>/tmp/webrtc-control.lock
flock -x 9

case "${1:-apply}" in
	apply) apply_all ;;
	clear) clear_all ;;
	*) echo "usage: $0 {apply|clear}"; exit 1 ;;
esac
