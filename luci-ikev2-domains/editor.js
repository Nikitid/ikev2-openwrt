'use strict';
'require view';
'require fs';
'require ikev2-manager.shared as common';

// Shadow the global _() with the project translator for this module only;
// see the note in shared.js about not replacing window._.
var _ = common.t;

var domainFile    = '/etc/pbr-ikev2-domains.txt';
var manualFile    = '/etc/pbr-ikev2-domains.manual.txt';
var manualAddressFile = '/etc/pbr-ikev2-addresses.manual.txt';
var selectedFile  = '/etc/pbr-ikev2-community-selected.txt';
var statusFile    = '/tmp/ikev2-domains-community.status';
var communityHelper = '/usr/libexec/ikev2-domains-community';
var domainRouterHelper = '/usr/libexec/ikev2-domain-router';
var serviceSelection = {};

function normalizeDomains(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var domains = [];
	var seen = {};

	for (var i = 0; i < lines.length; i++) {
		var domain = lines[i].trim().toLowerCase();

		if (!domain || domain.charAt(0) === '#')
			continue;

		var labels = domain.split('.');
		if (domain.length > 253 || domain.charAt(0) === '.' ||
		    domain.charAt(domain.length - 1) === '.' || domain.indexOf('..') !== -1 ||
		    labels.some(function(label) {
			    return !label || label.length > 63 || label.charAt(0) === '-' ||
				    label.charAt(label.length - 1) === '-';
		    }) || /\s/.test(domain) || domain.indexOf('@') !== -1 ||
		    domain.indexOf('/') !== -1 ||
		    domain.indexOf('full:') === 0 ||
		    domain.indexOf('regexp:') === 0 ||
		    !/^[a-z0-9._-]+$/.test(domain)) {
			throw new Error(
				_('Invalid entry on line %d: %s').format(i + 1, domain));
		}

		if (!seen[domain]) {
			seen[domain] = true;
			domains.push(domain);
		}
	}

	return domains;
}

function normalizeAddresses(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var addresses = [];
	var seen = {};

	for (var i = 0; i < lines.length; i++) {
		var entry = lines[i].trim();
		if (!entry || entry.charAt(0) === '#')
			continue;

		var parts = entry.split('/');
		if (parts.length > 2 || (parts.length === 2 &&
		    (!/^\d+$/.test(parts[1]) || +parts[1] > 32)))
			throw new Error(
				_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));

		var octets = parts[0].split('.');
		if (octets.length !== 4 || octets.some(function(octet) {
			return !/^\d+$/.test(octet) || +octet > 255;
		}))
			throw new Error(
				_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));

		var normalized = parts[0] + '/' + (parts.length === 2 ? +parts[1] : 32);
		if (!seen[normalized]) {
			seen[normalized] = true;
			addresses.push(normalized);
		}
	}

	return addresses;
}

function serviceLabel(name) {
	var labels = {
		openai: 'OpenAI',
		anthropic_ai: 'Anthropic',
		google_ai: 'Google AI',
		x_ai: 'xAI',
		hdrezka: 'HDRezka',
		google_play: 'Google Play',
		google_meet: 'Google Meet',
		digitalocean: 'DigitalOcean',
		cloudfront: 'CloudFront'
	};
	if (labels[name])
		return labels[name];
	return name.replace(/_/g, ' ').replace(/\b\w/g, function(letter) {
		return letter.toUpperCase();
	});
}

// Ordered service categories. Any catalog name not listed here falls into the
// trailing "Other" group, so adding a new service still shows up.
var SERVICE_CATEGORIES = [
	{ title: 'AI',
	  names: [ 'openai', 'anthropic_ai', 'google_ai', 'midjourney',
	           'perplexity', 'mistral', 'huggingface', 'stability_ai', 'x_ai' ] },
	{ title: 'Social & messaging',
	  names: [ 'telegram', 'discord', 'twitter', 'meta', 'linkedin' ] },
	{ title: 'Video & music',
	  names: [ 'youtube', 'tiktok', 'hdrezka', 'spotify', 'google_meet' ] },
	{ title: 'Games & stores',
	  names: [ 'roblox', 'google_play' ] },
	{ title: 'Infrastructure (broad — use with care)',
	  names: [ 'cloudflare', 'cloudfront', 'digitalocean', 'hetzner', 'ovh' ] }
];

var BROAD_SERVICES = /^(cloudflare|cloudfront|digitalocean|hetzner|ovh)$/;
// Compact selectable chip (replaces the bulky per-service checkbox card).
function serviceChip(name, selected, ipServices) {
	var broad = BROAD_SERVICES.test(name);
	var ipNetworks = !!ipServices[name];
	var input = E('input', {
		'type': 'checkbox',
		'class': 'ikev2-community-service',
		'value': name,
		'checked': selected[name] ? '' : null
	});
	var chip = E('label', {
		'class': 'ikev2-chip' + (broad ? ' broad' : '') + (selected[name] ? ' selected' : '')
	}, [
		input,
		E('span', {}, [ serviceLabel(name) ]),
		broad ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Broad — may also route unrelated sites')
		}, [ '⚠' ]) : '',
		ipNetworks ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Includes direct service IP networks')
		}, [ 'IP' ]) : ''
	]);
	input.addEventListener('change', function() {
		chip.classList.toggle('selected', input.checked);
		if (input.checked)
			serviceSelection[name] = true;
		else
			delete serviceSelection[name];
	});
	return chip;
}

// Group a flat catalog list into ordered category blocks. Unmatched names
// collect into a trailing "Other" group.
function renderServiceGroups(services, selected, ipServices) {
	var available = {};
	services.forEach(function(n) { available[n] = true; });

	var used   = {};
	var blocks = [];

	function block(title, names) {
		var items = names.filter(function(n) { return available[n]; })
			.map(function(n) {
				used[n] = true;
				return serviceChip(n, selected, ipServices);
			});
		if (!items.length)
			return;
		blocks.push(E('div', { 'class': 'ikev2-chip-group' }, [
			E('h4', {}, [ _(title) ]),
			E('div', { 'class': 'ikev2-chips' }, items)
		]));
	}

	SERVICE_CATEGORIES.forEach(function(cat) { block(cat.title, cat.names); });

	var others = services.filter(function(n) { return !used[n]; }).sort();
	block('Other', others);

	return blocks;
}

function parseStatus(text) {
	var out = {};
	var lines = (text || '').replace(/\r/g, '').split('\n');
	for (var i = 0; i < lines.length; i++) {
		var eq = lines[i].indexOf('=');
		if (eq > 0)
			out[lines[i].slice(0, eq)] = lines[i].slice(eq + 1);
	}
	return out;
}

// Poll the status file until its `updated` timestamp differs from `prev`
// (meaning our apply run finished) or the deadline passes. Resolves with the
// parsed status object, or null on timeout.
function pollStatus(actionId, deadline, onProgress) {
	return L.resolveDefault(fs.exec(communityHelper, [ 'status', actionId ]), {
		stdout: ''
	}).then(function(response) {
		var st = parseStatus((response && response.stdout) || '');
		if (st.action_id === actionId && st.state === 'running' && onProgress)
			onProgress(st);
		if (st.action_id === actionId && (st.state === 'ok' || st.state === 'error'))
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1500);
		}).then(function() {
			return pollStatus(actionId, deadline, onProgress);
		});
	});
}

function pollDomainRouter(actionId, deadline) {
	return L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
		code: 1, stdout: ''
	}).then(function(response) {
		var st = parseStatus((response || {}).stdout || '');
		if (st.action_id === actionId &&
		    (st.state === 'active' || st.state === 'disabled' || st.state === 'error'))
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1000);
		}).then(function() {
			return pollDomainRouter(actionId, deadline);
		});
	});
}

// Refresh the on-page status block without a full reload.
function updateStatusLine(st) {
	var pre = document.querySelector('#ikev2-status-line');
	if (!pre)
		return;
	if (!st) {
		return;
	}
	var lines = [];
	if (st.state)    lines.push('state=' + st.state);
	if (st.updated)  lines.push('updated=' + st.updated);
	if (st.services != null) lines.push('services=' + st.services);
	if (st.domains  != null) lines.push('domains=' + st.domains);
	if (st.cidrs != null) lines.push('cidrs=' + st.cidrs);
	if (st.custom_cidrs != null) lines.push('custom_cidrs=' + st.custom_cidrs);
	if (st.selected) lines.push('selected=' + st.selected);
	if (st.cached_services) lines.push('cached_services=' + st.cached_services);
	if (st.message)  lines.push('message=' + st.message);
	pre.textContent = lines.join('\n');
	pre.style.display = lines.length ? '' : 'none';
}

return view.extend({
	load: function() {
		return Promise.all([
			// Textarea is bound to the manual file only — never fall back to the
			// combined list, or clearing/editing would silently reappear.
			L.resolveDefault(fs.read(manualFile), ''),
			L.resolveDefault(fs.read(selectedFile), ''),
			L.resolveDefault(fs.read(statusFile), ''),
			L.resolveDefault(fs.exec(communityHelper, [ 'catalog' ]), {
				code: 1, stdout: ''
			}),
			L.resolveDefault(fs.read(domainFile), ''),
			L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.exec(communityHelper, [ 'ip-services' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.read(manualAddressFile), '')
		]);
	},

	doSave: function(result, onUpdated) {
		var textarea   = document.querySelector('#ikev2-domain-list');
		var addressTextarea = document.querySelector('#ikev2-address-list');
		var domains;
		var addresses;
		var selected = Object.keys(serviceSelection).sort();

		if (!textarea || !addressTextarea) {
			result.err(_('Editor is not ready.'));
			return Promise.reject(new Error('textarea-missing'));
		}

		try {
			domains = normalizeDomains(textarea.value);
			addresses = normalizeAddresses(addressTextarea.value);
		}
		catch (error) {
			result.err(error.message);
			return Promise.reject(error);
		}

		var manualValue   = domains.join('\n') + (domains.length ? '\n' : '');
		var addressValue = addresses.join('\n') + (addresses.length ? '\n' : '');
		var selectedValue = selected.join('\n') + (selected.length ? '\n' : '');

			var token = common.inputToken();
			var inputPrefix = '/tmp/ikev2-domains-input-' + token;
			return Promise.all([
				fs.write(inputPrefix + '.domains', manualValue, 384),
				fs.write(inputPrefix + '.cidrs', addressValue, 384),
				fs.write(inputPrefix + '.services', selectedValue, 384)
			])
					.then(function() {
						result.busy(_('Rebuilding the PBR list…'));
						return common.execChecked(communityHelper, [ 'schedule', token ],
							_('Unable to start the PBR rebuild')).then(function(response) {
							textarea.value = manualValue;
							addressTextarea.value = addressValue;
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollStatus(actionId, Date.now() + 120000, function(st) {
							if (st.message)
								result.busy(_(st.message));
						});
					});
				})
				.then(function(st) {
					updateStatusLine(st);
					if (onUpdated)
						onUpdated(st);

					if (!st) {
						result.warn(_('Saved; rebuild continues in the background.'));
						return;
					}
					if (st.state === 'ok') {
						result.ok(_('%s domains active').format(st.domains != null ? st.domains : '?'));
					}
					else {
						result.err(_('Rebuild failed: %s').format(st.message || _('unknown error')));
					}
				})
			.catch(function(error) {
				if (error.message !== 'textarea-missing')
					result.err(_('Unable to save: %s').format(error.message));
			});
	},


	render: function(data) {
		var self = this;

		/* ── Domains tab ────────────────────────────────────────────────── */
		var manual = data[0] || '';
		var manualAddresses = data[7] || '';
		var selected = {};
		var selectedLines = (data[1] || '').trim().split(/\s+/).filter(Boolean);
		var status = (data[2] || '').trim();
		var statusData = parseStatus(status);
		var routerStatus = parseStatus(((data[5] || {}).stdout || ''));
		var fakeipActive = routerStatus.engine === 'fakeip' &&
			routerStatus.service === 'running' &&
			routerStatus.nft === 'active' &&
			routerStatus.rule === 'active';
		var activeDomains = (data[4] || '').split('\n').filter(function(line) {
			return line.trim() && line.trim().charAt(0) !== '#';
		}).length;
		var policyPill = common.pill('', 'neutral');
		function updatePolicyStatus(st) {
			if (st && st.state === 'error') {
				common.setPill(policyPill, _('Policy error'), 'bad');
				return;
			}
			var active = st ? st.state === 'ok' :
				(statusData.state === 'ok' || activeDomains > 0);
			common.setPill(policyPill, active ? _('Policy active') : _('Policy empty'),
				active ? 'good' : 'warn');
		}
		updatePolicyStatus(null);
		var catalogResult = data[3] || {};
		var services = (catalogResult.stdout || '').trim().split(/\s+/)
			.filter(function(name) {
				return /^[a-z0-9_]+$/.test(name);
			});
		var ipServices = {};
		((data[6] || {}).stdout || '').trim().split(/\s+/)
			.filter(function(name) {
				return /^[a-z0-9_]+$/.test(name);
			})
			.forEach(function(name) {
				ipServices[name] = true;
			});

		for (var i = 0; i < selectedLines.length; i++)
			selected[selectedLines[i]] = true;
		serviceSelection = Object.assign({}, selected);

		var serviceNodes = renderServiceGroups(services, selected, ipServices);

		if (!serviceNodes.length) {
			serviceNodes.push(E('p', { 'class': 'alert-message warning' }, [
				_('The community catalog is temporarily unavailable. Saved selections and cached lists are preserved.')
			]));
		}

		var engineResult = common.inlineResult();
		var enginePill = common.pill(
			fakeipActive ? _('Reliable mode active') : _('Standard mode active'),
			fakeipActive ? 'good' : 'warn');
		var engineSummary = E('p', {
			'class': 'ikev2-engine-summary'
		}, [ fakeipActive ?
			_('Selected domains receive stable FakeIP addresses. Only connections to those addresses from covered networks enter the IKEv2 path.') :
			_('dnsmasq currently classifies domains by their public IP addresses. Existing connections may keep an earlier WAN route after an address changes.') ]);
		var engineButton = E('button', {
			'class': 'cbi-button ' + (fakeipActive ? 'cbi-button-reset' : 'cbi-button-apply')
		}, [ fakeipActive ? _('Use standard mode') : _('Enable reliable mode') ]);
		function updateEngineState(active, message) {
			fakeipActive = active;
			common.setPill(enginePill,
				active ? _('Reliable mode active') : _('Standard mode active'),
				active ? 'good' : 'warn');
			engineSummary.textContent = active ?
				_('Selected domains receive stable FakeIP addresses. Only connections to those addresses from covered networks enter the IKEv2 path.') :
				_('dnsmasq currently classifies domains by their public IP addresses. Existing connections may keep an earlier WAN route after an address changes.');
			engineButton.className = 'cbi-button ' +
				(active ? 'cbi-button-reset' : 'cbi-button-apply');
			engineButton.textContent = active ?
					_('Use standard mode') : _('Enable reliable mode');
			if (message)
				engineResult.ok(message);
		}
		engineButton.addEventListener('click', function() {
			var command = fakeipActive ? 'deactivate-async' : 'activate-async';
			var targetActive = !fakeipActive;
			return common.runAction({
				button: engineButton,
				result: engineResult,
				busy: fakeipActive ? _('Disabling...') : _('Enabling...'),
				run: function() {
					return common.execChecked(domainRouterHelper, [ command ],
						_('Unable to start routing-engine change')).then(function(response) {
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollDomainRouter(actionId, Date.now() + 60000);
					}).then(function(st) {
						if (!st)
							throw new Error(_('The operation continues in the background.'));
						if (st.state === 'error')
							throw new Error(st.message || _('Operation failed'));
						updateEngineState(targetActive, st.message || _('Saved.'));
					});
				}
			});
		});

		var domainsContent = E('div', {}, [
			common.section(_('Domain routing engine'),
				_('Reliable mode keeps selected domains on the IKEv2 route even when their public addresses change. Other traffic continues through the normal WAN.'),
				E('div', { 'class': 'ikev2-engine' }, [
					E('div', { 'class': 'ikev2-engine-head' }, [
						E('div', { 'class': 'ikev2-engine-state' }, [
							enginePill,
							engineSummary
						]),
						E('div', { 'class': 'ikev2-engine-action' }, [
							engineResult.node,
							engineButton
						])
					])
				])),
			common.section(_('Community services'),
				_('Curated targets are cached locally and merged atomically. Services marked IP also include their direct protocol networks. Broad infrastructure groups may route unrelated sites.'),
				E('div', {}, [
					E('div', {}, serviceNodes),
					E('pre', {
						'id': 'ikev2-status-line',
						'class': 'ikev2-status-box',
						'style': status ? '' : 'display:none;'
					}, [ status ])
				])),
			common.section(_('Custom domains'),
				_('One plain domain per line. Custom entries are never overwritten by service updates.'),
				E('textarea', {
					'id': 'ikev2-domain-list',
					'class': 'cbi-input-textarea ikev2-domain-editor',
					'spellcheck': 'false'
				}, [ manual ])),
			common.section(_('Custom IP addresses and networks'),
				_('One IPv4 address or CIDR network per line. A single address is stored as /32.'),
				E('textarea', {
					'id': 'ikev2-address-list',
					'class': 'cbi-input-textarea ikev2-domain-editor',
					'spellcheck': 'false',
					'placeholder': '203.0.113.10\n198.51.100.0/24'
				}, [ manualAddresses ]))
		]);

		var saveResult = common.inlineResult();
		var saveBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Save') ]);
		saveBtn.addEventListener('click', function() {
			return common.runAction({
				button: saveBtn,
				result: saveResult,
				busy: _('Saving...'),
				run: function() {
					return self.doSave(saveResult, updatePolicyStatus);
				}
			});
		});

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Policy Routing'),
					_('Build the IPv4 VPN policy from curated services, custom destinations and per-device modes.'),
					policyPill),
				domainsContent,
				E('div', { 'class': 'ikev2-note warn' }, [
					_('Clients must use router DNS. Plain DNS is redirected and DoT is blocked, but browser DoH and Apple Private Relay must still be disabled for deterministic domain routing.')
				]),
				E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1.1rem' }, [
					saveResult.node,
					saveBtn
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
