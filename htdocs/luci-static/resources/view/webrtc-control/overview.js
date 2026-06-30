'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require dom';
'require poll';

var callStatus = rpc.declare({ object: 'webrtc-control', method: 'status', expect: { '': {} } });
var callStats  = rpc.declare({ object: 'webrtc-control', method: 'stats',  expect: { '': {} } });

function badge(ok, ontext, offtext) {
	return E('span', { 'style': 'font-weight:bold;color:' + (ok ? '#2e7d32' : '#c62828') },
		ok ? ontext : offtext);
}

function row(label, value_node) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		E('td', { 'class': 'td left' }, value_node)
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), uci.load('webrtc-control') ]);
	},

	setEnabled: function(val) {
		uci.set('webrtc-control', 'global', 'enabled', val ? '1' : '0');
		return uci.save()
			.then(function() { return uci.apply(); })
			.then(function() {
				ui.addNotification(null, E('p', _('已%s并应用').format(val ? _('启用') : _('停用'))), 'info');
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', _('操作失败: ') + e), 'error');
				throw e;
			});
	},

	render: function(data) {
		var st = data[0] || {};

		var v_state   = E('span', {}, '-');
		var v_mode    = E('span', {}, '-');
		var v_dropped = E('span', {}, '-');
		var v_wl      = E('span', {}, '-');
		var v_dpi = E('span', {}, '-'), v_port = E('span', {}, '-'), v_dns = E('span', {}, '-');

		function fillStatus(s) {
			dom.content(v_state,
				(s.enabled && s.loaded) ? badge(true, _('运行中'), '') :
				(s.enabled ? badge(false, '', _('已启用但规则未加载')) : badge(false, '', _('已停用'))));
			dom.content(v_mode, s.mode === 'block' ? _('全局拦截') : _('强制走代理否则丢弃'));
			dom.content(v_dropped, String(s.dropped || 0));
			dom.content(v_wl, String(s.whitelisted || 0));
		}
		fillStatus(st);

		poll.add(function() {
			return Promise.all([ callStatus(), callStats() ]).then(function(r) {
				fillStatus(r[0] || {});
				var t = r[1] || {};
				dom.content(v_dpi, String(t.dpi || 0));
				dom.content(v_port, String(t.ports || 0));
				dom.content(v_dns, String(t.dns || 0));
			});
		}, 5);

		var self = this;
		var enabledState = (st.enabled == 1);
		var btnLabel = function() { return enabledState ? _('停用拦截') : _('启用拦截'); };
		var btnClass = function() { return 'btn cbi-button cbi-button-' + (enabledState ? 'reset' : 'save'); };
		var btnToggle = E('button', { 'class': btnClass() }, btnLabel());
		btnToggle.addEventListener('click', function() {
			btnToggle.disabled = true;
			self.setEnabled(!enabledState).then(function() {
				enabledState = !enabledState;
				btnToggle.textContent = btnLabel();
				btnToggle.className = btnClass();
				btnToggle.disabled = false;
			}).catch(function() {
				btnToggle.disabled = false;
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('WebRTC 控制 · 总览')),
			E('div', { 'class': 'cbi-map-descr' },
				_('在路由器网络层拦截 WebRTC 的 STUN/ICE 探测，防止真实 IP 泄露。对全网所有设备生效，无需安装浏览器扩展。')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('运行状态')),
				E('table', { 'class': 'table' }, [
					row(_('状态'), v_state),
					row(_('联动模式'), v_mode),
					row(_('累计拦截（包）'), v_dropped),
					row(_('白名单设备数'), v_wl),
					row(_('DPI / 端口 / DNS 命中'), E('span', {}, [ v_dpi, ' / ', v_port, ' / ', v_dns ]))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('快捷操作')),
				E('div', { 'class': 'cbi-section-node' }, [
					btnToggle,
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function() { window.open('https://browserleaks.com/webrtc', '_blank'); }
					}, _('打开 WebRTC 泄露检测')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function() { location.href = L.url('admin/services/webrtc-control/settings'); }
					}, _('前往拦截设置'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
