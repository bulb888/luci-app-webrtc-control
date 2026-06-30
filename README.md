# luci-app-webrtc-control

在 OpenWRT（fw4/nftables）路由器上于**网络层**拦截 WebRTC 的 STUN/ICE 探测，防止真实 IP 泄露。
面向 **KWRT 25.12 / OpenWRT 22.03+**（fw4 + LuCI JS 客户端），与 **passwall** 配合使用。

与浏览器扩展 [webrtc-control](https://github.com/dlinbernard/webrtc-control) 的区别：浏览器扩展只能保护装了它的那个浏览器；本插件在路由器上对**全网所有设备**（手机、电视、任意浏览器）生效，无需逐个安装扩展。

## 工作原理

WebRTC 通过 STUN/ICE 发 UDP 探测真实网络地址，这些请求常**绕过 passwall 代理直连**，暴露真实 IP。本插件用 nftables 三层拦截这条泄露路径：

1. **协议级 DPI**（主力）：匹配 STUN 报文的 magic cookie `0x2112A442`（`udp @th,96,32`），不论端口都能拦。
2. **端口拦截**：丢弃常见 STUN/TURN 端口 3478 / 5349 / 19302-19309。
3. **DNS 域名拦截**：自包含解析器（`resolve-stun.sh`）用 `resolveip` 解析已知 STUN 服务器域名清单，把 IP 直接灌进 nft 集合 `stun_block_ip4/6` 再丢弃；cron 每 30 分钟刷新（域名 IP 会轮换）。**不依赖 dnsmasq**——因为 passwall 会接管/劫持 DNS，dnsmasq nftset 那条路在 passwall 环境下走不通。

规则通过 fw4 扩展点 `/usr/share/nftables.d/ruleset-post/10-webrtc-control.nft` 注入。⚠️ fw4 reload **不** flush 整个 ruleset，故生成文件用「建空表→删表→重建」幂等惯用法，保证每次 reload 干净重建、不叠加。

### passwall 联动模式（默认 proxy）

- **强制走代理否则丢弃（proxy）**：拦截规则带 `oifname @wan_ifaces`。被 passwall 的 TPROXY 接管的 UDP 走本地、不经 forward 链，因而放行；只有绕过代理、直连 WAN 的 STUN 被丢弃。
  - ⚠️ 前提：passwall 需开启 **UDP 转发/代理**，否则 STUN 走直连会被全部拦掉（WebRTC 用不了，但**不泄露**，安全）。
- **全局拦截（block）**：不分路径一律拦截。

## 功能

- 全网总开关 / 三层拦截各自独立开关
- 按 **IP / MAC 白名单**放行设备（如需视频会议的工作电脑）
- 按**防火墙 zone** 限定生效范围（如只管 guest 网络）
- 拦截命中计数与 system log 日志
- 总览页内置 WebRTC 泄露自测入口

## 目录结构

```
Makefile
htdocs/luci-static/resources/view/webrtc-control/{overview,settings,whitelist,logs}.js
root/etc/config/webrtc-control                         UCI 配置
root/etc/init.d/webrtc-control                          procd 服务
root/etc/uci-defaults/40_luci-webrtc-control            首次安装初始化
root/usr/share/luci/menu.d/...                          菜单
root/usr/share/rpcd/acl.d/...                           ACL 权限
root/usr/libexec/rpcd/webrtc-control                    ubus 后端（状态/计数/日志）
root/usr/share/webrtc-control/apply.sh                  UCI -> nft 规则生成器（核心）
root/usr/share/webrtc-control/resolve-stun.sh           STUN 域名解析器 -> 灌 nft 集合
root/usr/share/webrtc-control/stun-domains.list         STUN 域名清单
build-ipk.sh                                            本地手工打包脚本（无需 SDK）
```

## 构建（OpenWRT/KWRT SDK）

需用与目标固件匹配的 SDK（KWRT 25.12 / openwrt-25.12）。

```sh
# 1) 放进 SDK 的 package 目录
cp -r luci-app-webrtc-control <SDK>/package/

# 2) 刷新 feeds（提供 luci.mk 与依赖）
cd <SDK>
./scripts/feeds update -a && ./scripts/feeds install -a

# 3) 编译
make package/luci-app-webrtc-control/compile V=s

# 产物
bin/packages/<arch>/.../luci-app-webrtc-control_*.ipk
```

> 运行依赖仅 `firewall4` + `kmod-nft-core`（`resolveip`、`cron` 都在 base 系统里），KWRT 默认都有。

### 本地手工打包（无需 SDK / Docker）

本包是纯文件包（无 C 代码），可直接用 `build-ipk.sh` 在任意机器上组装 ipk：

```sh
sh build-ipk.sh        # 产物在 ./dist/
```

> ⚠️ 外层必须是 **gzip-tar**（经典 ipkg 格式），内层 tar 必须是 **ustar**（避免 macOS pax 扩展头）——
> 这台 KWRT 的 opkg 是静态 busybox 解析器，不吃 ar 归档也不吃 pax，本脚本已处理好。

## 安装与验证

```sh
opkg install luci-app-webrtc-control_*.ipk

# 1) nft 规则已加载
nft list table inet webrtc_control

# 2) 在 LAN 客户端打开泄露检测页（启用后应只见代理 IP / 无候选）
#    https://browserleaks.com/webrtc

# 3) 校准 magic cookie 偏移：真实 WebRTC 流量应让 DPI 计数递增
logread | grep webrtc-drop
nft list chain inet webrtc_control forward     # 看 counter packets

# 4) fw4 reload 后规则应自动重载（持久化验证）
fw4 reload && nft list table inet webrtc_control
```

## 已在真机验证（KWRT 25.12-SNAPSHOT + passwall + xray）

核心：
- ✅ `@th,96,32` magic cookie 偏移命中真实 STUN 包，DPI 在直连泄露路径于 WAN 出口 `OUT=eth0` 丢弃，与端口无关
- ✅ **真实 STUN 客户端端到端**：国内 STUN 服务器超时被拦；国外 STUN 经 passwall 返回的是**代理 IP 而非真实 IP**（真实公网 IP 不泄露）
- ✅ 白名单端到端：白名单内来源的 STUN 放行，DPI 计数不增
- ✅ IPv4 + IPv6 双覆盖：DPI 规则在 `inet` 表用 `meta l4proto udp @th`，与地址族无关；wan_ifaces 自动含 v6 WAN 设备

健壮性 / 压测：
- ✅ `fw4 reload` 与 `fw4 restart`（完整重启）后表都自动重建，与 passwall 规则共存不冲突
- ✅ 5 路并发 reload 压测：flock 串行化后最终状态完全一致（无竞态）
- ✅ block 模式、三层全关、50 条白名单、注入攻击（被校验拦下）等边界均正确
- ✅ DNS 解析器填充集合、cron 刷新、幂等 reload、ubus/UI、限速日志全部正常

## 能力边界（重要，请如实理解）

本插件在**网络层**工作，能力与浏览器扩展不同：

- ✅ **能防**：通过 STUN 探测**公网 IP** 的泄露 —— 直连路径丢弃，代理路径只暴露代理 IP。
- ⚠️ **不能防 host candidate（本机局域网 IP）**：浏览器枚举本机网卡得到的 host 候选不产生网络流量，路由器拦不到。所幸现代浏览器（Chrome/Firefox 自 2019 起）默认用 **mDNS `.local`** 混淆本机 IP，已大幅缓解；老旧浏览器或关了 mDNS 才可能暴露内网 IP。要 100% 杜绝请同时用浏览器扩展。
- ⚠️ **proxy 模式不"关闭"WebRTC**：经 passwall 代理的 WebRTC 仍可用（只是显示代理 IP）。即便 block 模式也拦不到被 TPROXY 接管的流量（它不经 forward 链）。本插件目标是**防真实 IP 泄露**，不是彻底禁用 WebRTC。

## 注意 / 取舍

- 路由层拦 WebRTC 会**误伤走直连的正常视频通话/语音**（国内直连 STUN 的应用、游戏语音等）。需要时把对应设备加入白名单；微信等用私有协议、不触发标准 STUN 规则，一般不受影响。
- proxy 模式依赖 passwall 用 TPROXY 接管 UDP；若你的代理方案对 UDP 用别的机制，请改用 block 模式或调整。
- 双重 NAT（路由器下又接路由器）时，下游设备在本机看是同一来源 IP，"按设备白名单"无法区分。

## License

GPL-3.0-or-later
