'use strict';
'require view';
'require fs';
'require ikev2-manager.shared as common';

// Shadow the global _() with the project translator for this module only;
// see the note in shared.js about not replacing window._.
var _ = common.t;

var helper = '/usr/libexec/ikev2-manager-system';
var devicesHelper = '/usr/libexec/ikev2-devices';
var depsStatusFile = '/tmp/ikev2-manager-deps.status';

function parseStatus(text) {
	var out = {};
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var eq = line.indexOf('=');
		if (eq > 0) out[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return out;
}

function dependenciesReady(doctor) {
	return doctor && doctor.dependencies_ok === '1';
}

function dependenciesKnown(doctor) {
	return doctor && (doctor.dependencies_ok === '1' || doctor.dependencies_ok === '0');
}

// install-deps detaches and reports through depsStatusFile; poll until the
// run after `prev` finishes (state ok/error) or the deadline passes.
function pollDeps(actionId, deadline, result) {
	return L.resolveDefault(fs.read(depsStatusFile), '').then(function(txt) {
		var st = parseStatus(txt);
		if (st.action_id === actionId && st.message)
			result.busy(_(st.message));
		if ((st.state === 'ok' || st.state === 'error') && st.action_id === actionId)
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(r) { window.setTimeout(r, 2000); }).then(function() {
			return pollDeps(actionId, deadline, result);
		});
	});
}

function runDepsJob(button, cmd, result, doneMsg, refresh) {
	return common.runAction({
		button: button,
		result: result,
		busy: _('Working...'),
		run: function() {
			return common.execChecked(helper, [ cmd ], _('Operation failed')).then(function(response) {
				var actionId = parseStatus(response.stdout || '').action_id;
				if (!actionId)
					throw new Error(_('Action did not start'));
				return pollDeps(actionId, Date.now() + 300000, result);
			}).then(function(st) {
				if (!st) {
					result.warn(_('The operation continues in the background. You can use the button again.'));
				}
				else if (st.state === 'error') {
					throw new Error(st.message ? _(st.message) : _('Operation failed'));
				}
				else {
					result.ok(doneMsg);
					return refresh();
				}
			});
		}
	});
}

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

// "name=192.168.2.0/24" lines from `ikev2-devices networks`
function parseNetworks(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').map(function(line) {
		var eq = line.indexOf('=');
		return eq > 0 ? { name: line.slice(0, eq), cidr: line.slice(eq + 1) } : null;
	}).filter(Boolean);
}

function parseDeviceDump(stdout) {
	var entries = [];
	(stdout || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		line = line.trim();
		if (!line) return;
		var entry = {};
		line.split(' ').forEach(function(part) {
			var eq = part.indexOf('=');
			if (eq > 0) entry[part.slice(0, eq)] = part.slice(eq + 1);
		});
		if (entry.addr && entry.mode) entries.push(entry);
	});
	return entries;
}

function parseClients(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').map(function(line) {
		var fields = line.split('\t');
		if (!fields[0]) return null;
		return { addr: fields[0], name: fields[1] || '', mac: fields[2] || '' };
	}).filter(Boolean);
}

function parseDeviceStats(stdout) {
	var stats = {};
	(stdout || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var item = {};
		line.split(' ').forEach(function(field) {
			var eq = field.indexOf('=');
			if (eq > 0) item[field.slice(0, eq)] = field.slice(eq + 1);
		});
		if (item.addr && item.kind)
			stats[item.kind + ':' + item.addr] = item;
	});
	return stats;
}

function validateAddr(addr) {
	return addr.length > 0 && addr.length < 50 &&
		/^[0-9.]+(\/[0-9]{1,2})?$/.test(addr);
}

function domainRuntimeStatus(value) {
	if (value.domain_engine !== 'fakeip') {
		return {
			label: _('Standard mode active'),
			tone: 'neutral',
			detail: _('PBR currently classifies selected services by their resolved public IP addresses. Configure the engine on the Policy Routing page.')
		};
	}
	if (value.domain_healthy === 'yes') {
		return {
			label: _('Reliable mode active'), tone: 'good',
			detail: _('sing-box FakeIP and nftables TProxy classify selected services. Configure the engine on the Policy Routing page.')
		};
	}
	var detail;
	if (value.domain_state === 'running')
		detail = _('Reliable domain routing is still updating.');
	else if (value.domain_service !== 'running')
		detail = _('The reliable domain-router service is stopped.');
	else if (value.domain_dnsmasq_upstream !== '127.0.0.42')
		detail = _('dnsmasq is not using the FakeIP resolver.');
	else if (value.domain_dnsmasq_cache !== '0')
		detail = _('dnsmasq caching is still enabled in reliable mode.');
	else if (value.domain_nft !== 'active')
		detail = _('Reliable-mode nftables rules are missing.');
	else if (value.domain_rule !== 'active')
		detail = _('Reliable-mode policy routing rule is missing.');
	else
		detail = value.domain_message ? _(value.domain_message) :
			_('Reliable domain routing failed a runtime health check.');
	return { label: _('Reliable mode degraded'), tone: 'bad', detail: detail };
}

function checkRows(doctor) {
	var labels = {
		diagnostic_status: _('Readiness check'),
		firmware_source: _('Firmware source'),
		openwrt: _('OpenWrt release'),
		board_model: _('Router model'),
		target: _('OpenWrt target'),
		architecture: _('Architecture'),
		kernel: _('Kernel'),
		package_manager: _('Package manager'),
		package_feeds: _('Package feeds'),
		storage_free: _('Persistent storage free'),
		tmp_free: _('Temporary storage free'),
		memory_available: _('Available memory'),
		system_clock: _('System clock'),
		crypto_acceleration: _('Crypto acceleration'),
		flow_offloading: _('Flow offloading'),
		resource_conflict: _('Reserved resource conflicts'),
		upnp_ikev2_ports: _('UPnP reservation for IKEv2'),
		firewall4: _('firewall4'),
		firewall4_config: _('Firewall configuration'),
		dnsmasq_nftset: _('dnsmasq nftset support'),
		dnsproxy: _('Encrypted DNS proxy'),
		dns_segments: _('Destination DNS segments'),
		curl: _('HTTP client'),
		sing_box: _('sing-box domain router'),
		sing_box_fakeip: _('FakeIP allocator'),
		nft_tproxy: _('nftables TProxy support'),
		pbr_service: _('PBR service'),
		pbr_version: _('PBR version'),
		failclosed_route: _('Fail-closed route'),
		failclosed_ipv6_route: _('IPv6 fail-closed route'),
		xfrm_module: _('XFRM interface module'),
		xfrm_ifid_conflict: _('XFRM if_id conflict'),
		xfrm_name_conflict: _('XFRM name conflict'),
		swanctl: _('strongSwan swanctl'),
		swanmon: _('strongSwan monitoring'),
		strongswan_kernel_netlink: _('strongSwan kernel-netlink'),
		strongswan_vici: _('strongSwan VICI'),
		strongswan_openssl: _('strongSwan OpenSSL'),
		strongswan_eap_mschapv2: _('strongSwan EAP-MSCHAPv2'),
		strongswan_eap_client_security: _('Outbound EAP security'),
		strongswan_eap_server_security: _('Inbound strongSwan version'),
		strongswan_cohort: _('strongSwan package cohort'),
		strongswan_x509: _('strongSwan X.509'),
		device_policy_runtime: _('Device policy runtime')
	};
	var rows = [];
	Object.keys(labels).forEach(function(key) {
		if (doctor[key] == null)
			return;
		var value = doctor[key];
		var good = value === 'ok' || value === 'none' || value.indexOf('ok:') === 0;
		var warn = value.indexOf('warn:') === 0;
		var notice = value.indexOf('notice:') === 0;
		var shown = value.replace(/^(ok|warn|notice|invalid):/, '');
		if ((key === 'storage_free' || key === 'tmp_free' || key === 'memory_available') &&
		    /^\d+KiB$/.test(shown)) {
			shown = common.formatBytes(Number(shown.slice(0, -3)) * 1024);
		}
		else if (key === 'system_clock') {
			var clock = new Date(shown);
			if (!isNaN(clock.getTime()))
				shown = clock.toLocaleString();
		}
		rows.push({
			key: key,
			label: labels[key],
			value: common.pill(_(shown), good ? 'good' : (notice ? 'info' : (warn ? 'warn' : 'bad'))),
			tone: good ? 'good' : (notice ? 'info' : (warn ? 'warn' : 'bad'))
		});
	});
	return rows;
}

function rowPairs(rows) {
	return rows.map(function(row) { return [ row.label, row.value ]; });
}

function dependencyOverview(rows) {
	var useful = {
		diagnostic_status: true,
		openwrt: true,
		storage_free: true,
		memory_available: true,
		resource_conflict: true,
		upnp_ikev2_ports: true,
		firewall4_config: true,
		dnsproxy: true,
		dns_segments: true,
		sing_box: true,
		sing_box_fakeip: true,
		pbr_version: true,
		failclosed_route: true,
		xfrm_module: true,
		strongswan_eap_client_security: true,
		strongswan_eap_server_security: true,
		device_policy_runtime: true
	};
	var issues = rows.filter(function(row) {
		return row.tone === 'bad' || row.tone === 'warn';
	});
	var details = rows.filter(function(row) { return useful[row.key]; });
	var half = Math.ceil(details.length / 2);
	return E('div', {}, [
		issues.length ? E('div', { 'class': 'ikev2-dependency-issues' },
			issues.map(function(row) {
				return E('div', { 'class': 'ikev2-health-row' }, [
					E('strong', {}, [ row.label ]),
					row.value
				]);
			})) : '',
		E('details', { 'class': 'ikev2-diagnostics' }, [
			E('summary', {}, [ _('Technical details') ]),
			E('div', { 'class': 'ikev2-diagnostics-body' }, [
				E('div', { 'class': 'ikev2-two-col' }, [
					common.keyValueTable(rowPairs(details.slice(0, half))),
					common.keyValueTable(rowPairs(details.slice(half)))
				])
			])
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'get' ]), { stdout: '' }),
			// A failed RPC is not evidence that packages are missing. Preserve an
			// explicit unknown state so the page cannot offer a destructive repair
			// for a transient diagnostic failure.
			L.resolveDefault(fs.exec(helper, [ 'doctor-ui' ]), {
				stdout: 'diagnostic_status=unavailable\ndependencies_ok=unknown\n'
			}),
			L.resolveDefault(fs.exec(devicesHelper, [ 'networks' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(devicesHelper, [ 'dump' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(devicesHelper, [ 'clients' ]), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/libexec/ikev2-device-routing', [ 'stats' ]), { stdout: '' })
		]);
	},

	// Persist a device change, then refresh every device panel from one snapshot
	// without forcing a page reload or losing the user's scroll position.
	deviceAction: function(args, busyBtn, result, onSaved) {
		var self = this;
		return common.runJob({
			button: busyBtn,
			result: result,
			busy: _('Saving...'),
			success: _('Saved'),
			failure: _('Operation failed'),
			startPath: helper,
			startArgs: [ 'device-async' ].concat(args),
			statusPath: helper,
			statusArgs: [ 'action-status' ],
			timeout: 150000,
			timeoutMessage: _('The operation continues in the background. You can use the button again.'),
			onSuccess: function(st) {
				if (st && st.state !== 'timeout') {
					return common.execChecked(devicesHelper, [ 'dump' ],
						_('Could not refresh device rules')).then(function(response) {
					(self.deviceRefreshers || []).forEach(function(refresh) {
						refresh(response.stdout || '');
					});
						if (onSaved)
							onSaved(response.stdout || '');
					});
				}
			}
		});
	},

	// Keep routing and independent PBR, DNS and DPI opt-outs in one compact row.
	renderDevicePolicies: function(dumpStdout, clientsStdout, statsStdout) {
		var self = this;
		var clients = parseClients(clientsStdout);
		var clientsByAddr = {};
		clients.forEach(function(client) { clientsByAddr[client.addr] = client; });
		var stats = parseDeviceStats(statsStdout);
		var list = E('div', { 'class': 'ikev2-device-policy-scroll' }, []);
		var result = common.inlineResult();
		var lastDump = dumpStdout;

		function policyCheck(entry, field, title, checks) {
			var checked = field === 'pbr' ? entry.mode === 'exclude' : entry[field] === '1';
			var control = E('input', {
				'type': 'checkbox',
				'checked': checked ? '' : null,
				'aria-label': title
			});
			var node = E('label', {
				'class': 'ikev2-policy-check',
				'title': title
			}, [ control, E('span', {}) ]);
			checks[field] = control;
			control.addEventListener('change', function() {
				var values = [ 'set-exclusions', entry.addr,
					checks.pbr.checked ? '1' : '0',
					checks.dns.checked ? '1' : '0',
					checks.dpi.checked ? '1' : '0' ];
				Object.keys(checks).forEach(function(key) { checks[key].disabled = true; });
				self.deviceAction(values, null, result).then(function(status) {
					if (!status)
						refreshList(lastDump);
				});
			});
			return node;
		}

		function refreshList(stdout) {
			lastDump = stdout;
			var entries = parseDeviceDump(stdout).filter(function(entry) {
				return entry.mode === 'fullroute' || entry.mode === 'exclude' ||
					entry.dns === '1' || entry.dpi === '1';
			});
			if (!entries.length) {
				list.replaceChildren(E('div', { 'class': 'ikev2-empty' }, [
					E('strong', {}, [ _('No device rules') ]),
					E('div', { 'class': 'cbi-section-descr' }, [
						_('All devices use the default PBR, DNS and Zapret policies.') ])
				]));
				return;
			}

			list.replaceChildren(E('div', { 'class': 'ikev2-device-policy-table' }, [
				E('div', { 'class': 'ikev2-device-policy-row head' }, [
					E('span', {}, [ _('Device / IP') ]),
					E('span', {}, [ _('Type') ]),
					E('span', {}, [ 'PBR' ]),
					E('span', {}, [ 'DNS' ]),
					E('span', {}, [ 'Zapret' ]),
					E('span', {}, [ _('Matched traffic') ]),
					E('span', {})
				])
			].concat(entries.map(function(entry) {
				var included = entry.mode === 'fullroute';
				var client = clientsByAddr[entry.addr];
				var hit = stats[(included ? 'fullroute' : 'exclude') + ':' + entry.addr] || {};
				var remove = E('button', {
					'class': 'cbi-button cbi-button-remove ikev2-square-action',
					'type': 'button',
					'title': _('Remove'),
					'aria-label': _('Remove')
				}, [ common.icon('trash') ]);
				remove.addEventListener('click', function() {
					self.deviceAction([ 'clear-policy', entry.addr ], remove, result);
				});
				var checks = {};
				return E('div', { 'class': 'ikev2-device-policy-row' }, [
					E('span', { 'class': 'ikev2-device-policy-name' }, [
						client && client.name ? E('strong', {}, [ client.name ]) : '',
						E('code', {}, [ entry.addr ])
					]),
					E('span', {}, [ common.pill(included ? _('Inclusion') : _('Exclusion'),
						included ? 'good' : 'warn') ]),
					included ? E('span', { 'class': 'ikev2-policy-na' }, [ '—' ]) :
						policyCheck(entry, 'pbr', _('Exclude from project PBR'), checks),
					included ? E('span', { 'class': 'ikev2-policy-na' }, [ '—' ]) :
						policyCheck(entry, 'dns', _('Use the device DNS without interception'), checks),
					included ? E('span', { 'class': 'ikev2-policy-na' }, [ '—' ]) :
						policyCheck(entry, 'dpi', _('Bypass Zapret processing'), checks),
					E('span', { 'class': 'ikev2-device-policy-traffic' }, [
						common.formatBytes(Number(hit.bytes || 0)) + ' · ' +
						_('%d packets').format(Number(hit.packets || 0)) ]),
					remove
				]);
			}))));
		}

		refreshList(dumpStdout);
		(this.deviceRefreshers || (this.deviceRefreshers = [])).push(refreshList);

		var choices = clients.map(function(client) {
			return {
				value: client.addr,
				label: (client.name || _('Connected device')) + ' — ' + client.addr +
					(client.mac ? ' · ' + client.mac : '')
			};
		});
		var addr = common.choiceWithCustom(choices.length ? choices[0].value : '',
			choices, { placeholder: '192.168.2.55' });
		var type = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'exclude' }, [ _('Exclusion') ]),
			E('option', { 'value': 'include' }, [ _('Include — all traffic through VPN') ])
		]);
		var add = E('button', {
			'class': 'cbi-button cbi-button-add', 'type': 'button'
		}, [ _('Add') ]);
		add.addEventListener('click', function() {
			var value = addr.value();
			if (!validateAddr(value)) {
				result.err(_('Invalid address'));
				return;
			}
			var action = type.value === 'include' ?
				[ 'set-included', value ] : [ 'set-exclusions', value, '1', '0', '0' ];
			self.deviceAction(action, add, result, function() {
				addr.setValue(choices.length ? choices[0].value : '');
			});
		});

		return E('div', {}, [
			list,
			E('div', { 'class': 'ikev2-inline-form', 'style': 'margin-top:1rem' }, [
				E('div', { 'class': 'ikev2-device-picker' }, [ addr.node ]),
				type, result.node, add
			])
		]);
	},

	render: function(data) {
		var self = this;
		this.deviceRefreshers = [];
		var value = common.parseKeyValues(data[0].stdout);
		var doctor = common.parseKeyValues(data[1].stdout);
		var netList = parseNetworks(data[2].stdout);
		var depRows = checkRows(doctor);
		var ready = dependenciesReady(doctor);

		var enabled = input('checkbox', value.configured);
		var dnsEnforce = input('checkbox', value.dns_enforce);
		var blockDot = input('checkbox', value.block_dot);
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Apply') ]);
		var applyResult = common.inlineResult();
		var installDeps = E('button', { 'class': 'cbi-button cbi-button-action' }, [
			_('Install runtime dependencies') ]);
		var removeDeps = E('button', { 'class': 'cbi-button cbi-button-remove' }, [
			_('Reset app and remove dependencies') ]);
		var domainRuntime = domainRuntimeStatus(value);
		var headerPill = common.pill('', 'neutral');
		var managedDescription = E('p', {});
		var managedToggle = common.toggleRow(enabled, _('Let the app manage the router'), '');
		var domainDetail = E('span', { 'class': 'ikev2-toggle-sub' });
		var domainPill = common.pill('', 'neutral');
		var depsChecks = E('div', {});
		var depsResult = common.inlineResult();
		var depsPill = common.pill('', 'neutral');

		function renderDependencyChecks() {
			depRows = checkRows(doctor);
			depsChecks.replaceChildren(dependencyOverview(depRows));
		}

		function updateSetupState() {
			ready = dependenciesReady(doctor);
			var known = dependenciesKnown(doctor);
			domainRuntime = domainRuntimeStatus(value);
			enabled.checked = value.configured === '1';
			// Disabling must always remain available for an already managed router,
			// even when a runtime check is degraded. Package readiness only gates a
			// fresh enable; runtime drift is repaired by Apply, not dependency install.
			enabled.disabled = value.configured !== '1' && !ready;
			save.disabled = value.configured !== '1' && !ready;
			managedDescription.textContent = ready ?
				_('Master switch: lets the app create and own the router routing, firewall and PBR. Network and DNS changes are applied together by the button at the bottom.') :
				(known ? _('Install the runtime dependencies below first — then this switch becomes available.') :
					_('Runtime dependencies could not be checked. Reload the page and try again.'));
			var toggleSub = managedToggle.querySelector('.ikev2-toggle-sub');
			if (toggleSub)
				toggleSub.textContent = ready ?
					_('Creates and owns routing, firewall and PBR on the router.') :
				(known ? _('Available after runtime dependencies are installed.') :
					_('Available after the runtime check succeeds.'));
			common.setPill(headerPill,
				value.configured === '1' ? _('Configured') : _('Not configured'),
				value.configured === '1' ? 'good' : 'warn');
			domainDetail.textContent = domainRuntime.detail;
			common.setPill(domainPill, domainRuntime.label, domainRuntime.tone);
			common.setPill(depsPill,
				ready ? _('Ready') : (known ? _('Dependencies missing') : _('Check unavailable')),
				ready ? 'good' : (known ? 'bad' : 'warn'));
			installDeps.style.display = known && !ready ? '' : 'none';
			removeDeps.style.display = ready ? '' : 'none';
			renderDependencyChecks();
		}

		function refreshSetupState() {
			return Promise.all([
				common.execChecked(helper, [ 'get' ], _('Unable to refresh configuration')),
				common.execChecked(helper, [ 'doctor-ui' ], _('Unable to refresh system readiness'))
			]).then(function(results) {
				value = common.parseKeyValues(results[0].stdout || '');
				doctor = common.parseKeyValues(results[1].stdout || '');
				updateSetupState();
			});
		}

		// ── Network selectors ────────────────────────────────────────────
		var wanField, protectedField;

		// The inbound VPN server is a selectable "network": when on, its clients
		// (ipsec-in) follow the same domain policy as local networks.
		var vpnPick = value.server_enabled === '1'
			? common.netPick('__vpn__', _('VPN server'), _('Inbound clients (ipsec-in)'),
				value.source_include_vpn !== '0')
			: null;

		wanField = common.choiceWithCustom(value.wan_interface, netList.map(function(o) {
			return { value: o.name, label: o.name + ' — ' + o.cidr };
		}), { placeholder: 'wan' });
		protectedField = common.multiChoiceWithCustom(value.source_interfaces,
			netList.filter(function(o) { return o.name !== value.wan_interface; })
				.map(function(o) {
					return { value: o.name, name: o.name, meta: o.cidr };
				}),
			{
				placeholder: 'lan iot',
				prependNodes: vpnPick ? [ vpnPick.node ] : [],
				customBelow: true
			});
		var protectedNode = protectedField.node;

		save.addEventListener('click', function() {
			var selectedWan = wanField.value();
			var protectedVal = protectedField.value().split(/\s+/).filter(function(name) {
				return name && name !== selectedWan;
			}).join(' ');
			var args = [
				'set',
				enabled.checked ? '1' : '0',
				selectedWan,
				protectedVal,
				dnsEnforce.checked ? '1' : '0',
				blockDot.checked ? '1' : '0',
				vpnPick ? (vpnPick.input.checked ? '1' : '0') : (value.source_include_vpn || '1')
			];
			args[0] = 'set-async';
			return common.runJob({
				button: save,
				result: applyResult,
				busy: enabled.checked ? _('Applying configuration...') : _('Disabling...'),
				success: enabled.checked ? _('Applied') : _('Disabled'),
				failure: _('Apply failed'),
				startPath: helper,
				startArgs: args,
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 150000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					if (st && st.state !== 'timeout')
						return refreshSetupState();
				}
			});
		});

		installDeps.addEventListener('click', function() {
			if (!window.confirm(_('Install missing runtime packages now? DNS/DHCP may restart briefly while dnsmasq-full replaces dnsmasq.')))
				return;
			runDepsJob(installDeps, 'install-deps', depsResult,
				_('Dependencies installed. Rechecking...'), refreshSetupState);
		});

		removeDeps.addEventListener('click', function() {
			if (!window.confirm(_('Reset the app and prepare it for removal? All app functions stop; its settings, users, secrets, generated files and app-owned dependencies are removed. Pre-install DNS/DHCP is restored. Shared packages required by other software are kept.')))
				return;
			runDepsJob(removeDeps, 'remove-deps', depsResult,
				_('Application reset completed.'), refreshSetupState);
		});

		updateSetupState();

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('IKEv2 Manager Overview'),
					_('Install the app safely, prepare dependencies, then enable the managed routing configuration only when the checks are green.'),
					headerPill),
				E('section', { 'class': 'ikev2-section' }, [
					E('div', { 'class': 'ikev2-section-head' }, [
						E('div', {}, [
							E('h3', {}, [ _('Managed mode') ]),
							managedDescription
						])
					]),
					managedToggle,
					E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:1rem' }, [
						E('span', { 'class': 'ikev2-health-copy' }, [
							E('strong', {}, [ _('Domain routing engine') ]),
							domainDetail
						]),
						domainPill
					])
				]),
				common.section(_('Runtime dependencies'),
					_('Required VPN, routing and DNS components. Only warnings and failures are shown until technical details are opened.'),
					E('div', {}, [
						depsChecks,
						E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
							depsResult.node,
							installDeps,
							removeDeps
						])
					]),
					depsPill),
				common.section(_('Network integration'),
					_('Choose the WAN uplink and the networks this app protects. Firewall zones are detected automatically.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('WAN network'),
								_('The internet uplink. Receives UDP 500/4500 when the inbound server is enabled.')),
							wanField.node
						]),
						E('div', { 'style': 'margin-top:1.15rem' }, [
							common.fieldLabel(_('Protected networks'),
								_('Networks whose selected domains use the outbound tunnel.')),
							E('div', { 'style': 'margin-top:.6rem' }, [ protectedNode ])
						])
					])),
				common.section(_('Device rules'),
					_('Keep inclusions and exclusions in one list. Excluded devices can independently bypass project PBR, DNS interception and Zapret.'),
					self.renderDevicePolicies(data[3].stdout, data[4].stdout, data[5].stdout)),
				common.section(_('DNS policy'),
					null,
					E('div', {}, [
						E('div', { 'class': 'ikev2-two-col' }, [
							common.toggleRow(dnsEnforce, _('Redirect plain DNS'),
								_('Redirect TCP/UDP port 53 from protected zones to the router.')),
							common.toggleRow(blockDot, _('Block DNS-over-TLS'),
								_('Reject TCP/UDP port 853 from protected zones to WAN.'))
						]),
						E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:.85rem' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('IPv6 fail-fast') ]),
								E('span', { 'class': 'ikev2-toggle-sub' }, [
									_('Dual-stack clients drop to IPv4 instead of hanging when there is no IPv6 WAN.') ])
							]),
							common.pill(
								value.ipv6_failfast === 'active' ? _('active') :
									(value.ipv6_failfast === 'na' ? _('IPv6 WAN present') : _('off')),
								value.ipv6_failfast === 'active' ? 'good' : 'neutral')
						])
					])),
				E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
					applyResult.node,
					save
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
