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
var serviceRecords = [];

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
function serviceChip(record, selected) {
	var name = record.id;
	var broad = BROAD_SERVICES.test(name);
	var ipNetworks = record.ip === '1';
	var input = E('input', {
		'type': 'checkbox',
		'class': 'ikev2-community-service',
		'value': name,
		'checked': selected[name] ? '' : null
	});
	var chip = E('label', {
		'class': 'ikev2-chip'
	}, [
		input,
		E('span', {}, [ record.label && record.label !== name ? record.label : serviceLabel(name) ]),
		broad ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Broad — may also route unrelated sites')
		}, [ '⚠' ]) : '',
		ipNetworks ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Includes direct service IP networks')
		}, [ 'IP' ]) : ''
	]);
	chip.className += (broad ? ' broad' : '') +
		(selected[name] ? ' selected' : '');
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
function renderServiceGroups(services, selected) {
	var available = {};
	services.forEach(function(record) { available[record.id] = record; });

	var used   = {};
	var blocks = [];

	function block(title, names) {
		var items = names.filter(function(n) {
			return available[n] && available[n].origin !== 'custom';
		})
			.map(function(n) {
				used[n] = true;
				return serviceChip(available[n], selected);
			});
		if (!items.length)
			return;
		blocks.push(E('div', { 'class': 'ikev2-chip-group' }, [
			E('h4', {}, [ _(title) ]),
			E('div', { 'class': 'ikev2-chips' }, items)
		]));
	}

	SERVICE_CATEGORIES.forEach(function(cat) { block(cat.title, cat.names); });

	var others = services.filter(function(record) {
		return record.origin !== 'custom' && !used[record.id];
	}).map(function(record) { return record.id; }).sort();
	block('Other', others);
	var custom = services.filter(function(record) {
		return record.origin === 'custom';
	}).sort(function(a, b) {
		return (a.label || a.id).localeCompare(b.label || b.id);
	});
	if (custom.length) {
		blocks.push(E('div', { 'class': 'ikev2-chip-group' }, [
			E('h4', {}, [ _('Custom services') ]),
			E('div', { 'class': 'ikev2-chips' }, custom.map(function(record) {
				return serviceChip(record, selected);
			}))
		]));
	}

	return blocks;
}

function parseServiceRecords(text) {
	return (text || '').replace(/\r/g, '').split('\n').map(function(line) {
		var fields = line.split('|');
		if (fields.length !== 5 || !/^[a-z0-9_]+$/.test(fields[0]))
			return null;
		return {
			id: fields[0], label: fields[1], origin: fields[2],
			customized: fields[3], ip: fields[4]
		};
	}).filter(Boolean);
}

function parseServiceDetails(text) {
	var details = { domains: '', cidrs: '' };
	var section = '';
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		if (line === '---domains---') { section = 'domains'; return; }
		if (line === '---cidrs---') { section = 'cidrs'; return; }
		if (section) {
			details[section] += line + '\n';
			return;
		}
		var eq = line.indexOf('=');
		if (eq > 0)
			details[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return details;
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

function pollResolverDiagnostic(actionId, deadline) {
	return L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
		code: 1, stdout: ''
	}).then(function(response) {
		var st = parseStatus((response || {}).stdout || '');
		if (st.action_id === actionId && st.state === 'error')
			return st;
		if (st.action_id === actionId && st.state === 'active' &&
		    (st.message || '').indexOf('FakeIP diagnostic completed;') === 0)
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1000);
		}).then(function() {
			return pollResolverDiagnostic(actionId, deadline);
		});
	});
}

// Refresh the on-page status block without a full reload.
// The active policy used to be printed as a raw key=value dump, internal service
// identifiers included - the same selection the chips above already show. Report
// the three numbers that actually say what is routed, in the cards the rest of
// the application uses.
function statusCards(st) {
	if (!st || (st.services == null && st.domains == null && st.cidrs == null))
		return [];
	var cidrs = Number(st.cidrs || 0);
	var custom = Number(st.custom_cidrs || 0);
	var tone = st.state === 'error' ? 'bad' : (st.state === 'running' ? 'warn' : 'good');
	var label = st.state === 'error' ? _('Failed') :
		(st.state === 'running' ? _('Rebuilding') : _('Active'));
	return [
		E('div', { 'class': 'ikev2-grid' }, [
			common.card(_('Services'), String(st.services != null ? st.services : '—'),
				st.message || _('Selected on this page')),
			common.card(_('Domains'), String(st.domains != null ? st.domains : '—'),
				_('Routed through the tunnel')),
			common.card(_('IP networks'), String(cidrs),
				custom ? _('Including your own: ') + custom : _('From selected services')),
			common.card(_('Policy'), label,
				st.updated ? _('Updated: ') + st.updated : '—')
		])
	];
}

function updateStatusLine(st) {
	var host = document.querySelector('#ikev2-status-line');
	if (!host || !st)
		return;
	var cards = statusCards(st);
	host.replaceChildren.apply(host, cards);
	host.style.display = cards.length ? '' : 'none';
}

return view.extend({
	load: function() {
		return Promise.all([
			// Textarea is bound to the manual file only — never fall back to the
			// combined list, or clearing/editing would silently reappear.
			L.resolveDefault(fs.read(manualFile), ''),
			L.resolveDefault(fs.read(selectedFile), ''),
			L.resolveDefault(fs.read(statusFile), ''),
			L.resolveDefault(fs.exec(communityHelper, [ 'services' ]), {
				code: 1, stdout: ''
			}),
			L.resolveDefault(fs.read(domainFile), ''),
			L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
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
		var manualAddresses = data[6] || '';
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
		serviceRecords = parseServiceRecords(catalogResult.stdout || '');

		for (var i = 0; i < selectedLines.length; i++)
			selected[selectedLines[i]] = true;
		serviceSelection = Object.assign({}, selected);

		var engineResult = common.inlineResult();
		var routerTraffic = E('input', {
			'type': 'checkbox',
			'class': 'cbi-input-checkbox',
			'checked': routerStatus.route_router_traffic === '1' ? '' : null
		});
		var routerTrafficResult = common.inlineResult();
		routerTraffic.addEventListener('change', function() {
			var desired = routerTraffic.checked;
			return runPageAction({
				button: routerTraffic,
				result: routerTrafficResult,
				busy: _('Saving...'),
				run: function() {
					return common.execChecked(domainRouterHelper,
						[ 'router-traffic', desired ? '1' : '0' ],
						_('Unable to update router traffic policy')).then(function() {
						routerTrafficResult.ok(_('Saved.'));
					}, function(error) {
						routerTraffic.checked = !desired;
						throw error;
					});
				}
			});
		});
		var logLevel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'error' }, [ _('Errors only') ]),
			E('option', { 'value': 'warn' }, [ _('Warnings (recommended)') ]),
			E('option', { 'value': 'info' }, [ _('Information') ]),
			E('option', { 'value': 'debug' }, [ _('Debug') ]),
			E('option', { 'value': 'trace' }, [ _('Trace') ])
		]);
		logLevel.value = routerStatus.log_level || 'warn';
		var logLevelResult = common.inlineResult();
		logLevel.addEventListener('change', function() {
			var previous = routerStatus.log_level || 'warn';
			var desired = logLevel.value;
			return runPageAction({
				button: logLevel,
				result: logLevelResult,
				busy: _('Applying...'),
				run: function() {
					return common.execChecked(domainRouterHelper, [ 'log-level', desired ],
						_('Unable to update log level')).then(function() {
						routerStatus.log_level = desired;
						logLevelResult.ok(_('Saved.'));
					}, function(error) {
						logLevel.value = previous;
						throw error;
					});
				}
			});
		});
		var resolverDiagnosticResult = common.inlineResult();
		var resolverDiagnosticButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button',
			'disabled': fakeipActive ? null : ''
		}, [ _('Capture debug log for 60 seconds') ]);
		resolverDiagnosticButton.addEventListener('click', function() {
			return runPageAction({
				button: resolverDiagnosticButton,
				result: resolverDiagnosticResult,
				busy: _('Capturing FakeIP diagnostics...'),
				run: function() {
					return common.execChecked(domainRouterHelper,
						[ 'diagnostic-start', '60' ],
						_('Unable to start FakeIP diagnostics')).then(function(response) {
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollResolverDiagnostic(actionId, Date.now() + 90000);
					}).then(function(st) {
						if (!st)
							throw new Error(_('Diagnostic timed out'));
						if (st.state === 'error')
							throw new Error(st.message || _('Diagnostic failed'));
						resolverDiagnosticResult.ok(st.message || _('Diagnostic completed.'));
					});
				}
			});
		});
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
			resolverDiagnosticButton.disabled = !active;
			if (message)
				engineResult.ok(message);
		}
		engineButton.addEventListener('click', function() {
			var command = fakeipActive ? 'deactivate-async' : 'activate-async';
			var targetActive = !fakeipActive;
			return runPageAction({
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

		var serviceResult = common.inlineResult();
		var serviceCatalog = E('div');
		var serviceEditor = E('div', {
			'class': 'ikev2-service-editor',
			'style': 'display:none;'
		});
		var serviceId = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': 'my_service'
		});
		var serviceName = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': _('My service')
		});
		var serviceDomains = E('textarea', {
			'class': 'cbi-input-textarea ikev2-domain-editor',
			'spellcheck': 'false',
			'placeholder': 'example.com\nstatic.example.com'
		});
		var serviceCidrs = E('textarea', {
			'class': 'cbi-input-textarea ikev2-domain-editor ikev2-domain-editor-small',
			'spellcheck': 'false',
			'placeholder': '203.0.113.0/24'
		});
		var serviceEditorTitle = E('h3');
		var servicePicker = E('select', {
			'class': 'cbi-input-select'
		});
		var servicePickerRow = E('div', {
			'class': 'ikev2-form-grid ikev2-service-picker'
		}, [
			common.fieldLabel(_('Service to edit'),
				_('Choose a service to inspect or edit.')),
			servicePicker
		]);
		var serviceSave = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'type': 'button'
		}, [ _('Save service') ]);
		var serviceReset = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'type': 'button'
		}, [ _('Restore prepared service') ]);
		var serviceDelete = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'type': 'button'
		}, [ _('Delete service') ]);
		var serviceCancel = E('button', {
			'class': 'cbi-button',
			'type': 'button'
		}, [ _('Cancel') ]);
		var editingService = null;
		var serviceLoadSequence = 0;
		var serviceBusy = false;
		var serviceDirty = false;
		var manageServicesButton;
		var addServiceButton;
		var saveBtn;

		var serviceFields = [ serviceId, serviceName, serviceDomains, serviceCidrs ];
		serviceFields.forEach(function(field) {
			field.addEventListener('input', function() { serviceDirty = true; });
			field.addEventListener('change', function() { serviceDirty = true; });
		});

		function serviceEditorVisible() {
			return serviceEditor.style.display !== 'none';
		}

		function confirmDiscardServiceChanges() {
			return !serviceEditorVisible() || !serviceDirty ||
				window.confirm(_('Discard unsaved service changes?'));
		}

		function setServiceControlsBusy(busy, activeButton) {
			serviceBusy = busy;
			serviceFields.forEach(function(field) {
				field.disabled = busy || (field === serviceId && !!editingService);
			});
			[ serviceSave, serviceReset, serviceDelete, serviceCancel,
			  manageServicesButton, addServiceButton, saveBtn, engineButton,
			  resolverDiagnosticButton, routerTraffic, logLevel ].forEach(function(button) {
				if (!button || button === activeButton)
					return;
				button.disabled = busy ||
					(button === resolverDiagnosticButton && !fakeipActive);
			});
			servicePicker.disabled = busy;
			var chips = serviceCatalog.querySelectorAll('input.ikev2-community-service');
			for (var i = 0; i < chips.length; i++)
				chips[i].disabled = busy;
		}

		function runPageAction(options) {
			if (serviceBusy)
				return Promise.resolve(null);
			setServiceControlsBusy(true, options.button);
			return common.runAction(options).finally(function() {
				setServiceControlsBusy(false, options.button);
			});
		}

		function runServiceAction(button, busyLabel, operation) {
			if (serviceBusy)
				return Promise.resolve(null);
			common.setBusy(button, true, busyLabel);
			setServiceControlsBusy(true, button);
			serviceResult.busy(busyLabel);
			return Promise.resolve().then(operation).catch(function(error) {
				serviceResult.err(error.message || _('Service update failed'));
				return null;
			}).finally(function() {
				setServiceControlsBusy(false, button);
				common.setBusy(button, false);
			});
		}

		function recordById(id) {
			for (var i = 0; i < serviceRecords.length; i++)
				if (serviceRecords[i].id === id)
					return serviceRecords[i];
			return null;
		}

		function renderCatalog() {
			while (serviceCatalog.firstChild)
				serviceCatalog.removeChild(serviceCatalog.firstChild);
			var nodes = renderServiceGroups(serviceRecords, serviceSelection);
			if (!nodes.length) {
				nodes.push(E('p', { 'class': 'alert-message warning' }, [
					_('The service catalog is unavailable. Saved selections and local services are preserved.')
				]));
			}
			nodes.forEach(function(node) { serviceCatalog.appendChild(node); });
		}

		function refreshServicePicker() {
			var current = servicePicker.value;
			var records = serviceRecords.slice().sort(function(a, b) {
				return (a.label || serviceLabel(a.id)).localeCompare(
					b.label || serviceLabel(b.id));
			});
			while (servicePicker.firstChild)
				servicePicker.removeChild(servicePicker.firstChild);
			records.forEach(function(record) {
				servicePicker.appendChild(E('option', {
					'value': record.id
				}, [ record.label && record.label !== record.id ?
					record.label : serviceLabel(record.id) ]));
			});
			if (recordById(current))
				servicePicker.value = current;
			else if (editingService && recordById(editingService.id))
				servicePicker.value = editingService.id;
		}

		function refreshServiceRecords() {
			return common.execChecked(communityHelper, [ 'services' ],
				_('Unable to refresh the service catalog')).then(function(response) {
				serviceRecords = parseServiceRecords(response.stdout || '');
				refreshServicePicker();
			});
		}

		function showServiceEditor(record, details) {
			editingService = record || null;
			serviceEditorTitle.textContent = record ?
				_('Edit service') : _('New service');
			servicePickerRow.style.display = record ? '' : 'none';
			if (record)
				servicePicker.value = record.id;
			serviceId.value = record ? record.id : '';
			serviceId.disabled = !!record;
			serviceName.value = details ?
				(details.label === record.id ? serviceLabel(record.id) : details.label) : '';
			serviceDomains.value = details ? details.domains.replace(/\n$/, '') : '';
			serviceCidrs.value = details ? details.cidrs.replace(/\n$/, '') : '';
			serviceReset.style.display = record && record.origin !== 'custom' &&
				record.customized === '1' ? '' : 'none';
			serviceDelete.style.display = record && record.origin === 'custom' ? '' : 'none';
			serviceEditor.style.display = '';
			serviceDirty = false;
			serviceResult.clear();
			(record ? serviceName : serviceId).focus();
		}

		function openService(record, sourceButton) {
			if (serviceBusy)
				return Promise.resolve(null);
			var sequence = ++serviceLoadSequence;
			if (sourceButton)
				common.setBusy(sourceButton, true, _('Loading service...'));
			setServiceControlsBusy(true, sourceButton);
			serviceResult.busy(_('Loading service...'));
			return common.execChecked(communityHelper, [ 'service-read', record.id ],
				_('Unable to load service')).then(function(response) {
				if (sequence !== serviceLoadSequence)
					return;
				showServiceEditor(record, parseServiceDetails(response.stdout || ''));
			}, function(error) {
				if (sequence !== serviceLoadSequence)
					return;
				serviceResult.err(error.message);
			}).finally(function() {
				setServiceControlsBusy(false, sourceButton);
				if (sourceButton)
					common.setBusy(sourceButton, false);
			});
		}

		function requestService(record, sourceButton) {
			if (!record || serviceBusy)
				return Promise.resolve(null);
			if (serviceEditorVisible() && editingService &&
			    editingService.id === record.id) {
				serviceEditor.scrollIntoView({ block: 'nearest' });
				serviceName.focus();
				return Promise.resolve(record);
			}
			if (!confirmDiscardServiceChanges()) {
				if (editingService)
					servicePicker.value = editingService.id;
				return Promise.resolve(null);
			}
			serviceDirty = false;
			return openService(record, sourceButton);
		}

		function serviceMeta(operation, id, label) {
			return 'operation=' + operation + '\n' +
				'id=' + id + '\n' +
				'label=' + label + '\n' +
				'selected=' + (operation === 'delete' ? '0' : 'keep') + '\n';
		}

		function reconcileServiceRecord(operation, previous, id, label, hasCidrs) {
			serviceRecords = serviceRecords.filter(function(record) {
				return record.id !== id;
			});
			if (operation === 'delete')
				return;
			if (operation === 'reset') {
				serviceRecords.push({
					id: id, label: id, origin: 'builtin', customized: '0',
					ip: previous && previous.ip === '1' ? '1' : '0'
				});
				return;
			}
			serviceRecords.push({
				id: id,
				label: label,
				origin: previous && previous.origin === 'custom' ? 'custom' :
					(previous ? 'override' : 'custom'),
				customized: '1',
				ip: hasCidrs ? '1' : '0'
			});
		}

		function runServiceOperation(operation) {
			var id = (serviceId.value || '').trim().toLowerCase();
			var label = (serviceName.value || '').trim();
			var previous = editingService;
			var domains = [];
			var cidrs = [];
			if (!/^[a-z0-9_]{2,48}$/.test(id))
				return Promise.reject(new Error(_('Service identifier must contain 2–48 lowercase letters, digits or underscores.')));
			if (!editingService && recordById(id))
				return Promise.reject(new Error(_('A service with this identifier already exists.')));
			if (operation === 'save') {
				if (!label || label.length > 80 || /[|\r\n]/.test(label))
					return Promise.reject(new Error(_('Enter a service name up to 80 characters.')));
				try {
					domains = normalizeDomains(serviceDomains.value);
					cidrs = normalizeAddresses(serviceCidrs.value);
				}
				catch (error) {
					return Promise.reject(error);
				}
				if (!domains.length && !cidrs.length)
					return Promise.reject(new Error(_('Add at least one domain or IPv4 network.')));
			}
			var token = common.inputToken();
			var prefix = '/tmp/ikev2-service-input-' + token;
			return Promise.all([
				fs.write(prefix + '.meta', serviceMeta(operation, id, label), 384),
				fs.write(prefix + '.domains', domains.join('\n') + (domains.length ? '\n' : ''), 384),
				fs.write(prefix + '.cidrs', cidrs.join('\n') + (cidrs.length ? '\n' : ''), 384)
			]).then(function() {
				return common.execChecked(communityHelper, [ 'service-schedule', token ],
					_('Unable to start service update'));
			}).then(function(response) {
				var actionId = parseStatus(response.stdout || '').action_id;
				if (!actionId)
					throw new Error(_('Action did not start'));
				return pollStatus(actionId, Date.now() + 120000, function(st) {
					if (st.message)
						serviceResult.busy(_(st.message));
				});
			}).then(function(st) {
				if (!st)
					throw new Error(_('The operation is still running in the background.'));
				if (st.state !== 'ok')
					throw new Error(st.message || _('Service update failed'));
				if (operation === 'delete')
					delete serviceSelection[id];
				return refreshServiceRecords().then(function() { return true; },
					function() { return false; });
			}).then(function(refreshed) {
				if (!refreshed) {
					reconcileServiceRecord(operation, previous, id, label, cidrs.length > 0);
					refreshServicePicker();
				}
				serviceEditor.style.display = 'none';
				serviceDirty = false;
				renderCatalog();
				var success = operation === 'delete' ? _('Custom service deleted and policy rebuilt.') :
					(operation === 'reset' ? _('Prepared service restored and policy rebuilt.') :
					 _('Service saved. Active policy was rebuilt when required.'));
				if (refreshed)
					serviceResult.ok(success);
				else
					serviceResult.warn(success + ' ' + _('Reload the page to refresh the service catalog.'));
			});
		}

		serviceSave.addEventListener('click', function() {
			return runServiceAction(serviceSave, _('Saving service...'),
				function() { return runServiceOperation('save'); });
		});
		serviceReset.addEventListener('click', function() {
			if (!window.confirm(_('Discard this local override and restore the prepared service?')))
				return;
			return runServiceAction(serviceReset, _('Restoring service...'),
				function() { return runServiceOperation('reset'); });
		});
		serviceDelete.addEventListener('click', function() {
			if (!window.confirm(_('Delete this custom service?')))
				return;
			return runServiceAction(serviceDelete, _('Deleting service...'),
				function() { return runServiceOperation('delete'); });
		});
		serviceCancel.addEventListener('click', function() {
			if (serviceBusy || !confirmDiscardServiceChanges())
				return;
			serviceLoadSequence++;
			serviceEditor.style.display = 'none';
			serviceDirty = false;
			serviceResult.clear();
		});
		servicePicker.addEventListener('change', function() {
			var record = recordById(servicePicker.value);
			if (record)
				requestService(record, null);
		});

		addServiceButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button'
		}, [ _('Add service') ]);
		addServiceButton.addEventListener('click', function() {
			if (serviceBusy || !confirmDiscardServiceChanges())
				return;
			serviceLoadSequence++;
			showServiceEditor(null, null);
		});
		serviceEditor.appendChild(E('div', { 'class': 'ikev2-service-editor-heading' }, [
			serviceEditorTitle,
			addServiceButton
		]));
		serviceEditor.appendChild(servicePickerRow);
		serviceEditor.appendChild(E('div', { 'class': 'ikev2-form-grid' }, [
			common.fieldLabel(_('Identifier'), _('Stable internal name; it cannot be changed after creation.')),
			serviceId,
			common.fieldLabel(_('Service name')),
			serviceName,
			common.fieldLabel(_('Domain suffixes'), _('One domain suffix per line. Subdomains are included automatically.')),
			serviceDomains,
			common.fieldLabel(_('IPv4 addresses and networks'), _('Optional; one IPv4 address or CIDR per line.')),
			serviceCidrs
		]));
		serviceEditor.appendChild(E('div', { 'class': 'ikev2-actions end' }, [
			serviceCancel, serviceReset, serviceDelete, serviceSave
		]));
		manageServicesButton = E('button', {
			'class': 'cbi-button cbi-button-action ikev2-icon-button',
			'type': 'button'
		}, [ common.icon('settings'), E('span', {}, [ _('Manage services') ]) ]);
		manageServicesButton.addEventListener('click', function() {
			var record = recordById(servicePicker.value) || serviceRecords[0];
			if (record)
				requestService(record, manageServicesButton);
			else
				showServiceEditor(null, null);
		});
		refreshServicePicker();
		renderCatalog();

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
					]),
					E('div', { 'style': 'margin-top:1rem' }, [
						common.toggleRow(routerTraffic,
							_('Route router services by domain policy'),
							_('In Reliable mode, selected domains requested by services on this router use the outbound tunnel. Tunnel transport and local management addresses remain direct.'),
							routerTrafficResult.node)
					]),
					E('details', { 'class': 'ikev2-advanced', 'style': 'margin-top:1rem' }, [
						E('summary', {}, [ _('Logging') ]),
						E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
							common.fieldLabel(_('FakeIP resolver log level'),
								_('Warnings are quiet enough for normal operation. Information, debug and trace can quickly evict unrelated system events. Changing this while Reliable mode is active restarts its resolver.')),
							logLevel,
							common.fieldLabel(_('Temporary diagnostics'),
								_('Temporarily switches the FakeIP resolver to debug logging, then restores the selected normal level automatically. Starting and ending the capture restart the resolver.')),
							resolverDiagnosticButton
						]),
						Number(routerStatus.system_log_size || 0) > 0 &&
						Number(routerStatus.system_log_size || 0) < 512 ?
							E('div', { 'class': 'ikev2-note warn', 'style': 'margin-top:.75rem' }, [
								_('The system log buffer is only %s KiB. Keep the normal level at Warnings and use timed diagnostics for troubleshooting.').format(routerStatus.system_log_size)
							]) : '',
						logLevelResult.node,
						resolverDiagnosticResult.node
					])
				])),
			common.section(_('Services'),
				_('Prepared and user-created services stay in separate lists. Chips stage policy selection; the page Save button applies it. Service definitions are managed independently.'),
				E('div', {}, [
					serviceCatalog,
					serviceEditor,
					serviceResult.node,
					E('div', { 'id': 'ikev2-status-line' }, statusCards(statusData))
				]), E('div', { 'class': 'ikev2-actions' }, [
					manageServicesButton
				])),
			E('div', { 'class': 'ikev2-destination-editors' }, [
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
			])
		]);

		var saveResult = common.inlineResult();
		saveBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Save') ]);
		saveBtn.addEventListener('click', function() {
			return runPageAction({
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
