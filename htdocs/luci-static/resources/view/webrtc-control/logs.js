'use strict';
'require view';
'require rpc';
'require dom';
'require poll';

var callLogs  = rpc.declare({ object: 'webrtc-control', method: 'logs' });
var callStats = rpc.declare({ object: 'webrtc-control', method: 'stats' });

function statRow(label, node) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		E('td', { 'class': 'td left' }, node)
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ callLogs(), callStats() ]);
	},

	render: function(data) {
		var logs  = (data[0] && data[0].entries) || [];
		var stats = data[1] || {};

		var pre = E('pre', {
			'style': 'max-height:480px;overflow:auto;white-space:pre-wrap;font-size:12px'
		}, logs.length ? logs.join('\n') : _('暂无拦截记录'));

		var v_dpi  = E('span', {}, String(stats.dpi   || 0));
		var v_port = E('span', {}, String(stats.ports || 0));
		var v_dns  = E('span', {}, String(stats.dns   || 0));

		poll.add(function() {
			return Promise.all([ callLogs(), callStats() ]).then(function(r) {
				var l = (r[0] && r[0].entries) || [];
				dom.content(pre, l.length ? l.join('\n') : _('暂无拦截记录'));
				var t = r[1] || {};
				dom.content(v_dpi,  String(t.dpi   || 0));
				dom.content(v_port, String(t.ports || 0));
				dom.content(v_dns,  String(t.dns   || 0));
			});
		}, 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('拦截日志')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('命中统计（累计包数）')),
				E('table', { 'class': 'table' }, [
					statRow(_('协议级 DPI'), v_dpi),
					statRow(_('端口拦截'), v_port),
					statRow(_('DNS 拦截'), v_dns)
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('最近拦截（system log，需开启“记录拦截日志”）')),
				pre
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
