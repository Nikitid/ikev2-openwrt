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

process.stdout.write('client UI render tests OK\n');
JS
