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
	get textContent() {
		return this.childNodes.map(item =>
			typeof item === 'string' ? item : item.textContent).join('');
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

console.log('luci shared module tests OK');
