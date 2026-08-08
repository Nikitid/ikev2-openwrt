'use strict';
'require view';
'require fs';
'require poll';
'require ikev2-manager.shared as common';

// Shadow the global _() with the project translator for this module only;
// see the note in shared.js about not replacing window._.
var _ = common.t;

var helper = '/usr/libexec/ikev2-manager';
var systemHelper = '/usr/libexec/ikev2-manager-system';

var dnsProtocols = [
	{ id: 'udp', label: 'DNS over UDP' },
	{ id: 'tcp', label: 'DNS over TCP' },
	{ id: 'dot', label: 'DNS over TLS (DoT)' },
	{ id: 'doh', label: 'DNS over HTTPS (DoH)' },
	{ id: 'doh3', label: 'DoH with HTTP/3 preferred — experimental' },
	{ id: 'h3', label: 'DoH over HTTP/3 only — experimental' },
	{ id: 'doq', label: 'DNS over QUIC (DoQ) — experimental' },
	{ id: 'dnscrypt', label: 'DNSCrypt' }
];

var dnsProviders = [
	{
		id: 'cloudflare', label: 'Cloudflare',
		udp: 'udp://1.1.1.1:53 udp://1.0.0.1:53',
		tcp: 'tcp://1.1.1.1:53 tcp://1.0.0.1:53',
		dot: 'tls://one.one.one.one',
		doh: 'https://dns.cloudflare.com/dns-query',
		doh3: 'https://dns.cloudflare.com/dns-query',
		bootstrap: '1.1.1.1:53 1.0.0.1:53'
	},
	{
		id: 'google', label: 'Google Public DNS',
		udp: 'udp://8.8.8.8:53 udp://8.8.4.4:53',
		tcp: 'tcp://8.8.8.8:53 tcp://8.8.4.4:53',
		dot: 'tls://dns.google',
		doh: 'https://dns.google/dns-query',
		doh3: 'https://dns.google/dns-query',
		h3: 'h3://dns.google/dns-query',
		bootstrap: '8.8.8.8:53 8.8.4.4:53'
	},
	{
		id: 'quad9', label: 'Quad9 Security',
		udp: 'udp://9.9.9.9:53 udp://149.112.112.112:53',
		tcp: 'tcp://9.9.9.9:53 tcp://149.112.112.112:53',
		dot: 'tls://dns.quad9.net',
		doh: 'https://dns.quad9.net/dns-query',
		bootstrap: '9.9.9.9:53 149.112.112.112:53'
	},
	{
		id: 'adguard', label: 'AdGuard DNS',
		udp: 'udp://94.140.14.14:53 udp://94.140.15.15:53',
		tcp: 'tcp://94.140.14.14:53 tcp://94.140.15.15:53',
		dot: 'tls://dns.adguard-dns.com',
		doh: 'https://dns.adguard-dns.com/dns-query',
		doh3: 'https://dns.adguard-dns.com/dns-query',
		doq: 'quic://dns.adguard-dns.com',
		dnscrypt: 'sdns://AQMAAAAAAAAAETk0LjE0MC4xNC4xNDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20',
		bootstrap: '94.140.14.14:53 94.140.15.15:53'
	},
	{
		id: 'adguard_unfiltered', label: 'AdGuard DNS — unfiltered',
		udp: 'udp://94.140.14.140:53 udp://94.140.14.141:53',
		tcp: 'tcp://94.140.14.140:53 tcp://94.140.14.141:53',
		dot: 'tls://unfiltered.adguard-dns.com',
		doh: 'https://unfiltered.adguard-dns.com/dns-query',
		doh3: 'https://unfiltered.adguard-dns.com/dns-query',
		doq: 'quic://unfiltered.adguard-dns.com',
		bootstrap: '94.140.14.140:53 94.140.14.141:53'
	},
	{
		id: 'controld', label: 'Control D — unfiltered',
		udp: 'udp://76.76.2.0:53 udp://76.76.10.0:53',
		tcp: 'tcp://76.76.2.0:53 tcp://76.76.10.0:53',
		dot: 'tls://p0.freedns.controld.com',
		doh: 'https://freedns.controld.com/p0',
		bootstrap: '76.76.2.0:53 76.76.10.0:53'
	},
	{
		id: 'mullvad', label: 'Mullvad DNS',
		dot: 'tls://dns.mullvad.net',
		doh: 'https://dns.mullvad.net/dns-query',
		bootstrap: '194.242.2.2:53'
	},
	{
		id: 'yandex', label: 'Yandex DNS',
		udp: 'udp://77.88.8.8:53 udp://77.88.8.1:53',
		tcp: 'tcp://77.88.8.8:53 tcp://77.88.8.1:53',
		dot: 'tls://common.dot.dns.yandex.net',
		doh: 'https://common.dot.dns.yandex.net/dns-query',
		bootstrap: '77.88.8.8:53 77.88.8.1:53'
	}
];

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

function splitDnsList(value) {
	return (value || '').trim().split(/\s+/).filter(Boolean);
}

function configuredDnsValue(values, key, currentKey, defaultValue) {
	if (Object.prototype.hasOwnProperty.call(values, key))
		return values[key] || '';
	if (currentKey && Object.prototype.hasOwnProperty.call(values, currentKey))
		return values[currentKey] || '';
	return defaultValue || '';
}

function parseDnsSegments(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').filter(Boolean).map(function(line) {
		var out = {};
		line.split('\t').forEach(function(field) {
			var eq = field.indexOf('=');
			if (eq > 0) out[field.slice(0, eq)] = field.slice(eq + 1);
		});
		return out.id ? out : null;
	}).filter(Boolean);
}

function dnsEndpointProtocol(value) {
	if (value.indexOf('udp://') === 0) return 'udp';
	if (value.indexOf('tcp://') === 0) return 'tcp';
	if (value.indexOf('tls://') === 0) return 'dot';
	if (value.indexOf('https://') === 0) return 'doh';
	if (value.indexOf('h3://') === 0) return 'h3';
	if (value.indexOf('quic://') === 0) return 'doq';
	if (value.indexOf('sdns://') === 0) return 'dnscrypt';
	return 'unknown';
}

function validDnsEndpoint(protocol, value) {
	var accepted = {
		udp: 'udp://', tcp: 'tcp://', dot: 'tls://', doh: 'https://',
		doh3: 'https://', h3: 'h3://', doq: 'quic://', dnscrypt: 'sdns://'
	};
	var prefix = accepted[protocol];
	if (!prefix || value.indexOf(prefix) !== 0 || value.length > 2048)
		return false;
	var remainder = value.slice(prefix.length);
	if (protocol === 'dnscrypt')
		return remainder.length >= 8 && /^[A-Za-z0-9_-]+$/.test(remainder);
	var path = '';
	if (protocol === 'doh' || protocol === 'doh3' || protocol === 'h3') {
		var slash = remainder.indexOf('/');
		if (slash <= 0)
			return false;
		path = remainder.slice(slash);
		remainder = remainder.slice(0, slash);
		if (path === '/' || !/^\/[A-Za-z0-9._~:/?%+=,&;@-]+$/.test(path))
			return false;
	}
	if (!remainder || /[\/?#@\[\]]/.test(remainder))
		return false;
	var parts = remainder.split(':');
	if (parts.length > 2)
		return false;
	if (parts.length === 2) {
		if (!/^\d+$/.test(parts[1]))
			return false;
		var port = Number(parts[1]);
		if (port < 1 || port > 65535)
			return false;
	}
	var host = parts[0];
	if (/^\d+(?:\.\d+){3}$/.test(host)) {
		var octets = host.split('.');
		return octets.every(function(octet) { return Number(octet) <= 255; });
	}
	if (/^[0-9.]+$/.test(host) || host.length > 253)
		return false;
	return host.split('.').every(function(label) {
		return label.length >= 1 && label.length <= 63 &&
			/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(label);
	});
}

function validBootstrapEndpoint(value) {
	var match = value.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+):(\d+)$/);
	if (!match)
		return false;
	for (var i = 1; i <= 4; i++)
		if (Number(match[i]) > 255)
			return false;
	var port = Number(match[5]);
	return port >= 1 && port <= 65535;
}

function dnsEndpointEditor(value, placeholder, addLabel, emptyLabel) {
	var list = E('div', { 'class': 'ikev2-dns-endpoints' });
	var add = E('button', {
		'class': 'cbi-button cbi-button-action',
		'type': 'button'
	}, [ addLabel ]);

	function values() {
		return Array.prototype.map.call(
			list.querySelectorAll('input[type="text"]'),
			function(field) { return field.value.trim(); }
		).filter(Boolean);
	}

	function render(items) {
		list.replaceChildren();
		if (!items.length)
			list.appendChild(E('div', { 'class': 'ikev2-dns-empty' }, [ emptyLabel ]));
		items.forEach(function(item) {
			var field = input('text', item, { 'placeholder': placeholder });
			var remove = E('button', {
				'class': 'cbi-button cbi-button-remove',
				'type': 'button',
				'title': _('Remove'),
				'aria-label': _('Remove')
			}, [ '×' ]);
			remove.addEventListener('click', function() {
				field.parentNode.remove();
				if (!list.querySelector('.ikev2-dns-endpoint'))
					render([]);
			});
			list.appendChild(E('div', { 'class': 'ikev2-dns-endpoint' }, [ field, remove ]));
		});
	}

	function append(items) {
		var next = values();
		splitDnsList(items).forEach(function(item) {
			if (next.indexOf(item) < 0)
				next.push(item);
		});
		render(next);
	}

	add.addEventListener('click', function() {
		var next = values();
		next.push('');
		render(next);
		var fields = list.querySelectorAll('input[type="text"]');
		if (fields.length)
			fields[fields.length - 1].focus();
	});

	render(splitDnsList(value));
	return {
		node: E('div', { 'class': 'ikev2-dns-editor' }, [
			list,
			E('div', { 'class': 'ikev2-dns-editor-actions' }, [ add ])
		]),
		values: values,
		append: append,
		set: function(items) { render(splitDnsList(items)); }
	};
}

function findOutbound(sas) {
	for (var i = 0; i < sas.length; i++) {
		if (sas[i]['proxy-out'])
			return sas[i]['proxy-out'];
	}
	return null;
}

function writeProfileInput(value) {
	var token = common.inputToken();
	return fs.write('/var/run/ikev2-manager-profile-' + token + '.in', value, 384)
		.then(function() { return token; });
}

function runManagerJob(button, result, args, busy, success, failure, timeout, onSuccess) {
	return common.runJob({
		button: button,
		result: result,
		busy: busy,
		success: success,
		failure: failure,
		startPath: helper,
		startArgs: args,
		statusPath: helper,
		statusArgs: [ 'action-status' ],
		timeout: timeout || 120000,
		allowImmediate: true,
		timeoutMessage: _('The operation continues in the background. You can use the button again.'),
		onSuccess: onSuccess
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return Promise.all([
				fs.exec(helper, [ 'client-get' ]),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' }),
				fs.exec(helper, [ 'advanced-mode', 'outbound' ]),
				fs.exec(helper, [ 'advanced-read', 'outbound' ]),
				L.resolveDefault(fs.exec(systemHelper, [ 'dns-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(systemHelper, [ 'dns-segments-get' ]), { stdout: '' })
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('Outbound IKEv2 Tunnel'),
				_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.')) ]);
		var value = common.parseKeyValues(data[0].stdout);
		var dnsValue = common.parseKeyValues((data[4] && data[4].stdout) || '');
		var dnsSegments = parseDnsSegments((data[5] && data[5].stdout) || '');
		var customMode = (data[2].stdout || '').trim() === '1';
		var outbound = findOutbound(common.parseSwanmon(data[1]));
		var child = outbound && Object.values(outbound['child-sas'] || {})
			.find(function(item) { return item.name === 'proxy4'; });
		var statusPill = common.pill('', 'neutral');
		var rawModePill = common.pill('', 'neutral');

		function liveCard(label, extraClass) {
			var valueNode = E('div', { 'class': 'ikev2-card-value' });
			var detailNode = E('div', { 'class': 'ikev2-card-detail' });
			return {
				node: E('div', { 'class': 'ikev2-card ' + (extraClass || '') }, [
					E('div', { 'class': 'ikev2-card-label' }, [ label ]),
					valueNode,
					detailNode
				]),
				value: valueNode,
				detail: detailNode
			};
		}

		var gatewayCard = liveCard(_('Remote gateway'));
		var virtualCard = liveCard(_('Virtual IPv4'));
		var trafficCard = liveCard(_('Current SA traffic'));
		var accumulatedTrafficCard = liveCard(_('Accumulated tunnel traffic'));

		function updateConnectionView() {
			common.setPill(statusPill,
				customMode ? _('Custom config') : (child ? _('Connected') : _('Disconnected')),
				customMode ? 'warn' : (child ? 'good' : 'bad'));
			common.setPill(rawModePill,
				customMode ? _('Override active') : _('Generated'),
				customMode ? 'warn' : 'good');
			gatewayCard.value.textContent = outbound ? outbound['remote-host'] :
				(value.remote_address || '-');
			gatewayCard.detail.textContent = outbound ? outbound['remote-id'] : (value.remote_id || '');
			virtualCard.value.textContent = outbound && (outbound['local-vips'] || [])[0] || '-';
			virtualCard.detail.textContent = child ?
				common.formatDuration(child['install-time']) + ' ' + _('online') : '';
			var down = child ? Number(child['bytes-in'] || 0) : 0;
			var up = child ? Number(child['bytes-out'] || 0) : 0;
			trafficCard.value.textContent = common.formatBytes(down + up);
			trafficCard.detail.textContent = child ?
				_('Down %s, up %s').format(common.formatBytes(down), common.formatBytes(up)) +
					' · ' + _('Counter age: %s').format(common.formatDuration(child['install-time'])) :
				_('No active traffic SA');
			var interfacePresent = value.interface_present === '1';
			var totalDown = Number(value.interface_bytes_in || 0);
			var totalUp = Number(value.interface_bytes_out || 0);
			accumulatedTrafficCard.value.textContent = interfacePresent ?
				common.formatBytes(totalDown + totalUp) : '-';
			accumulatedTrafficCard.detail.textContent = interfacePresent ?
				_('Down %s, up %s').format(common.formatBytes(totalDown), common.formatBytes(totalUp)) +
					' · ' + _('Since ipsec-out was created') :
				_('ipsec-out is unavailable');
		}

		function refreshClientState() {
			return Promise.all([
				L.resolveDefault(fs.exec(helper, [ 'client-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' })
			]).then(function(results) {
				value = common.parseKeyValues(results[0].stdout || '');
				outbound = findOutbound(common.parseSwanmon(results[1]));
				child = outbound && Object.values(outbound['child-sas'] || {})
					.find(function(item) { return item.name === 'proxy4'; });
				updateConnectionView();
			});
		}
		updateConnectionView();
		poll.add(refreshClientState, 5);
		var enabled = input('checkbox', value.enabled);
		var address = input('text', value.remote_address, {
			'placeholder': _('IPv4 address or hostname')
		});
		var remoteId = input('text', value.remote_id);
		var username = input('text', value.username, { 'autocomplete': 'off' });
			var password = input('password', '', {
				'placeholder': _('Leave blank to keep the current password'),
				'autocomplete': 'new-password'
		});
		var dpd = common.choiceWithCustom(value.dpd, [
			{ value: '30', label: '30 ' + _('seconds') + ' — ' + _('recommended') },
			{ value: '60', label: '60 ' + _('seconds') },
			{ value: '120', label: '120 ' + _('seconds') }
		], { type: 'number', attrs: { 'min': '10', 'max': '300' } });
		var mtu = common.choiceWithCustom(value.mtu, [
			{ value: '1400', label: '1400 — ' + _('recommended') },
			{ value: '1360', label: '1360 — ' + _('constrained networks') },
			{ value: '1280', label: '1280 — ' + _('minimum') },
			{ value: '1500', label: '1500 — ' + _('no reduction') }
		], { type: 'number', attrs: { 'min': '1280', 'max': '1500' } });
		var reconnectCooldown = common.choiceWithCustom(value.reconnect_cooldown || '15', [
			{ value: '15', label: '15 ' + _('seconds') + ' — ' + _('recommended') },
			{ value: '30', label: '30 ' + _('seconds') },
			{ value: '60', label: '60 ' + _('seconds') }
		], { type: 'number', attrs: { 'min': '15', 'max': '300' } });
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save and connect')
		]);
		var saveOnly = E('button', { 'class': 'cbi-button' }, [
			_('Save')
		]);
		var reconnect = E('button', { 'class': 'cbi-button cbi-button-neutral' }, [
			_('Reconnect')
		]);
		var connectResult = common.inlineResult();
		var rawResult = common.inlineResult();
		var rawToggle = E('button', { 'class': 'cbi-button' }, [ _('Edit raw config') ]);
		var rawText = E('textarea', { 'class': 'ikev2-domain-editor' }, [
			data[3].stdout || ''
		]);
		var rawSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save custom config')
		]);
		var rawReset = E('button', { 'class': 'cbi-button cbi-button-reset' }, [
			_('Reset to generated')
		]);
		var rawPanel = E('div', {
			'style': 'display:none;margin-top:1rem'
		}, [
			E('div', { 'class': 'ikev2-note warn' }, [
				_('Custom mode replaces the generated outbound connection. Credentials remain managed separately by the EAP fields above.')
			]),
			rawText,
			E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:.7rem' }, [
				rawResult.node,
				rawReset,
				rawSave
			])
		]);

		rawToggle.addEventListener('click', function() {
			rawPanel.style.display = rawPanel.style.display === 'none' ? '' : 'none';
		});

		rawSave.addEventListener('click', function() {
			return writeProfileInput(rawText.value).then(function(token) {
				return runManagerJob(rawSave, rawResult,
					[ 'advanced-start', 'outbound', token ],
					_('Validating and reconnecting...'), _('Loaded'),
					_('Custom configuration was rejected'), 120000, function(st) {
						if (st && st.state !== 'timeout') {
							customMode = true;
							return refreshClientState();
						}
					});
			}).catch(function(error) {
				rawResult.err(error.message || error);
				});
		});

		rawReset.addEventListener('click', function() {
			return runManagerJob(rawReset, rawResult,
				[ 'advanced-reset-start', 'outbound' ],
				_('Restoring and reconnecting...'), _('Restored'), _('Reset failed'), 120000,
				function(st) {
					if (st && st.state !== 'timeout') {
						customMode = false;
						return refreshClientState();
					}
				});
		});

			function writeClientInput(mode) {
				var token = common.inputToken();
				var payload = [
				mode,
				enabled.checked ? '1' : '0',
				address.value.trim(),
				remoteId.value.trim(),
				username.value.trim(),
				dpd.value(),
				mtu.value(),
				password.value,
				reconnectCooldown.value()
			].join('\n') + '\n';
				return fs.write('/var/run/ikev2-manager-client-' + token + '.in', payload, 384 /* 0600 */)
					.then(function() { return token; });
			}

		function runClientInputJob(button, mode, busy, success, failure, timeout) {
				return writeClientInput(mode).then(function(token) {
					return runManagerJob(button, connectResult, [ 'client-input', token ],
					busy, success, failure, timeout, refreshClientState);
			}).catch(function(error) {
				connectResult.err(error.message || error);
			});
		}

		saveOnly.addEventListener('click', function() {
			return runClientInputJob(saveOnly, 'save',
				_('Saving...'), _('Saved'), _('Save failed'), 120000);
		});

		save.addEventListener('click', function() {
			return runClientInputJob(save, 'set',
				enabled.checked ? _('Saving and connecting...') : _('Saving and stopping...'),
				enabled.checked ? _('Saved and connected') : _('Saved and disabled'),
				_('Apply failed'), 150000);
		});

		// Reconnect the existing tunnel without changing saved settings.
		reconnect.addEventListener('click', function() {
			return runManagerJob(reconnect, connectResult, [ 'reconnect-client' ],
				_('Reconnecting...'), _('Reconnected'), _('Reconnect failed'), 90000,
				refreshClientState);
		});

		var dnsManaged = E('select', { 'class': 'cbi-input-select' }, [
			E('option', {
				'value': '0',
				'selected': dnsValue.managed !== '1' ? '' : null
			}, [ _('Keep existing router DNS') ]),
			E('option', {
				'value': '1',
				'selected': dnsValue.managed === '1' ? '' : null
			}, [ _('Manage DNS upstream') ])
		]);
		var initialProtocol = dnsValue.protocol || dnsValue.current_protocol || 'doh';
		if (!dnsProtocols.some(function(item) { return item.id === initialProtocol; }))
			initialProtocol = 'doh';
		var dnsProtocol = E('select', { 'class': 'cbi-input-select' },
			dnsProtocols.map(function(item) {
				return E('option', {
					'value': item.id,
					'selected': item.id === initialProtocol ? '' : null
				}, [ _(item.label) ]);
			}));
		var dnsProvider = E('select', { 'class': 'cbi-input-select' });
		var dnsAddProvider = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button'
		}, [ _('Add preset') ]);
		var initialMode = dnsValue.upstream_mode || dnsValue.current_upstream_mode ||
			'load_balance';
		var dnsUpstreamMode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', {
				'value': 'load_balance',
				'selected': initialMode === 'load_balance' ? '' : null
			}, [ _('Load balance') ]),
			E('option', {
				'value': 'parallel',
				'selected': initialMode === 'parallel' ? '' : null
			}, [ _('First response') ]),
			E('option', {
				'value': 'fastest_addr',
				'selected': initialMode === 'fastest_addr' ? '' : null
			}, [ _('Fastest address') ])
		]);
		var endpointPlaceholder = 'https://dns.example/dns-query';
		var dnsUpstream = dnsEndpointEditor(
			configuredDnsValue(dnsValue, 'upstream', 'current_upstream', ''),
			endpointPlaceholder, _('Add DNS server'), _('No DNS servers added'));
		var dnsBootstrap = dnsEndpointEditor(
			configuredDnsValue(dnsValue, 'bootstrap', 'current_bootstrap',
				'1.1.1.1:53 1.0.0.1:53'),
			'1.1.1.1:53', _('Add bootstrap server'), _('No bootstrap servers added'));
		var dnsFallback = dnsEndpointEditor(
			configuredDnsValue(dnsValue, 'fallback', 'current_fallback', ''),
			endpointPlaceholder, _('Add fallback server'), _('No fallback servers added'));
		var dnsResult = common.inlineResult();
		var dnsCurrentText = E('span', {});
		var dnsStatus = common.pill('', 'neutral');
		var dnsSave = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'type': 'button'
		}, [ _('Apply DNS') ]);
		var dnsPresetPicker = E('div', { 'class': 'ikev2-dns-preset-picker' }, [
			dnsProvider,
			dnsAddProvider
		]);
		var dnsRows = E('div', { 'class': 'ikev2-form-grid' }, [
			common.fieldLabel(_('Protocol'),
				_('dnsproxy supports plain DNS, DoT, DoH, HTTP/3, DoQ and DNSCrypt.')),
			dnsProtocol,
			common.fieldLabel(_('Add provider preset')),
			dnsPresetPicker,
			common.fieldLabel(_('Query strategy')),
			dnsUpstreamMode,
			common.fieldLabel(_('Primary DNS servers')),
			dnsUpstream.node,
			common.fieldLabel(_('Bootstrap DNS')),
			dnsBootstrap.node,
			common.fieldLabel(_('Fallback DNS servers')),
			dnsFallback.node
		]);
		var dnsManagedRows = E('div', { 'class': 'ikev2-dns-managed' }, [ dnsRows ]);
		var segmentResult = common.inlineResult();
		var segmentSelect = E('select', { 'class': 'cbi-input-select' });
		var segmentName = input('text', '', { 'placeholder': 'national' });
		var segmentEnabled = input('checkbox', '1');
		var segmentDomains = input('text', '', { 'placeholder': 'ru su xn--p1ai' });
		var segmentProtocol = E('select', { 'class': 'cbi-input-select' },
			dnsProtocols.map(function(item) {
				return E('option', { 'value': item.id }, [ _(item.label) ]);
			}));
		var segmentProvider = E('select', { 'class': 'cbi-input-select' });
		var segmentAddProvider = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button'
		}, [ _('Add preset') ]);
		var segmentPresetPicker = E('div', { 'class': 'ikev2-dns-preset-picker' }, [
			segmentProvider,
			segmentAddProvider
		]);
		var segmentMode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'load_balance' }, [ _('Load balance') ]),
			E('option', { 'value': 'parallel' }, [ _('First response') ]),
			E('option', { 'value': 'fastest_addr' }, [ _('Fastest address') ])
		]);
		var segmentUpstream = dnsEndpointEditor('', 'udp://77.88.8.8:53',
			_('Add DNS server'), _('No DNS servers added'));
		var segmentBootstrap = dnsEndpointEditor('', '77.88.8.8:53',
			_('Add bootstrap server'), _('No bootstrap servers added'));
		var segmentSave = E('button', {
			'class': 'cbi-button cbi-button-apply', 'type': 'button'
		}, [ _('Save segment') ]);
		var segmentDelete = E('button', {
			'class': 'cbi-button cbi-button-remove', 'type': 'button'
		}, [ _('Delete segment') ]);

		function selectedSegment() {
			return dnsSegments.find(function(item) { return item.id === segmentSelect.value; }) || null;
		}
		function loadSegmentFields() {
			var item = selectedSegment();
			segmentName.value = item ? item.name : '';
			segmentEnabled.checked = !item || item.enabled === '1';
			segmentDomains.value = item ? item.domains : '';
			segmentProtocol.value = item ? item.protocol : 'udp';
			segmentMode.value = item ? item.mode : 'load_balance';
			segmentUpstream.set(item ? item.upstream : '');
			segmentBootstrap.set(item ? item.bootstrap : '');
			rebuildSegmentProviders(segmentProvider.value || 'yandex');
			segmentDelete.disabled = !item;
		}
		function rebuildSegmentSelect(preferred) {
			segmentSelect.replaceChildren(E('option', { 'value': '' }, [ _('New segment') ]));
			dnsSegments.forEach(function(item) {
				segmentSelect.appendChild(E('option', { 'value': item.id }, [
					(item.name || item.id) + ' — ' + item.domains
				]));
			});
			segmentSelect.value = preferred || '';
			loadSegmentFields();
		}
		function refreshSegments(preferred) {
			return common.execChecked(systemHelper, [ 'dns-segments-get' ],
				_('Could not refresh DNS segments')).then(function(response) {
				dnsSegments = parseDnsSegments(response.stdout || '');
				rebuildSegmentSelect(preferred);
			});
		}
		function runSegment(action, button) {
			var item = selectedSegment();
			var id = item ? item.id : common.inputToken().replace(/-/g, '').slice(0, 16);
			var payload = [ action, id, segmentName.value.trim(),
				segmentEnabled.checked ? '1' : '0', segmentDomains.value.trim(),
				segmentProtocol.value, segmentMode.value, segmentUpstream.values().join(' '),
				segmentBootstrap.values().join(' ') ].join('\n') + '\n';
			var token = common.inputToken();
			return fs.write('/tmp/ikev2-manager-dns-segment-' + token + '.in', payload, 384)
				.then(function() {
					return common.runJob({
						button: button, result: segmentResult,
						busy: _('Applying DNS segment...'), success: _('DNS segment applied.'),
						failure: _('DNS segment failed.'),
						startPath: systemHelper,
						startArgs: [ 'dns-segment-input', token ],
						statusPath: systemHelper, statusArgs: [ 'action-status' ],
						timeout: 120000,
						onSuccess: function() { return refreshSegments(action === 'set' ? id : ''); }
					});
				});
		}
		segmentSelect.addEventListener('change', loadSegmentFields);
		segmentSave.addEventListener('click', function() {
			var upstream = segmentUpstream.values();
			var bootstrap = segmentBootstrap.values();
			if (!/^[A-Za-z0-9_]+$/.test(segmentName.value.trim())) {
				segmentResult.err(_('Segment name may contain only letters, digits and underscores.'));
				return;
			}
			if (!segmentDomains.value.trim() || !upstream.length || !bootstrap.length) {
				segmentResult.err(_('Domains, upstreams and bootstrap servers are required.'));
				return;
			}
			if (!upstream.every(function(value) {
				return validDnsEndpoint(segmentProtocol.value, value);
			})) {
				segmentResult.err(_('Invalid DNS upstream for the selected protocol'));
				return;
			}
			if (!bootstrap.every(validBootstrapEndpoint)) {
				segmentResult.err(_('Bootstrap DNS must contain IPv4:port entries'));
				return;
			}
			return runSegment('set', segmentSave);
		});
		segmentDelete.addEventListener('click', function() {
			if (!selectedSegment() || !window.confirm(_('Delete this DNS segment?'))) return;
			return runSegment('delete', segmentDelete);
		});
		function presetFor(protocol, provider) {
			for (var i = 0; i < dnsProviders.length; i++)
				if (dnsProviders[i].id === provider && dnsProviders[i][protocol])
					return dnsProviders[i];
			return null;
		}

		function rebuildDnsProviders(preferred) {
			while (dnsProvider.firstChild)
				dnsProvider.removeChild(dnsProvider.firstChild);
			dnsProviders.forEach(function(provider) {
				if (!provider[dnsProtocol.value])
					return;
				dnsProvider.appendChild(E('option', {
					'value': provider.id,
					'selected': provider.id === preferred ? '' : null
				}, [ provider.label ]));
			});
			if (!dnsProvider.value)
				dnsProvider.value = dnsProvider.options[0].value;
		}

		function rebuildSegmentProviders(preferred) {
			segmentProvider.replaceChildren();
			dnsProviders.forEach(function(provider) {
				if (!provider[segmentProtocol.value])
					return;
				segmentProvider.appendChild(E('option', {
					'value': provider.id,
					'selected': provider.id === preferred ? '' : null
				}, [ provider.label ]));
			});
			if (!segmentProvider.value && segmentProvider.options.length)
				segmentProvider.value = segmentProvider.options[0].value;
		}

		function syncDnsVisibility() {
			dnsManagedRows.style.display = dnsManaged.value === '1' ? '' : 'none';
		}

		function updateDnsState(next) {
			dnsValue = common.parseKeyValues((next && next.stdout) || '');
			dnsCurrentText.textContent = dnsValue.current_upstream || _('WAN-provided resolvers');
			if (dnsValue.managed === '1') {
				common.setPill(dnsStatus,
					dnsValue.running === '1' ? _('Managed') : _('Stopped'),
					dnsValue.running === '1' ? 'good' : 'bad');
			}
			else {
				common.setPill(dnsStatus, _('Existing settings'), 'neutral');
			}
		}

		rebuildDnsProviders(dnsValue.provider || 'cloudflare');
		rebuildSegmentProviders('yandex');
		rebuildSegmentSelect('');
		syncDnsVisibility();
		dnsManaged.addEventListener('change', syncDnsVisibility);
		dnsProtocol.addEventListener('change', function() {
			rebuildDnsProviders(dnsProvider.value);
		});
		dnsAddProvider.addEventListener('click', function() {
			var preset = presetFor(dnsProtocol.value, dnsProvider.value);
			if (!preset)
				return;
			dnsUpstream.append(preset[dnsProtocol.value]);
			dnsBootstrap.append(preset.bootstrap || '');
		});
		segmentProtocol.addEventListener('change', function() {
			rebuildSegmentProviders(segmentProvider.value);
		});
		segmentAddProvider.addEventListener('click', function() {
			var preset = presetFor(segmentProtocol.value, segmentProvider.value);
			if (!preset)
				return;
			segmentUpstream.append(preset[segmentProtocol.value]);
			segmentBootstrap.append(preset.bootstrap || '');
		});

		dnsSave.addEventListener('click', function() {
			return common.runAction({
				button: dnsSave,
				result: dnsResult,
				busy: _('Applying and testing DNS...'),
				failure: _('DNS apply failed'),
				run: function() {
					var upstream = dnsUpstream.values();
					var bootstrap = dnsBootstrap.values();
					var fallback = dnsFallback.values();
					if (dnsManaged.value === '1') {
						if (!upstream.length || !upstream.every(function(value) {
							return validDnsEndpoint(dnsProtocol.value, value);
						}))
							throw new Error(_('Invalid DNS upstream for the selected protocol'));
						if (!bootstrap.length || !bootstrap.every(validBootstrapEndpoint))
							throw new Error(_('Bootstrap DNS must contain IPv4:port entries'));
						if (!fallback.every(function(value) {
							return validDnsEndpoint(dnsEndpointProtocol(value), value);
						}))
							throw new Error(_('Invalid fallback DNS endpoint'));
					}
						var token = common.inputToken();
						var payload = [
						dnsManaged.value,
						dnsProtocol.value,
						dnsProvider.value,
						dnsUpstreamMode.value,
						upstream.join(' '),
						bootstrap.join(' '),
						fallback.join(' ')
					].join('\n') + '\n';
						return fs.write('/tmp/ikev2-manager-dns-' + token + '.in', payload, 384)
							.then(function() {
								return common.execChecked(systemHelper, [ 'dns-set-async', token ],
								_('DNS settings rejected'));
						})
						.then(function(response) {
							var started = common.parseKeyValues(response.stdout || '');
							if (!started.action_id)
								throw new Error(_('DNS apply did not start'));
							return common.pollAction(systemHelper,
								[ 'action-status', started.action_id ], started.action_id, {
									timeout: 90000,
									interval: 1000,
									onProgress: function(st) {
										if (st.message)
											dnsResult.busy(_(st.message));
									}
								});
						})
						.then(function(st) {
							if (!st)
								throw new Error(_('DNS apply timed out'));
							if (st.state === 'error')
								throw new Error(st.message || _('DNS apply failed'));
							dnsResult.ok(_('DNS is working'));
							return L.resolveDefault(fs.exec(systemHelper, [ 'dns-get' ]), { stdout: '' })
								.then(function(next) { updateDnsState(next); });
						});
				}
			});
		});

		updateDnsState({ stdout: (data[4] && data[4].stdout) || '' });

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Outbound IKEv2 Tunnel'),
					_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.'),
					statusPill),
				E('div', { 'class': 'ikev2-grid' }, [
					gatewayCard.node,
					virtualCard.node,
					trafficCard.node,
					accumulatedTrafficCard.node
				]),
				common.section(_('Connection'),
					_('Changing these values reloads the tunnel profile and reconnects it. The PBR policy remains loaded.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('Enable client')),
							common.switchLabel(enabled),
							common.fieldLabel(_('Remote address'),
								_('IPv4 address or hostname of the IKEv2 gateway.')),
							address,
							common.fieldLabel(_('Remote identity'),
								_('Certificate identity expected from the VPS.')),
							remoteId,
							common.fieldLabel(_('EAP username')),
							username,
							common.fieldLabel(_('New EAP password'),
								_('Visible while editing; leave blank to preserve the saved secret.')),
							password
						]),
						E('details', { 'class': 'ikev2-advanced' }, [
							E('summary', {}, [ _('Advanced connectivity') ]),
							E('div', { 'class': 'ikev2-form-grid' }, [
								common.fieldLabel(_('DPD interval'),
									_('Dead peer detection in seconds.')),
								dpd.node,
								common.fieldLabel(_('XFRM MTU'),
									_('Keep 1400 unless PMTU diagnostics show a problem.')),
								mtu.node,
								common.fieldLabel(_('Reconnect cooldown'),
									_('Minimum delay between automatic connection attempts, in seconds.')),
								reconnectCooldown.node
							])
						]),
						E('div', { 'class': 'ikev2-actions bar' }, [ connectResult.node, reconnect, saveOnly, save ])
					])),
				common.section(_('DNS upstream'),
					_('Choose the public DNS upstream. In reliable mode dnsmasq sends public queries through sing-box, which uses dnsproxy as its upstream; in standard mode dnsmasq uses dnsproxy directly.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-note', 'style': 'margin-bottom:1rem' }, [
							_('Current upstream:'), ' ', dnsCurrentText,
							E('br'),
							_('This is a router-wide resolver setting. Upstream DNS connections use the router default route.')
						]),
						E('div', { 'class': 'ikev2-note warn', 'style': 'margin-bottom:1rem' }, [
							_('Applying DNS restarts the managed resolver and clears its in-memory optimistic cache. The previous configuration is restored if validation fails, but name resolution can pause briefly during the switch. Do not use Apply as a connectivity repair action.')
						]),
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('DNS management'),
								_('Existing settings are preserved until managed DNS is enabled.')),
							dnsManaged
						]),
						dnsManagedRows,
						E('details', { 'class': 'ikev2-advanced', 'style': 'margin-top:1rem' }, [
							E('summary', {}, [ _('Destination DNS segments') ]),
							E('p', { 'class': 'ikev2-panel-note' }, [
								_('Send explicit domain suffixes to an independent resolver group. Each segment has its own protocol and query strategy; all unlisted names keep the global DNS policy. Suffixes cannot overlap between enabled segments, and at most eight segments can run at once. Lists are stored locally and are not replaced by domain-policy rebuilds.')
							]),
							E('div', { 'class': 'ikev2-form-grid' }, [
								common.fieldLabel(_('Segment')), segmentSelect,
								common.fieldLabel(_('Name')), segmentName,
								common.fieldLabel(_('Enabled')), common.switchLabel(segmentEnabled),
								common.fieldLabel(_('Domain suffixes'), _('Space-separated, for example: ru su')), segmentDomains,
								common.fieldLabel(_('Protocol')), segmentProtocol,
								common.fieldLabel(_('Add provider preset')), segmentPresetPicker,
								common.fieldLabel(_('Query strategy')), segmentMode,
								common.fieldLabel(_('Primary DNS servers')), segmentUpstream.node,
								common.fieldLabel(_('Bootstrap DNS')), segmentBootstrap.node
							]),
							E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
								segmentResult.node, segmentDelete, segmentSave
							])
						]),
						E('div', { 'class': 'ikev2-actions bar' }, [ dnsResult.node, dnsSave ])
					]),
					dnsStatus),
				common.section(_('Advanced strongSwan configuration'),
					_('Inspect the generated swanctl connection or replace it with a manually maintained profile.'),
					E('div', {}, [
						rawPanel,
						E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [ rawToggle ])
					]),
					rawModePill),
				E('div', { 'class': 'ikev2-note warn' }, [
					_('Disabling this client intentionally blocks selected domains. The fail-closed route does not fall back to the home WAN.')
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
