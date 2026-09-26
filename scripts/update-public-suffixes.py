#!/usr/bin/env python3
"""Regenerate luci-ikev2-domains/public-suffixes.txt from the Public Suffix List.

Usage: scripts/update-public-suffixes.py PUBLIC_SUFFIX_LIST.dat

Keeps the ICANN section's multi-label rules only: a single label ("com") is
already refused, and the private section names hosting domains such as
github.io that service lists legitimately select. Wildcard ("*.ck") and
exception ("!www.ck") rules are kept as written; names are lower-case ASCII,
internationalised ones in punycode, as the domain lists hold them.

The list is published by the Mozilla Foundation under the MPL-2.0
(https://publicsuffix.org/).
"""

import sys


def ascii_rule(rule):
    prefix = ''
    if rule[0] in '*!':
        prefix, rule = rule[0], rule[1:]
        if prefix == '*':
            prefix, rule = '*.', rule[1:]
    labels = []
    for label in rule.split('.'):
        labels.append(label if label.isascii() else label.encode('idna').decode('ascii'))
    return prefix + '.'.join(labels).lower()


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    icann = False
    rules = set()
    for line in open(sys.argv[1], encoding='utf-8'):
        line = line.strip()
        if '===BEGIN ICANN DOMAINS===' in line:
            icann = True
        elif '===END ICANN DOMAINS===' in line:
            icann = False
        if not icann or not line or line.startswith('//'):
            continue
        rule = ascii_rule(line.split()[0])
        if '.' in rule.lstrip('*.!'):
            rules.add(rule)
        elif rule.startswith('*.'):
            rules.add(rule)
    out = 'luci-ikev2-domains/public-suffixes.txt'
    with open(out, 'w') as f:
        f.write('# Multi-label public suffixes (ICANN section of the Public Suffix List,\n')
        f.write('# https://publicsuffix.org/, MPL-2.0). Regenerate with\n')
        f.write('# scripts/update-public-suffixes.py.\n')
        for rule in sorted(rules):
            f.write(rule + '\n')
    print('%s: %d rules' % (out, len(rules)))


if __name__ == '__main__':
    main()
