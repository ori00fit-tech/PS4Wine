"""WinePS4 Enhanced: PE file parsing and a byte-level classifier of the differences between two builds of the same DLL,
for tools/compare-pkg.py and tools/pe-sections.py.

classify(a, b) compares two PE files section by section and sorts every differing byte into one of these, each
recognised by what the bytes are, never by where they are alone:

  padding     inter-function alignment padding: on both sides only NOP encodings (90, 0f 1f 00, 66 90, ...),
              which no code reaches (it follows a ret or jmp). Seen: clang's i686 builds pad with 0f 1f 00 in the
              official package and with 90 90 90 here.
  ctor-list   mingw's __CTOR_LIST__/__DTOR_LIST__ sentinels (-1, 0 per list: ff x8 then 00 x8) placed in .rdata by one
              linker and at the end of .text by another: in .text or .rdata, only whole aligned pointer-size words
              (8 bytes, 4 for PE32) that are -1 on one side and 0 on the other, at most 32 bytes per section.
  debug       .debug_* sections (DWARF: build paths, the compiler's own identity string), not loaded at run time.
  symtab      the COFF symbol table and string table past the last section, not loaded at run time.
  timestamp   a 4-byte value equal, on each side, to that file's own COFF TimeDateStamp (the build time: the debug
              directory in .rdata repeats it).
  header      in the headers: the TimeDateStamp and CheckSum fields, and the section table's raw pointers of the
              .debug_* sections, which move when a debug section changes size.
  other       anything else: UNEXPLAINED.
A section present on one side only, or of another size, is "layout" (UNEXPLAINED)."""
import hashlib, struct

NOPS = {0x90, 0x0f, 0x1f, 0x00, 0x40, 0x44, 0x66, 0x2e, 0x84, 0x80}


def sections(path):
    """[(name, raw_size, raw_offset, data)] or None when the file is not PE"""
    data = open(path, 'rb').read()
    if data[:2] != b'MZ':
        return None, data
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None, data
    nsec, _, symtab, nsym, opt_size = struct.unpack_from('<HIIIH', data, pe + 6)
    strtab = symtab + nsym * 18 if symtab else 0
    out, off = [], pe + 24 + opt_size
    for i in range(nsec):
        raw_name, vsize, vaddr, rsize, rptr = struct.unpack_from('<8sIIII', data, off + i * 40)
        name = raw_name.rstrip(b'\0').decode('latin-1')
        if name.startswith('/') and strtab and name[1:].isdigit():  # a long name, in the COFF string table
            s = strtab + int(name[1:])
            name = data[s:data.index(b'\0', s)].decode('latin-1')
        out.append((name, rsize, rptr, data[rptr:rptr + rsize]))
    return out, data


def sha(b):
    return hashlib.sha256(b).hexdigest()


def runs(a, b, block=4096):
    """[(start, length)] of the differing bytes (blocks compared first: most of a section is the same)"""
    out, start, n = [], None, min(len(a), len(b))
    for base in range(0, n, block):
        if a[base:base + block] == b[base:base + block]:
            if start is not None:
                out.append((start, base - start)); start = None
            continue
        for i in range(base, min(base + block, n)):
            if a[i] != b[i]:
                if start is None:
                    start = i
            elif start is not None:
                out.append((start, i - start)); start = None
    if start is not None:
        out.append((start, n - start))
    return out


def coff(data):
    """(TimeDateStamp offset, its value, CheckSum offset, section table offset, number of sections)"""
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    nsec, ts = struct.unpack_from('<HI', data, pe + 6)
    opt_size = struct.unpack_from('<H', data, pe + 20)[0]
    return pe + 8, ts, pe + 24 + 64, pe + 24 + opt_size, nsec


def classify(path_a, path_b):
    """{'padding': n, 'ctor-list': n, 'debug': n, 'symtab': n, 'other': n, 'layout': [..]} in differing bytes"""
    res = {'padding': 0, 'ctor-list': 0, 'debug': 0, 'symtab': 0, 'timestamp': 0, 'header': 0, 'other': 0, 'layout': []}
    sa, da = sections(path_a)
    sb, db = sections(path_b)
    if sa is None or sb is None:
        res['other'] = sum(1 for x, y in zip(da, db) if x != y) + abs(len(da) - len(db))
        return res
    na = [(n, s) for n, s, _, _ in sa]
    nb = [(n, s) for n, s, _, _ in sb]
    if [n for n, _ in na] != [n for n, _ in nb]:
        res['layout'] = sorted(set(na) ^ set(nb))
    else:
        res['layout'] = sorted(x for x in set(na) ^ set(nb) if not x[0].startswith('.debug'))
    mb = {n: (s, o, d) for n, s, o, d in sb}
    for n, s, o, d in sa:
        if n not in mb:
            continue
        if mb[n][0] != s:
            if n.startswith('.debug'):
                res['debug'] += max(s, mb[n][0])
            continue
        e = mb[n][2]
        if d == e:
            continue
        if n.startswith('.debug'):
            res['debug'] += s
            continue
        diff = runs(d, e)
        count = sum(l for _, l in diff)
        # only whole pointer-size words, aligned, that are -1 (all ff) on one side and 0 on the other, in .text or
        # .rdata: the sentinel words themselves. (Before run #12's review any ff/00 bytes counted, wherever they
        # were: one changed 0xff byte in code passed as ctor-list.)
        word = 8 if struct.unpack_from('<H', da, struct.unpack_from('<I', da, 0x3c)[0] + 24)[0] == 0x20b else 4
        ff00 = n in ('.text', '.rdata') and all(
            st % word == 0 and l % word == 0 and
            all({d[k:k + word], e[k:k + word]} == {b'\xff' * word, b'\0' * word} for k in range(st, st + l, word))
            for st, l in diff)
        if ff00 and count <= 32:
            res['ctor-list'] += count
            continue
        ts_a, ts_b = struct.pack('<I', coff(da)[1]), struct.pack('<I', coff(db)[1])
        for st, l in diff:
            if all(d[i] in NOPS and e[i] in NOPS for i in range(st, st + l)):
                res['padding'] += l
                continue
            # a run inside a 4-byte value that is each file's own TimeDateStamp
            w = next((k for k in range(max(0, st - 3), st + 1)
                      if k + 4 >= st + l and d[k:k + 4] == ts_a and e[k:k + 4] == ts_b), None)
            if w is not None and ts_a != ts_b:
                res['timestamp'] += l
            else:
                res['other'] += l
    # past the sections: the COFF symbol table and its strings
    end_a = max(o + s for _, s, o, _ in sa)
    end_b = max(o + s for _, s, o, _ in sb)
    if da[end_a:] != db[end_b:]:
        res['symtab'] += max(len(da) - end_a, len(db) - end_b)
    # the headers before the first section
    tso, _, cso, sto, nsec = coff(da)
    allowed = set(range(tso, tso + 4)) | set(range(cso, cso + 4))
    for i, (n, _, _, _) in enumerate(sa):
        if n.startswith('.debug') or i > 0 and any(x.startswith('.debug') for x, _, _, _ in sa[:i]):
            allowed |= set(range(sto + i * 40 + 20, sto + i * 40 + 24))  # PointerToRawData
            if n.startswith('.debug'):
                allowed |= set(range(sto + i * 40 + 8, sto + i * 40 + 20))  # its sizes and address
    # a .debug section of another size moves what follows it and the image's sizes (lld maps debug sections):
    # SizeOfInitializedData, SizeOfImage, and the later sections' addresses - only then, and only these
    if any(n.startswith('.debug') and n in mb and mb[n][0] != sz for n, sz, _, _ in sa):
        opt = sto - struct.unpack_from('<H', da, tso + 12)[0]
        allowed |= set(range(opt + 8, opt + 12)) | set(range(opt + 56, opt + 60))
        seen = False
        for i, (n, _, _, _) in enumerate(sa):
            if seen:
                allowed |= set(range(sto + i * 40 + 12, sto + i * 40 + 16))  # VirtualAddress
            seen = seen or (n.startswith('.debug') and n in mb and mb[n][0] != sa[i][1])
    # sections with no data in the file (.bss: PointerToRawData 0) say nothing about where the headers end; counting
    # them made first_a 0 and skipped this whole check (run #9: 655 x86_64 DLLs' linker version and Load Config)
    first_a = min((o for _, _, o, _ in sa if o), default=0)
    for i in range(min(first_a, len(da), len(db))):
        if da[i] != db[i]:
            res['header' if i in allowed else 'other'] += 1
    return res
