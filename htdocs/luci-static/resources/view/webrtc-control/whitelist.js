'use strict';
'require view';
'require form';
'require uci';
'require network';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('webrtc-control'),
			uci.load('firewall'),
			network.getHostHints()
		]);
	},

	render: function(data) {
		var hints = data[2] || {};
		var m, s, o;

		m = new form.Map('webrtc-control', _('白名单与生效范围'),
			_('白名单内的设备不受 WebRTC 拦截影响（例如需要视频会议的工作电脑）。生效范围用于把拦截限定在特定网络。'));

		s = m.section(form.NamedSection, 'whitelist', 'whitelist', _('白名单（放行的设备）'));

		o = s.option(form.DynamicList, 'ip', _('IP 地址'),
			_('支持单个地址或网段（CIDR）。'));
		o.datatype = 'ipaddr';
		Object.keys(hints).forEach(function(mac) {
			var h = hints[mac];
			if (h && h.ipv4)
				o.value(h.ipv4, h.ipv4 + (h.name ? ' (' + h.name + ')' : ''));
		});

		o = s.option(form.DynamicList, 'mac', _('MAC 地址'));
		o.datatype = 'macaddr';
		Object.keys(hints).forEach(function(mac) {
			var h = hints[mac];
			o.value(mac, mac + (h && h.name ? ' (' + h.name + ')' : ''));
		});

		s = m.section(form.NamedSection, 'scope', 'scope', _('生效范围'),
			_('仅在“拦截设置”里关闭“对所有网络生效”后，此处选择的防火墙 zone 才会被限定。'));

		o = s.option(form.DynamicList, 'zone', _('生效的防火墙 zone'));
		uci.sections('firewall', 'zone').forEach(function(z) {
			if (z.name) o.value(z.name);
		});

		return m.render();
	}
});
