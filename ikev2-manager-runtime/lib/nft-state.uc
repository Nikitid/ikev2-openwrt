// A table as installed, without what traffic changes in it:
//
//   nft -j list table inet NAME | ucode nft-state.uc fingerprint [SET...]
//
// prints one canonical line that changes only when the table's program does.
// The runtimes used to verify an installed table by searching nft's text
// listing for the rules they meant to write, and nft prints some of those back
// in another form (a mask with a bit added, "!= 0" as "!= 0x00000000"); every
// such case read as a missing rule. Taking the fingerprint right after the
// table is installed and comparing later ones with it needs no knowledge of
// how nft prints anything.
//
// Left out: listing metadata, object handles, counter values, element expiry,
// and the elements of dynamic sets and of each named SET, which traffic or a
// resolver adds.
//
// Exit status: 0 printed, 2 the listing could not be read.

'use strict';

import { stdin } from 'fs';

function strip(value) {
	if (type(value) == 'array')
		return map(value, strip);
	if (type(value) != 'object')
		return value;
	let out = {};
	for (let k, v in value) {
		if (k == 'handle' || k == 'expires')
			continue;
		if (k == 'counter' && type(v) == 'object')
			out[k] = null;
		else
			out[k] = strip(v);
	}
	return out;
}

function canonical(value) {
	if (type(value) == 'array')
		return '[' + join(',', map(value, canonical)) + ']';
	if (type(value) == 'object')
		return '{' + join(',', map(sort(keys(value)), (k) => sprintf('%J:%s', k, canonical(value[k])))) + '}';
	return sprintf('%J', value);
}

if (ARGV[0] != 'fingerprint') {
	warn('usage: nft-state.uc fingerprint <LISTING\n');
	exit(2);
}

let volatile = slice(ARGV, 1);
let listing = null;
try {
	listing = json(stdin.read('all') || '');
}
catch (e) {
	exit(2);
}
if (type(listing) != 'object' || type(listing.nftables) != 'array')
	exit(2);

let objects = [];
for (let entry in listing.nftables) {
	if (type(entry) != 'object' || exists(entry, 'metainfo'))
		continue;
	let set = entry.set;
	if (type(set) == 'object' &&
	    ((type(set.flags) == 'array' && index(set.flags, 'dynamic') >= 0) || index(volatile, set.name) >= 0)) {
		entry = { set: { ...set } };
		delete entry.set.elem;
	}
	push(objects, strip(entry));
}
if (length(objects) == 0)
	exit(2);
print(canonical(objects), '\n');
exit(0);
