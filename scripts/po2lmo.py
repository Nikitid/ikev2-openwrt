#!/usr/bin/env python3
"""Compile a gettext .po catalog into a LuCI .lmo catalog.

A port of LuCI's modules/luci-base/src/po2lmo.c, so both build paths can
produce the catalog without building luci-base's host tools: the SDK package
build has no LuCI feed, and the IPK is staged without an SDK at all. It must
stay byte-identical to the C tool; scripts/test-luci-translations.sh checks
known hashes, and compares against the C tool when one is available.

Usage: po2lmo.py input.po output.lmo
"""

import struct
import sys

MASK = 0xFFFFFFFF


def _s8(byte):
    return byte - 256 if byte > 127 else byte


def _get16(data, pos):
    return data[pos] | (data[pos + 1] << 8)


def sfh_hash(data, init):
    """Paul Hsieh's SuperFastHash as implemented in LuCI's lmo.c."""
    length = len(data)
    if length <= 0:
        return 0
    value = init & MASK
    rem = length & 3
    pos = 0
    for _ in range(length >> 2):
        value = (value + _get16(data, pos)) & MASK
        tmp = ((_get16(data, pos + 2) << 11) ^ value) & MASK
        value = ((value << 16) ^ tmp) & MASK
        pos += 4
        value = (value + (value >> 11)) & MASK
    if rem == 3:
        value = (value + _get16(data, pos)) & MASK
        value ^= (value << 16) & MASK
        value ^= (_s8(data[pos + 2]) << 18) & MASK
        value = (value + (value >> 11)) & MASK
    elif rem == 2:
        value = (value + _get16(data, pos)) & MASK
        value ^= (value << 11) & MASK
        value = (value + (value >> 17)) & MASK
    elif rem == 1:
        value = (value + _s8(data[pos])) & MASK
        value ^= (value << 10) & MASK
        value = (value + (value >> 1)) & MASK
    value ^= (value << 3) & MASK
    value = (value + (value >> 5)) & MASK
    value ^= (value << 4) & MASK
    value = (value + (value >> 17)) & MASK
    value ^= (value << 25) & MASK
    value = (value + (value >> 6)) & MASK
    return value


def extract_string(line):
    """Return the quoted part of a .po line as po2lmo sees it, or None.

    Only \\" and \\\\ are unescaped; any other escape stays as written, exactly
    as the C tool keeps it.
    """
    if line.startswith(b'#'):
        return None
    start = line.find(b'"')
    if start < 0:
        return None
    out = bytearray()
    pos = start + 1
    while pos < len(line):
        char = line[pos]
        if char == 0x5C and pos + 1 < len(line):
            following = line[pos + 1]
            if following not in (0x22, 0x5C):
                out.append(char)
            out.append(following)
            pos += 2
            continue
        if char == 0x22:
            break
        out.append(char)
        pos += 1
    return bytes(out)


def pad(data):
    return data + b'\0' * ((4 - len(data) % 4) % 4)


def compile_po(source):
    entries = []
    blob = bytearray()
    msg = {'ctxt': None, 'id': None, 'plural': None, 'val': {}, 'num': -1}
    current = [None]

    def flush():
        vals = msg['val']
        if msg['id'] and vals.get(0):
            for index in range(msg['num'] + 1):
                value = vals.get(index)
                if not value:
                    continue
                if msg['ctxt'] and msg['plural']:
                    key = msg['ctxt'] + b'\1' + msg['id'] + b'\2' + str(index).encode()
                elif msg['ctxt']:
                    key = msg['ctxt'] + b'\1' + msg['id']
                elif msg['plural']:
                    key = msg['id'] + b'\2' + str(index).encode()
                else:
                    key = msg['id']
                key_id = sfh_hash(key, len(key))
                if key_id == sfh_hash(value, len(value)):
                    continue
                entries.append((key_id, msg['num'] + 1, len(blob), len(value)))
                blob.extend(pad(value))
        elif vals.get(0):
            for field in vals[0].split(b'\\n'):
                if field.lower().startswith(b'plural-forms: '):
                    field = field[14:]
                    entries.append((0, 0, len(blob), len(field)))
                    blob.extend(pad(field))
                    break
        msg.update(ctxt=None, id=None, plural=None, val={}, num=-1)

    lines = source.splitlines(keepends=True) + [None]
    for line in lines:
        eof = line is None
        line = line or b''
        if line.startswith(b'msgctxt "'):
            if msg['id'] or msg['val'].get(0):
                flush()
            msg['ctxt'] = None
            current[0] = ('ctxt', None)
        elif eof or line.startswith(b'msgid "'):
            if msg['id'] or msg['val'].get(0):
                flush()
            msg['id'] = None
            current[0] = ('id', None)
        elif line.startswith(b'msgid_plural "'):
            msg['plural'] = None
            current[0] = ('plural', None)
        elif line.startswith(b'msgstr "') or line.startswith(b'msgstr['):
            if line[6:7] == b'[':
                msg['num'] = int(line[7:].split(b']')[0])
            else:
                msg['num'] = 0
            if msg['num'] >= 10:
                raise SystemExit('Error: Too many plural forms')
            msg['val'][msg['num']] = None
            current[0] = ('val', msg['num'])
        if eof:
            break
        if current[0]:
            text = extract_string(line)
            if text:
                field, index = current[0]
                if field == 'val':
                    msg['val'][index] = (msg['val'].get(index) or b'') + text
                else:
                    msg[field] = (msg[field] or b'') + text

    if not blob:
        return None
    # The C tool sorts with qsort by key alone; keys are unique in a valid
    # catalog, so a stable sort gives the same order.
    index = b''.join(struct.pack('>IIII', *entry)
                     for entry in sorted(entries, key=lambda item: item[0]))
    return bytes(blob) + index + struct.pack('>I', len(blob))


def main(argv):
    if len(argv) != 3:
        sys.stderr.write('Usage: %s input.po output.lmo\n' % argv[0])
        return 1
    with open(argv[1], 'rb') as handle:
        result = compile_po(handle.read())
    if result is None:
        return 0
    with open(argv[2], 'wb') as handle:
        handle.write(result)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
