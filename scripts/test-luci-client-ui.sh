#!/bin/sh

# A parse check proves only that the file is syntactically valid. A LuCI page
# dies at render time instead - a control referenced before it is declared, a
# helper that is not exported, a section built from a variable that was never
# assigned - and every command-line check still passes while the page shows
# nothing. This harness stubs the LuCI environment and actually renders the
# outbound tunnel view, which owns the DNS controls.

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

node - "$root" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2];

// LuCI installs a printf-style String.prototype.format; the modules rely on it.
if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function() {
			const args = Array.prototype.slice.call(arguments);
			let index = 0;
			return String(this).replace(/%[sdif]|%\.\d+f/g, function() {
				const value = args[index++];
				return value === undefined ? '' : String(value);
			});
		}
	});
}

function fail(message) {
	process.stderr.write('client UI contract failed: ' + message + '\n');
	process.exit(1);
}

function makeNode(tag, attrs) {
	return {
		tagName: String(tag || 'div').toUpperCase(),
		attrs: attrs || {},
		children: [],
		style: {},
		dataset: {},
		listeners: {},
		// A real <select> reports the selected option's value when none was set
		// explicitly. Without this the modules see an empty protocol and build
		// empty option lists, which is a stub artefact rather than a page defect.
		_value: (attrs && attrs.value != null) ? String(attrs.value) : '',
		get value() {
			if (this._value) return this._value;
			if (this.tagName !== 'SELECT') return '';
			const chosen = this.children.find(function(child) {
				return child.attrs && child.attrs.selected != null;
			}) || this.children[0];
			return chosen && chosen.attrs ? String(chosen.attrs.value || '') : '';
		},
		set value(next) { this._value = next == null ? '' : String(next); },
		checked: !!(attrs && attrs.checked !== undefined && attrs.checked !== null),
		disabled: !!(attrs && attrs.disabled),
		textContent: '',
		title: '',
		className: (attrs && attrs['class']) || '',
		// A <select> exposes its <option> children as .options; the modules read it.
		get options() { return this.children; },
		get firstChild() { return this.children[0] || null; },
		classList: { add() {}, remove() {}, contains() { return false; }, toggle() {} },
		addEventListener(name, handler) { this.listeners[name] = handler; },
		removeAttribute() {}, setAttribute() {}, focus() {}, remove() {},
		appendChild(child) { this.children.push(child); return child; },
		insertBefore(child) { this.children.unshift(child); return child; },
		replaceChildren() { this.children = Array.prototype.slice.call(arguments); },
		appendChildren() {},
		querySelector() { return null; },
		querySelectorAll() { return []; }
	};
}

function E(tag, attrs, children) {
	// E([a, b]) builds a fragment from the array; keep the children or the page
	// looks empty to the harness even though it rendered.
	if (Array.isArray(tag)) {
		const fragment = makeNode('div', {});
		tag.forEach(function(child) { if (child) fragment.children.push(child); });
		return fragment;
	}
	if (typeof tag === 'string' && tag.charAt(0) === '<')
		return makeNode('svg', {});
	if (Array.isArray(attrs)) { children = attrs; attrs = {}; }
	const node = makeNode(tag, attrs);
	(children || []).forEach(function(child) { if (child) node.children.push(child); });
	return node;
}

const documentStub = {
	createTextNode(text) { const n = makeNode('#text', {}); n.textContent = String(text); return n; },
	getElementById() { return null; },
	head: { appendChild() {} },
	createDocumentFragment() { return makeNode('fragment', {}); },
	documentElement: { lang: 'en' },
	querySelector() { return null; },
	querySelectorAll() { return []; }
};
const windowStub = {
	localStorage: null, setTimeout() {}, clearTimeout() {},
	location: { reload() {} }, _: null
};

const L = {
	resolveDefault: function(p, d) { return Promise.resolve(d); },
	Poll: { add() {}, remove() {} }
};
const baseclass = { extend: function(o) { return o; } };
const fsStub = {
	exec: function() { return Promise.resolve({ code: 0, stdout: '' }); },
	stat: function() { return Promise.resolve({}); },
	write: function() { return Promise.resolve(); }
};
const uiStub = {
	createHandlerFn: function(self, fn) { return fn; },
	showModal() {}, hideModal() {}, addNotification() {}
};
const pollStub = { add() {}, remove() {} };

function loadModule(file, extra) {
	const src = fs.readFileSync(path.join(root, 'luci-ikev2-manager', file), 'utf8');
	const names = [ 'window', 'document', 'L', 'baseclass', 'E', 'fs', 'ui', 'uci',
		'view', 'poll', 'common' ];
	const values = [ windowStub, documentStub, L, baseclass, E, fsStub, uiStub, {},
		{ extend: function(o) { return o; } }, pollStub, extra ];
	return new Function(names.join(','), src).apply(null, values);
}

const common = loadModule('shared.js', null);
[ 't', 'styles', 'card', 'pill', 'setPill', 'header', 'section', 'fieldLabel',
	'inlineResult', 'runAction', 'execChecked', 'inputToken', 'toggleRow',
	'switchLabel', 'gate', 'parseKeyValues', 'parseSwanmon' ].forEach(function(name) {
	if (typeof common[name] !== 'function')
		fail('shared.js does not export ' + name + ', which client.js uses');
});

const view = loadModule('client.js', common);
if (typeof view.render !== 'function')
	fail('client.js does not return a view with render()');

// Reliable mode, managed DNS, tunnel resolution on, one destination segment.
const clientGet = [
	'enabled=1', 'remote_address=vpn.example.net', 'remote_id=vpn.example.net',
	'username=proxy', 'dpd=30', 'mtu=1400', 'custom_config=0',
	'reconnect_cooldown=15', 'tunnel_dns_provider=custom',
	'tunnel_dns_upstream=https://dns.cloudflare.com/dns-query https://dns.google/dns-query',
	'tunnel_dns_bootstrap=8.8.8.8:53 1.1.1.1:53',
	'tunnel_dns_active=https://dns.cloudflare.com/dns-query',
	'tunnel_dns_failures=0', 'interface_present=1',
	'interface_bytes_in=1', 'interface_bytes_out=1'
].join('\n');
const dnsGet = [
	'managed=1', 'protocol=doh', 'provider=custom', 'upstream_mode=fastest_addr',
	'upstream=https://freedns.controld.com/p0', 'bootstrap=9.9.9.10:53',
	'fallback=https://dns.google/dns-query', 'wan_fallback=1',
	'timeout=2s', 'timeout_effective=2s', 'fallback_verified=1788000000',
	'tunnel_resolve=1', 'segment_health=up', 'running=1'
].join('\n');
const segments = [
	'id=ru\tname=RU\tenabled=1\tdomains=ru su\tprotocol=doh\tmode=load_balance',
	'upstream=https://common.dot.dns.yandex.net/dns-query\tbootstrap=77.88.8.8:53',
	'fallback=\tfallback_effective=https://dns.google/dns-query\tinherits_fallback=1',
	'https_compat=1\tport=5550'
].join('\t');

const data = [
	{ code: 0, stdout: clientGet }, { stdout: '' }, { code: 0, stdout: '0' },
	{ code: 0, stdout: '' }, { stdout: dnsGet }, { stdout: segments }
];
data.ready = true;

let page;
try {
	page = view.render(data);
} catch (error) {
	fail('render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!page || !page.children || !page.children.length)
	fail('render() produced an empty page');

const source = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'client.js'), 'utf8');

// The tunnel DNS block applies on its own, and destination segments are their
// own section rather than a disclosure inside the router resolver.
if (source.indexOf("common.section(_('Destination DNS segments')") < 0)
	fail('destination segments are not their own section');
if (/E\('details'[^\n]*\n\s*E\('summary', \{\}, \[ _\('Destination DNS segments'\)/.test(source))
	fail('destination segments are still hidden behind a disclosure');
if (source.indexOf('tunnelDnsApply.addEventListener') < 0)
	fail('tunnel DNS has no apply of its own');
if (source.indexOf('routerDnsBypassNote') < 0)
	fail('router DNS section does not report being bypassed');

// Every literal bootstrap preset must satisfy the rule the runtime enforces:
// a bare IPv4 authority, or an encrypted endpoint whose host is one. A preset
// that fails it would be offered by the page and refused on save.
const providerStart = source.indexOf('var dnsProviders = [');
const providerBlock = source.slice(providerStart,
	source.indexOf('\n];', providerStart));
const literalPresets = (providerBlock.match(/bootstrap_(?:doh|dot): '([^']*)'/g) || [])
	.map(function(line) { return line.replace(/^[^']*'|'$/g, ''); })
	.join(' ').split(/\s+/).filter(Boolean);
if (literalPresets.length < 8)
	fail('the bootstrap group offers almost no literal-address presets');
literalPresets.forEach(function(endpoint) {
	const authority = endpoint.slice(endpoint.indexOf('://') + 3).split('/')[0];
	const host = authority.split(':')[0];
	if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(host))
		fail('bootstrap preset ' + endpoint + ' does not use a literal IPv4 host');
	if (!/^(https|tls|quic):\/\//.test(endpoint))
		fail('bootstrap preset ' + endpoint + ' uses a scheme the runtime refuses');
});

// Protocol labels reach _() through a variable, so the translation coverage
// check cannot see them. Every offered label must still be in the dictionary.
const sharedDict = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'shared.js'), 'utf8');
const protocolBlockStart = source.indexOf('var dnsProtocols = [');
const protocolLabels = source.slice(protocolBlockStart,
	source.indexOf('\n];', protocolBlockStart))
	.match(/label: '([^']*)'/g).map(function(line) {
		return line.replace(/^label: '|'$/g, '');
	}).concat([ 'Plain DNS (IPv4:port)' ]);
protocolLabels.forEach(function(label) {
	if (sharedDict.indexOf("\t'" + label + "':") < 0)
		fail('protocol label "' + label + '" has no translation');
});

// The protocol is chosen per endpoint, not once for a whole group. A group
// select would contradict the row selects the moment the two disagreed, and
// dnsproxy parses each upstream by its own scheme anyway.
if (/\bdnsProtocol\b/.test(source))
	fail('the router resolver still picks one protocol for the whole group');
if (/common\.fieldLabel\(_\('Protocol'\)\)/.test(source))
	fail('a segment still picks one protocol for its whole group');
if ((source.match(/\{ choosable: true \}/g) || []).length < 4)
	fail('not every editable group offers a per-row protocol select');
if (source.indexOf('function segmentProtocol()') < 0)
	fail('the stored segment protocol is no longer derived from its endpoints');
// doh3 renders the same https:// string as doh, so a per-row picker offering
// both cannot round-trip through the stored endpoint.
if (/id: 'doh3'/.test(source))
	fail('the protocol list still offers a choice it cannot store');

// Every endpoint row must carry its own provider select, and picking a
// provider must fill the editable field rather than replace it.
function firstWithClass(node, name, out) {
	if (!node || typeof node !== 'object') return out;
	if (node.attrs && typeof node.attrs['class'] === 'string' &&
		node.attrs['class'].split(/\s+/).indexOf(name) >= 0) out.push(node);
	(node.children || []).forEach(function(child) { firstWithClass(child, name, out); });
	return out;
}
// The controls are direct children of the row: a wrapper around the selects
// sized every row by its own longest option label, so columns stopped lining
// up between rows of one list.
const endpointRows = firstWithClass(page, 'ikev2-dns-endpoint', []);
if (!endpointRows.length)
	fail('no endpoint row offers a protocol/provider picker');
const rowShapes = {};
endpointRows.forEach(function(row) {
	const selects = row.children.filter(function(child) {
		return child && child.tagName === 'SELECT';
	});
	if (!selects.length)
		fail('an endpoint row rendered without a select');
	if (!selects[selects.length - 1].children.length)
		fail('the provider select rendered with no options');
	if (!row.children.some(function(child) {
		return child && child.tagName === 'INPUT';
	}))
		fail('an endpoint row rendered without its editable field');
	rowShapes[String(selects.length)] = true;
});
// Both shapes must exist: a group that fixes its protocol and one that lets
// every row choose. A single shape means one of them stopped rendering.
if (!rowShapes['1'] || !rowShapes['2'])
	fail('endpoint rows all render the same shape');
// The fallback line under a segment must not repeat a list the fields above it
// already show; it exists to spell out what an empty field inherits.
if (source.indexOf('var fallbackEffective = !inherits') < 0)
	fail('the segment fallback still restates an explicitly configured list');

// Segments are edited as one block per segment, not through a picker that
// opens on an empty creation form. A configured segment must be on screen
// without a click, and the add button must append another block.
function walk(node, out) {
	if (!node || typeof node !== 'object') return out;
	if (node.attrs && typeof node.attrs['class'] === 'string') out.push(node);
	(node.children || []).forEach(function(child) { walk(child, out); });
	return out;
}
function countClass(name) {
	return walk(page, []).filter(function(node) {
		return node.attrs['class'].split(/\s+/).indexOf(name) >= 0;
	}).length;
}
if (source.indexOf('segmentSelect') >= 0)
	fail('DNS segments are still edited through a segment picker');
if (countClass('ikev2-segment-block') !== 1)
	fail('expected one rendered block for the one configured segment, got ' +
		countClass('ikev2-segment-block'));
const addButton = walk(page, []).find(function(node) {
	return node.attrs['class'].indexOf('ikev2-wide-button') >= 0;
});
if (!addButton) fail('there is no full-width button to add a DNS segment');
addButton.listeners.click();
if (countClass('ikev2-segment-block') !== 2)
	fail('the add button did not append another segment block');

// A busy button must show that the action was accepted, not just go grey.
const probe = makeNode('button', {});
probe.textContent = 'Apply';
common.setBusy(probe, true, 'Applying...');
if (!probe.disabled)
	fail('setBusy did not disable the button');
if (!probe.children.some(function(child) {
	return child.attrs && child.attrs['class'] === 'ikev2-spin';
}))
	fail('setBusy did not render a spinner');
common.setBusy(probe, false);
if (probe.disabled)
	fail('setBusy did not restore the button');

// The overview page owns the pause control, so it is rendered here too: a
// control referenced before its declaration parses cleanly and only fails in
// the browser.
const setupValue = [
	'configured=1', 'routing_paused=1', 'wan_interface=wan', 'wan_zone=wan',
	'source_interfaces=lan', 'source_zones=lan', 'dns_enforce=1', 'block_dot=1',
	'source_include_vpn=1', 'engine=fakeip', 'service=running', 'healthy=yes',
	'state=active'
].join('\n');
const doctorOut = [ 'diagnostic_status=ok', 'dependencies_ok=yes', 'readiness=ok' ].join('\n');
const setupView = loadModule('setup.js', common);
if (typeof setupView.render !== 'function')
	fail('setup.js does not return a view with render()');
let setupPage;
try {
	setupPage = setupView.render([
		{ stdout: setupValue }, { stdout: doctorOut }, { stdout: '' },
		{ stdout: '' }, { stdout: '' }, { stdout: '' }
	]);
} catch (error) {
	fail('setup.js render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!setupPage || !setupPage.children || !setupPage.children.length)
	fail('setup.js render() produced an empty page');

const setupSource = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'setup.js'), 'utf8');
if (setupSource.indexOf("common.section(_('Tunnel routing')") < 0)
	fail('overview has no tunnel routing section');
if (setupSource.indexOf("'routing-resume-async'") < 0)
	fail('overview cannot resume routing');

// The policy editor lives in its own application and had no render coverage at
// all, which is where the raw status dump survived unnoticed.
function loadEditor() {
	const src = fs.readFileSync(path.join(root, 'luci-ikev2-domains', 'editor.js'), 'utf8');
	const names = [ 'window', 'document', 'L', 'baseclass', 'E', 'fs', 'ui', 'uci',
		'view', 'poll', 'common' ];
	const values = [ windowStub, documentStub, L, baseclass, E, fsStub, uiStub, {},
		{ extend: function(o) { return o; } }, pollStub, common ];
	return new Function(names.join(','), src).apply(null, values);
}
const editor = loadEditor();
if (typeof editor.render !== 'function')
	fail('editor.js does not return a view with render()');
const policyStatus = [
	'state=ok', 'updated=2026-08-30 11:58:52 +0300', 'services=16',
	'domains=121', 'cidrs=14', 'custom_cidrs=0', 'selected=openai,telegram'
].join('\n');
let editorPage;
try {
	editorPage = editor.render([
		'example.com\n', 'openai telegram', policyStatus,
		{ code: 0, stdout: '' }, 'example.com\n',
		{ code: 0, stdout: 'engine=fakeip\nservice=running\nnft=active\nrule=active' },
		'203.0.113.10\n'
	]);
} catch (error) {
	fail('editor.js render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!editorPage || !editorPage.children || !editorPage.children.length)
	fail('editor.js render() produced an empty page');

const editorSource = fs.readFileSync(path.join(root, 'luci-ikev2-domains', 'editor.js'), 'utf8');
// The policy state is reported by the header pill and the save result. The page
// must not grow a status readout of its own again: the last one was a raw
// key=value dump that duplicated the chips beside it.
if (editorSource.indexOf('ikev2-status-line') >= 0)
	fail('the policy page has a status readout again');
if (/lines\.push\('selected=' \+ st\.selected\)/.test(editorSource))
	fail('the policy page still dumps raw status keys');
if (editorSource.indexOf("common.setPill(policyPill") < 0)
	fail('the policy page no longer reports its state at all');

// The inbound server page carries the most controls of any view, so its render
// is exercised too - a restructured section there fails the same silent way.
const settingsView = loadModule('settings.js', common);
if (typeof settingsView.render !== 'function')
	fail('settings.js does not return a view with render()');
const serverGet = [
	'enabled=1', 'identity=vpn.example.com', 'pool4=10.253.10.0/24',
	'gateway4=10.253.10.1', 'dns4=10.253.10.1', 'mtu=1400', 'mobike=1',
	'fragmentation=1', 'dpd=30', 'ike_rekey=4h', 'child_rekey=1h'
].join('\n');
const serverAccess = [
	'local_ts=0.0.0.0/0', 'allow_internet=1', 'allow_lan=1', 'allow_router=1',
	'router_ports=', 'lan_zones=lan', 'firewall_zone=ikev2', 'outbound_zone=wan'
].join('\n');
const settingsData = [
	{ stdout: serverGet }, { stdout: serverAccess }, { stdout: '0' },
	{ stdout: '' }, { stdout: 'identities=vpn.example.com' },
	{ stdout: 'lan=LAN\nwan=WAN' }, { stdout: 'lan=LAN\nwan=WAN' },
	{ stdout: 'wan_interface=wan' }
];
settingsData.ready = true;
let settingsPage;
try {
	settingsPage = settingsView.render(settingsData);
} catch (error) {
	fail('settings.js render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!settingsPage || !settingsPage.children || !settingsPage.children.length)
	fail('settings.js render() produced an empty page');

// Advanced options are reached from a control in the header of the section
// they qualify, not from a disclosure block appended under its controls.
const settingsSource = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'settings.js'), 'utf8');
[ [ 'client.js', source ], [ 'settings.js', settingsSource ] ].forEach(function(entry) {
	if (entry[1].indexOf("'class': 'ikev2-advanced' }") >= 0)
		fail(entry[0] + ' still appends an advanced disclosure block');
	if (entry[1].indexOf('common.advancedPanel(') < 0)
		fail(entry[0] + ' has no advanced panel opened from a section header');
});
// Staging issues certificates clients reject, so it is an advanced option and
// is rendered with the same toggle row as every other switch on the page - not
// as a lone two-column grid whose switch drifted out of alignment.
if (/common\.fieldLabel\(_\('Staging'\)/.test(settingsSource))
	fail('the ACME staging switch is back in a grid row of its own');
if (settingsSource.indexOf("common.toggleRow(acmeStaging") < 0)
	fail('the ACME staging switch is not a toggle row');
if (settingsSource.indexOf('acmeAdvanced.toggle') < 0)
	fail('the ACME panel has no advanced toggle');
// The inbound page opened on three collapsed panels with nothing but the
// server identity visible. Its sections are now flat, each with its own
// advanced toggle for the parts that stay hidden.
if (settingsSource.indexOf("E('details', { 'class': 'ikev2-disclosure' }") >= 0)
	fail('the inbound page still nests its settings in disclosures');
if (settingsSource.indexOf('ikev2-disclosure-stack') >= 0)
	fail('the inbound page still stacks disclosures');
[ 'accessPanel', 'acmePanel', 'behaviorPanel' ].forEach(function(name) {
	if (!new RegExp('var ' + name + ' = common\\.section\\(').test(settingsSource))
		fail(name + ' is not a flat section');
});

// The custom destination editors are sized by a class that has to outrank the
// page-wide textarea floor, or they silently stay at that floor.
const sharedSource = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'shared.js'), 'utf8');
if (sharedSource.indexOf('.ikev2-page .ikev2-domain-editor {') < 0)
	fail('the domain editor height is set by a selector the textarea floor outranks');
if (sharedSource.indexOf('.ikev2-page .ikev2-domain-editor {') >
	sharedSource.indexOf('.ikev2-page .ikev2-domain-editor-small {'))
	fail('the small editor override is declared before the rule it narrows');

if (typeof common.advancedPanel !== 'function')
	fail('shared.js does not export advancedPanel');
const advanced = common.advancedPanel(makeNode('div', {}), 'Advanced');
if (advanced.panel.style.display !== 'none')
	fail('the advanced panel starts open');
advanced.toggle.listeners.click({});
if (advanced.panel.style.display === 'none')
	fail('the advanced toggle did not open the panel');
advanced.toggle.listeners.click({});
if (advanced.panel.style.display !== 'none')
	fail('the advanced toggle did not close the panel again');

process.stdout.write('client UI render tests OK\n');
JS
