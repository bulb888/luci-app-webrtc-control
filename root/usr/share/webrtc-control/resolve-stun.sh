#!/bin/sh
# 解析 STUN 域名清单，把 IP 直接灌进 nftables 集合 stun_block_ip4/6。
# 自包含、不依赖 dnsmasq —— 在 passwall 接管 DNS 的环境下也能可靠工作。
# 由 apply.sh 在启用时调用一次，并由 cron 定时刷新（域名 IP 会轮换）。

# cron 的默认 PATH 不含 /usr/sbin（nft 在此），显式设置避免定时刷新静默失效。
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DOMAINS=/usr/share/webrtc-control/stun-domains.list
TABLE=webrtc_control
TIMEOUT=2h

# 表不在（插件未启用）或清单缺失则直接退出
nft list table inet "$TABLE" >/dev/null 2>&1 || exit 0
[ -f "$DOMAINS" ] || exit 0

while read -r line; do
	d=$(echo "$line" | sed 's/#.*//' | awk '{print $1}')
	[ -n "$d" ] || continue
	for ip in $(resolveip -4 -t 3 "$d" 2>/dev/null); do
		nft add element inet "$TABLE" stun_block_ip4 "{ $ip timeout $TIMEOUT }" 2>/dev/null
	done
	for ip in $(resolveip -6 -t 3 "$d" 2>/dev/null); do
		nft add element inet "$TABLE" stun_block_ip6 "{ $ip timeout $TIMEOUT }" 2>/dev/null
	done
done < "$DOMAINS"
