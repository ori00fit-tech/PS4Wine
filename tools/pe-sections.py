#!/usr/bin/env python3
"""WinePS4 Enhanced: a PE file's sections - name (long names from the COFF string table, as mingw and lld write the
.debug_* ones), raw size and sha256 of the raw data - for tools/compare-pkg.py and by hand:

    python3 -I tools/pe-sections.py <file.dll> [<other.dll>]   (two files: side by side, '=' where the data is the same)
"""
import hashlib, struct, sys


def sections(path):
    data = open(path, 'rb').read()
    if data[:2] != b'MZ':
        return None
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    nsec, _, symtab, nsym, opt_size = struct.unpack_from('<HIIIH', data, pe + 6)
    strtab = symtab + nsym * 18 if symtab else 0
    out, off = [], pe + 24 + opt_size
    for i in range(nsec):
        raw_name, vsize, vaddr, rsize, rptr = struct.unpack_from('<8sIIII', data, off + i * 40)
        name = raw_name.rstrip(b'\0').decode('latin-1')
        if name.startswith('/') and strtab and name[1:].isdigit():  # a long name, in the string table
            s = strtab + int(name[1:])
            name = data[s:data.index(b'\0', s)].decode('latin-1')
        out.append((name, rsize, hashlib.sha256(data[rptr:rptr + rsize]).hexdigest()))
    return out


if __name__ == '__main__':
    a = sections(sys.argv[1])
    if len(sys.argv) == 2:
        for n, s, h in a:
            print(f'{n:<20}{s:>12}  {h[:16]}')
        sys.exit(0)
    b = {n: (s, h) for n, s, h in sections(sys.argv[2])}
    names = [n for n, _, _ in a] + [n for n in b if n not in {x for x, _, _ in a}]
    da = {n: (s, h) for n, s, h in a}
    print(f'{"section":<20}{"first":>12}{"second":>12}  same data')
    for n in names:
        sa, ha = da.get(n, (0, ''))
        sb, hb = b.get(n, (0, ''))
        print(f'{n:<20}{sa:>12}{sb:>12}  {"=" if ha == hb and ha else ("" if sa and sb else "missing")}')
