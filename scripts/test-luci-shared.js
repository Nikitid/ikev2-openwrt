'use strict';

// shared.js was stubbed out by every other JS test, so nothing ever evaluated
// it. That hid a page-breaking regression: styles() returned an empty string,
// and LuCI's E() falls through to document.createElement() for anything that is
// neither a node nor markup, so every view raised InvalidCharacterError.
//
// The E() dispatch below mirrors luci.js so this test fails the same way the
// browser did.

const assert = require('assert');
const fsNode = require('fs');

let createdTags = [];

class Node {
	constructor(nodeType, tag) {
		this.nodeType = nodeType;
		this.tagName = tag;
		this.childNodes = [];
		this.attributes = {};
		this.id = '';
		this.dataset = {};
		this.disabled = false;
	}
	appendChild(child) {
		if (child == null || typeof child !== 'object' || !('nodeType' in child))
			throw new TypeError('appendChild expects a node');
		// A document fragment contributes its children and then itself is empty.
		if (child.nodeType === 11) {
			child.childNodes.forEach(item => this.childNodes.push(item));
			child.childNodes = [];
			return child;
		}
		this.childNodes.push(child);
		return child;
	}
	setAttribute(name, value) {
		this.attributes[name] = value;
		if (name === 'id')
			this.id = value;
	}
	removeAttribute(name) {
		delete this.attributes[name];
	}
	get textContent() {
		return this.childNodes.map(item =>
			typeof item === 'string' ? item : item.textContent).join('');
	}
	set textContent(value) {
		this.childNodes = [ String(value) ];
	}
	get innerHTML() {
		return this.childNodes.map(item =>
			typeof item === 'string' ? item : item.textContent).join('');
	}
	set innerHTML(value) {
		this.childNodes = [ String(value) ];
	}
}

const document = {
	head: new Node(1, 'head'),
	byId: {},
	createElement(tag) {
		createdTags.push(tag);
		// The real DOM raises this for an empty or otherwise invalid tag name.
		if (typeof tag !== 'string' || !/^[A-Za-z][A-Za-z0-9-]*$/.test(tag))
			throw new Error('InvalidCharacterError: The string contains invalid characters.');
		return new Node(1, tag);
	},
	createDocumentFragment() {
		return new Node(11, null);
	},
	createTextNode(value) {
		const node = new Node(3, null);
		node.value = String(value);
		Object.defineProperty(node, 'textContent', { get: () => node.value });
		return node;
	},
	getElementById(id) {
		return document.byId[id] || null;
	},
	querySelectorAll() {
		return [];
	}
};

function isNode(value) {
	return value != null && typeof value === 'object' && 'nodeType' in value;
}

// Mirrors the dispatch in luci.js: array -> fragment, node -> as is,
// string starting with '<' -> parsed markup, anything else -> createElement.
function E(html, attr, data) {
	let elem;
	if (!(attr instanceof Object) || Array.isArray(attr)) {
		data = attr;
		attr = null;
	}
	if (Array.isArray(html)) {
		elem = document.createDocumentFragment();
		html.forEach(item => elem.appendChild(E(item)));
	}
	else if (isNode(html)) {
		elem = html;
	}
	else if (typeof html === 'string' && html.charCodeAt(0) === 60) {
		elem = new Node(1, 'parsed');
	}
	else {
		elem = document.createElement(html);
	}
	if (attr)
		Object.keys(attr).forEach(name => {
			if (attr[name] != null)
				elem.setAttribute(name, attr[name]);
		});
	if (data != null) {
		const items = Array.isArray(data) ? data : [ data ];
		items.forEach(item => {
			if (item == null || item === '')
				return;
			elem.appendChild(isNode(item) ? item : document.createTextNode(item));
		});
	}
	if (elem.id)
		document.byId[elem.id] = elem;
	return elem;
}

// LuCI installs this on String.prototype; shared.js relies on it.
if (!String.prototype.format)
	String.prototype.format = function() {
		const args = Array.prototype.slice.call(arguments);
		return this.replace(/%[sd]/g, () => String(args.shift()));
	};

const nativeTranslate = value => 'native:' + value;
const windowStub = {
	_: nativeTranslate,
	navigator: { language: 'en-US' },
	localStorage: { getItem: () => null, setItem: () => {} },
	setTimeout: () => {}
};

const baseclass = { extend: object => object };
const fs = {};

const source = fsNode.readFileSync('luci-ikev2-manager/shared.js', 'utf8');
const factory = new Function(
	'window', 'document', 'L', 'baseclass', 'fs', 'E', source);
const common = factory(windowStub, document, {}, baseclass, fs, E);

// The regression: whatever styles() returns is placed among E() children.
createdTags = [];
const first = common.styles();
assert(isNode(first), 'styles() must return something LuCI.dom.elem() accepts');
assert(!createdTags.includes(''),
	'styles() caused document.createElement("")');

// Passing it through E() the way every view does must not throw.
assert.doesNotThrow(() => E([ first, E('div', {}, [ 'x' ]) ]),
	'the styles() result is not accepted as an E() child');

// The stylesheet is installed once per document, not rebuilt on every render.
const injected = document.head.childNodes.filter(node => node.tagName === 'style');
assert.strictEqual(injected.length, 1, 'the stylesheet was not installed');
common.styles();
common.styles();
assert.strictEqual(
	document.head.childNodes.filter(node => node.tagName === 'style').length, 1,
	'the stylesheet was installed more than once');

// The project translator must stay local: replacing window._ applies the
// project map to every other application on shared pages such as Status
// Overview.
assert.strictEqual(windowStub._, nativeTranslate,
	'shared.js replaced the global translation function');
assert.strictEqual(typeof common.t, 'function', 'common.t is not exported');
assert.strictEqual(common.t('Overview'), 'native:Overview',
	'the translator does not fall back to the LuCI catalogue');

// Spot-check a couple of exported helpers actually run.
assert.strictEqual(common.formatBytes(0), '0 B');
assert.strictEqual(typeof common.pill('x', 'good'), 'object');

// Busy state may wrap buttons, checkboxes and selects. Non-button controls
// must retain their contents and current value while disabled.
const select = E('select', {}, [ E('option', {}, [ 'Warnings' ]), E('option', {}, [ 'Debug' ]) ]);
select.value = 'debug';
const selectMarkup = select.innerHTML;
common.setBusy(select, true, 'Applying...');
assert.strictEqual(select.innerHTML, selectMarkup, 'setBusy erased select options');
assert.strictEqual(select.value, 'debug', 'setBusy changed select value');
assert.strictEqual(select.disabled, true, 'setBusy did not disable select');
common.setBusy(select, false);
assert.strictEqual(select.innerHTML, selectMarkup, 'setBusy did not preserve select options');
assert.strictEqual(select.value, 'debug', 'setBusy did not preserve select value');
assert.strictEqual(select.disabled, false, 'setBusy did not restore select state');

// rpcd hands a session its grants when the session is created, so a page left
// open across an upgrade that adds a helper call keeps the older set and the
// call is refused. Surfacing rpcd's bare wording reads as a bug in the app;
// the message has to name the cause and what clears it.
(async () => {
	const captured = [];
	const sink = {
		busy() {}, ok() {},
		err(text) { captured.push(text); }
	};
	await common.runAction({
		result: sink,
		run() { throw new Error('Permission denied'); }
	});
	assert.strictEqual(captured.length, 1, 'runAction did not report the failure');
	assert.ok(/session/i.test(captured[0]),
		'a permission denial is still reported as rpcd words it: ' + captured[0]);
	assert.ok(/sign out/i.test(captured[0]),
		'the permission message does not say what clears it: ' + captured[0]);

	captured.length = 0;
	await common.runAction({
		result: sink,
		run() { throw new Error('Invalid DNS upstream'); }
	});
	assert.strictEqual(captured[0], 'Invalid DNS upstream',
		'an ordinary failure was rewritten as a permission problem');

	// The result line is where a failure explains itself. Clipping it to one
	// line turns the messages that say what to do into a fragment.
	const styles = fsNode.readFileSync('luci-ikev2-manager/shared.js', 'utf8');
	const resultRule = styles.slice(styles.indexOf('.ikev2-result {'),
		styles.indexOf('.ikev2-result.busy'));
	assert.ok(!/white-space:\s*nowrap/.test(resultRule),
		'the result line is clipped to one line again');
	assert.ok(!/text-overflow:\s*ellipsis/.test(resultRule),
		'the result line still truncates with an ellipsis');

	console.log('luci shared module tests OK');
})();
