'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('webrtc-control', _('拦截设置'),
			_('配置 WebRTC 拦截的强度与 passwall 联动方式。修改后“保存并应用”即可生效。'));

		s = m.section(form.NamedSection, 'global', 'webrtc-control', _('全局'));

		o = s.option(form.Flag, 'enabled', _('启用 WebRTC 拦截'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('passwall 联动模式'),
			_('“强制走代理否则丢弃”：经 passwall 代理的 WebRTC 仍可用，绕过代理直连 WAN 的 STUN 被丢弃，真实 IP 不泄露。“全局拦截”：不分路径一律拦截。'));
		o.value('proxy', _('强制走代理否则丢弃（推荐）'));
		o.value('block', _('全局拦截'));
		o.default = 'proxy';

		o = s.option(form.Flag, 'dpi', _('协议级 DPI'),
			_('用 nftables 匹配 STUN magic cookie (0x2112A442)，不论端口都能拦截，最彻底。'));
		o.default = '1';

		o = s.option(form.Flag, 'ports', _('端口拦截'),
			_('丢弃常见 STUN/TURN 端口：3478 / 5349 / 19302-19309。'));
		o.default = '1';

		o = s.option(form.Flag, 'dns', _('DNS 域名拦截'),
			_('屏蔽已知 STUN 服务器域名（依赖 dnsmasq-full 的 nftset 支持）。'));
		o.default = '1';

		o = s.option(form.Flag, 'log', _('记录拦截日志'),
			_('把被拦截的包写入 system log，可在“拦截日志”页查看。流量大时可关闭。'));
		o.default = '1';

		o = s.option(form.Flag, 'all_zones', _('对所有网络生效'),
			_('关闭后请在“白名单与范围”里选择仅对哪些防火墙 zone 生效。'));
		o.default = '1';

		return m.render();
	}
});
