#!/bin/sh

# Every string the pages pass through the translator must have a Russian
# entry, and no entry may be defined twice. A missing one shows an English
# label in the middle of a Russian page - which is how "Device policy runtime"
# and "FakeIP allocator" reached a screenshot - and a duplicate means one of the
# two translations is dead and nobody can tell which.

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

node - "$root" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const shared = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'shared.js'), 'utf8');

// Scan the dictionary only. The rest of the module is full of object literals
// whose keys ("class", "style") are not translations.
const start = shared.indexOf('var ru = {');
const end = shared.indexOf('\n};', start);
if (start < 0 || end < 0) {
	process.stderr.write('translation dictionary not found in shared.js\n');
	process.exit(1);
}
const dictionary = shared.slice(start, end);

// Keys may sit anywhere on a line, not only at its start.
const entry = /(^|[\s,{])'((?:[^'\\]|\\.)*)'\s*:\s*'/gm;
const keys = new Set();
const duplicates = [];
let match;
while ((match = entry.exec(dictionary)) !== null) {
	const key = match[2];
	if (keys.has(key))
		duplicates.push(key);
	keys.add(key);
}
if (duplicates.length) {
	process.stderr.write('duplicate translation keys: ' + duplicates.join(', ') + '\n');
	process.exit(1);
}

const pages = [
	[ 'luci-ikev2-manager', 'client.js' ], [ 'luci-ikev2-manager', 'setup.js' ],
	[ 'luci-ikev2-manager', 'settings.js' ], [ 'luci-ikev2-manager', 'users.js' ],
	[ 'luci-ikev2-manager', 'status-widget.js' ], [ 'luci-ikev2-domains', 'editor.js' ]
];
let missing = [];
let total = 0;
pages.forEach(function(page) {
	const file = path.join(root, page[0], page[1]);
	if (!fs.existsSync(file))
		return;
	const src = fs.readFileSync(file, 'utf8');
	const seen = new Set();
	let hit;
	const call = /_\('((?:[^'\\]|\\.)*)'\)/g;
	while ((hit = call.exec(src)) !== null)
		seen.add(hit[1]);
	total += seen.size;
	seen.forEach(function(text) {
		if (!keys.has(text))
			missing.push(page[1] + ': ' + text);
	});
});
if (missing.length) {
	process.stderr.write('untranslated strings:\n  ' + missing.join('\n  ') + '\n');
	process.exit(1);
}
process.stdout.write('translation coverage OK: ' + total + ' strings\n');
JS
