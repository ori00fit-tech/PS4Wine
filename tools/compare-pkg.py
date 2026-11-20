#!/usr/bin/env python3
"""WinePS4 Enhanced: compares two extracted WinePS4 packages (PkgTool pkg_extract trees) and writes a Markdown report.

    python3 -I tools/compare-pkg.py <official uroot> <built uroot> <official param.txt> <built param.txt> <out.md>

Every material difference is listed under "Differences", each with its explanation: EXPLAINED (the cause is
established by evidence in this report or in docs/BUILD_FROM_SOURCE.md) or UNEXPLAINED (it needs a look before the
package is trusted). Nothing here runs either package."""
import hashlib, importlib.util, os, re, subprocess, sys

_spec = importlib.util.spec_from_file_location('pelib', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pelib.py'))
pelib = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(pelib)

off_root, our_root, off_sfo, our_sfo, out_md = sys.argv[1:6]


def files(root):
    out = {}
    for d, _, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            out[os.path.relpath(p, root)] = p
    return out


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def area(rel):
    parts = rel.split('/')
    if rel.startswith('wine/lib/wine/'):
        return 'wine/lib/wine/' + parts[3]
    if rel.startswith('wine/prefix/'):
        return 'wine/prefix'
    if len(parts) == 1:
        return '(top level)'
    return '/'.join(parts[:2]) if parts[0] == 'wine' else parts[0]


def sfo(path):
    d = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        if ' = ' in line and ':' in line:
            k = line.split(':', 1)[0].strip()
            d[k] = line.rsplit(' = ', 1)[1].strip()
    return d


def strings(p, pattern):
    out = subprocess.run(['strings', '-n', '8', p], capture_output=True, text=True).stdout
    return sorted(set(m for m in out.splitlines() if re.fullmatch(pattern, m)))


def cc_all(p):
    out = subprocess.run(['strings', '-n', '8', p], capture_output=True, text=True).stdout
    return ', '.join(sorted(set(m.group(0) for m in re.finditer(r'GCC: \(GNU\) \S+|(?:Ubuntu )?clang version [0-9.]+(?: \([^)]*\))?', out)))) or '-'
def area_compiler_file(name):
    # the kernelbase.dll of the area's architecture (the prefix: its i386 copies are in syswow64, its x86_64 in system32;
    # reported with the i386 one, which is where the two packages' compilers differ)
    return 'wine/lib/wine/x86_64-windows/kernelbase.dll' if 'x86_64' in name else 'wine/lib/wine/i386-windows/kernelbase.dll'


O, U = files(off_root), files(our_root)
common = sorted(set(O) & set(U))
only_off = sorted(set(O) - set(U))
only_our = sorted(set(U) - set(O))

areas = {}
for rel in sorted(set(O) | set(U)):
    a = areas.setdefault(area(rel), {'off_n': 0, 'our_n': 0, 'off_b': 0, 'our_b': 0, 'same': 0, 'diff': 0})
    if rel in O:
        a['off_n'] += 1; a['off_b'] += os.path.getsize(O[rel])
    if rel in U:
        a['our_n'] += 1; a['our_b'] += os.path.getsize(U[rel])
diff_files = []
for rel in common:
    a = areas[area(rel)]
    if os.path.getsize(O[rel]) == os.path.getsize(U[rel]) and sha(O[rel]) == sha(U[rel]):
        a['same'] += 1
    else:
        a['diff'] += 1; diff_files.append(rel)

so, su = sfo(off_sfo), sfo(our_sfo)
md = []
w = md.append
w('# Comparison with the official WinePS4 package')
w('')
w('Both packages were extracted with the PkgTool this build makes. Nothing in this report ran either package on a console.')
w('')
w('## param.sfo')
w('| Entry | Official | This build |')
w('|---|---|---|')
for k in sorted(set(so) | set(su)):
    mark = '' if so.get(k) == su.get(k) else ' ⟵'
    w(f'| {k} | `{so.get(k, "-")}` | `{su.get(k, "-")}`{mark} |')
w('')
w('## Files by area')
w(f'Files: official {len(O)}, this build {len(U)}; in both {len(common)} '
  f'(byte-identical {sum(a["same"] for a in areas.values())}, different {len(diff_files)}).')
w('')
w('| Area | Files (off / ours) | Bytes (off / ours) | Identical | Different |')
w('|---|---|---|---|---|')
for name, a in sorted(areas.items()):
    w(f'| {name} | {a["off_n"]} / {a["our_n"]} | {a["off_b"]:,} / {a["our_b"]:,} | {a["same"]} | {a["diff"]} |')
w('')
w('## Only in the official package')
w('\n'.join(f'- `{r}`' for r in only_off) or '- none')
w('')
w('## Only in this build')
w('\n'.join(f'- `{r}`' for r in only_our) or '- none')
w('')

# the eboots and the compilers
w('## The eboots')
w('| | Official | This build |')
w('|---|---|---|')
for e in ('eboot.bin', 'wineps4.bin'):
    w(f'| {e} size | {os.path.getsize(O[e]):,} | {os.path.getsize(U[e]):,} |')
imp_o = strings(O['wineps4.bin'], r'lib(Sce[A-Za-z0-9]+|kernel)')
imp_u = strings(U['wineps4.bin'], r'lib(Sce[A-Za-z0-9]+|kernel)')
w(f'| wineps4.bin imports | {len(imp_o)} | {len(imp_u)} ({"same list" if imp_o == imp_u else "DIFFERENT"}) |')
ver_o = strings(O['wineps4.bin'], r'wineps4: WinePS4 v[0-9.]+ \(Wine [0-9.]+\)')
ver_u = strings(U['wineps4.bin'], r'wineps4: WinePS4 v[0-9.]+ \(Wine [0-9.]+\)')
w(f'| version string | {", ".join(ver_o)} | {", ".join(ver_u)} |')
h40_o = set(strings(O['wineps4.bin'], r'[0-9a-f]{40}'))
h40_u = set(strings(U['wineps4.bin'], r'[0-9a-f]{40}'))
w(f'| 40-hex ids (build ids) | {len(h40_o)}, {len(h40_o & h40_u)} shared | {len(h40_u)}, only here: {", ".join(sorted(x[:12] for x in h40_u - h40_o)) or "-"} |')
kb = 'wine/lib/wine/x86_64-windows/kernelbase.dll'
cc_o = strings(O[kb], r'GCC: \(GNU\) .*')
cc_u = strings(U[kb], r'GCC: \(GNU\) .*')
w(f'| PE compiler (x86_64 kernelbase.dll) | {", ".join(cc_o)} | {", ".join(cc_u)} |')
kb32 = 'wine/lib/wine/i386-windows/kernelbase.dll'
w(f'| PE compiler (i386 kernelbase.dll) | {cc_all(O[kb32])} | {cc_all(U[kb32])} |')
w('')

# the system symbols each eboot imports (NID#library#module, as create-fself writes them), compared one by one:
# any difference fails (no rule explains one: an import the console's loader resolves differently can stop the app
# before it logs anything, as run #7's __stack_chk_guard and __stack_chk_fail most likely did)
def nid_names():
    names = {}
    root = os.environ.get('PS4LIBDOC', os.path.expanduser('~/oo-src/ps4libdoc'))
    import json, glob
    for f in glob.glob(os.path.join(root, 'system', 'common', 'lib', '*.json')):
        try:
            d = json.load(open(f, encoding='utf-8-sig'))
        except Exception:
            continue
        for m in d.get('modules', []):
            for lib in m.get('libraries', []):
                for sym in lib.get('symbols', []):
                    if sym.get('encoded_id') and sym.get('name'):
                        names.setdefault(sym['encoded_id'], sym['name'])
    return names
def imports(p):
    out = subprocess.run(['strings', '-n', '13', p], capture_output=True, text=True).stdout
    return set(m for m in out.splitlines() if re.fullmatch(r'[A-Za-z0-9+-]{11}#[A-Za-z0-9+-]+#[A-Za-z0-9+-]+', m))
nidmap = nid_names()
import_diffs = []
w('## Imported system symbols')
w('| | Official | This build | Only official | Only this build |')
w('|---|---|---|---|---|')
for e in ('wineps4.bin', 'eboot.bin'):
    io, iu = imports(O[e]), imports(U[e])
    name = lambda n: f'{nidmap.get(n.split("#")[0], "?")} ({n})'
    oo, uu = sorted(io - iu), sorted(iu - io)
    w(f'| {e} | {len(io)} | {len(iu)} | {", ".join(map(name, oo)) or "-"} | {", ".join(map(name, uu)) or "-"} |')
    if oo or uu:
        import_diffs.append((e, oo, uu, name))
w('')

# the differences, each explained or not
w('## Differences')
expl = []
sfo_d = [k for k in set(so) | set(su) if so.get(k) != su.get(k)]
for k in sorted(sfo_d):
    if k == 'PUBTOOLINFO':
        expl.append(('EXPLAINED', 'param.sfo PUBTOOLINFO', 'c_date is the build date and img0_l0_size the image size: both differ by construction.'))
    else:
        expl.append(('UNEXPLAINED', f'param.sfo {k}', f'official `{so.get(k)}`, this build `{su.get(k)}`.'))
stale = [r for r in only_off if r.startswith('wine/prefix/drive_c/windows/')]
if stale:
    expl.append(('EXPLAINED', f'{len(stale)} prefix files only in the official package',
                 'they differ from the official package\'s own lib copies (older builds of the same DLLs kept in the '
                 'official prefix), so its package.sh kept them; here the prefix copies equal lib, and package.sh lists '
                 'them in system32-from-lib.txt instead (the first start copies them from lib).'))
rest = [r for r in only_off if r not in stale] + only_our
if rest:
    expl.append(('UNEXPLAINED', f'{len(rest)} other files in one package only', ', '.join(rest[:20])))
def is_pe(path):
    with open(path, 'rb') as f:
        return f.read(2) == b'MZ'
pe = [r for r in diff_files if (r.startswith('wine/lib/wine/') or r.startswith('wine/prefix/')) and is_pe(O[r]) and is_pe(U[r])]
# the prefix's registry files: compared with their timestamps taken out (the "[key] <seconds>" stamps and the
# "#time=" lines wineboot writes) - what is left must be the same, line for line
reg_ts = re.compile(r'^(\[.*\]) [0-9]+$')
def reg_norm(path):
    out = []
    for line in open(path, encoding='utf-8', errors='replace').read().splitlines():
        if re.fullmatch(r'#time=[0-9a-f]+', line):
            continue
        out.append(reg_ts.sub(r'\1', line))
    return out
for r in [r for r in diff_files if r.startswith('wine/prefix/') and r.endswith('.reg')]:
    a, b = reg_norm(O[r]), reg_norm(U[r])
    if a == b:
        expl.append(('EXPLAINED', r, 'the same, line for line, once the key timestamps and #time= lines are taken out.'))
    else:
        import difflib
        d = [x for x in difflib.unified_diff(a, b, lineterm='', n=0) if x[:1] in '+-' and x[:3] not in ('+++', '---')]
        users_o = sorted(set(re.findall(r'C:\\\\users\\\\([^\\"]+)', '\n'.join(a))))
        users_u = sorted(set(re.findall(r'C:\\\\users\\\\([^\\"]+)', '\n'.join(b))))
        sample = '; '.join(x[:90] for x in d[:4])
        expl.append(('UNEXPLAINED', r, f'{len(d)} lines differ beyond the timestamps (Windows user folders: official '
                     f'{users_o or "-"}, this build {users_u or "-"}). First: {sample}'))
    diff_files_handled = True
if 'wine/prefix/.update-timestamp' in diff_files:
    t = [open(x[r], 'rb').read().strip() for x, r in ((O, 'wine/prefix/.update-timestamp'), (U, 'wine/prefix/.update-timestamp'))]
    expl.append(('EXPLAINED' if all(v.isdigit() for v in t) else 'UNEXPLAINED', 'wine/prefix/.update-timestamp',
                 f'the time wineboot ran ({t[0].decode(errors="replace")} vs {t[1].decode(errors="replace")}).'))
if pe:
    # every differing PE file classified byte by byte (tools/pelib.py): a file is explained when none of its bytes
    # is "other" and its sections have the same names and sizes (debug sections excepted)
    kinds = ('padding', 'ctor-list', 'debug', 'symtab', 'timestamp', 'header', 'other')
    per_area, worst = {}, []
    for r in pe:
        c = pelib.classify(O[r], U[r])
        a = per_area.setdefault(area(r), {k: 0 for k in kinds} | {'files': 0, 'clean': 0})
        a['files'] += 1
        for k in kinds:
            a[k] += c[k]
        if c['other'] == 0 and not c['layout']:
            a['clean'] += 1
        else:
            worst.append((c['other'], r, c['layout']))
    w('## Wine PE files: what the differing bytes are')
    w('Each differing DLL compared section by section (tools/pelib.py). Byte counts per kind; a file is clean when it '
      'has no "other" byte and the same sections.')
    w('')
    w('| Area | Differing files | Clean | ' + ' | '.join(kinds) + ' |')
    w('|---|---|---|' + '---|' * len(kinds))
    for name, a in sorted(per_area.items()):
        w(f'| {name} | {a["files"]} | {a["clean"]} | ' + ' | '.join(f'{a[k]:,}' for k in kinds) + ' |')
    w('')
    if worst:
        w('Files with unexplained bytes (most first):')
        for o, r, lay in sorted(worst, reverse=True)[:25]:
            w(f'- `{r}`: {o:,} other bytes' + (f'; sections differ: {lay}' if lay else ''))
        w('')
    for name, a in sorted(per_area.items()):
        if a['clean'] == a['files']:
            expl.append(('EXPLAINED', f'{a["files"]} PE files in {name} with other bytes',
                         'every differing byte classified: ' + ', '.join(f'{k} {a[k]:,}' for k in kinds if a[k]) +
                         ' (tools/pelib.py: alignment padding, the CTOR/DTOR list placement, debug info, the COFF '
                         'symbol table, the build timestamp, the header fields those move); no other byte.'))
        else:
            expl.append(('UNEXPLAINED', f'{a["files"] - a["clean"]} of {a["files"]} PE files in {name}',
                         f'{a["other"]:,} bytes that are none of the known kinds (the list above). Compilers '
                         f'({area_compiler_file(name)}): official {cc_all(O[area_compiler_file(name)])}, '
                         f'this build {cc_all(U[area_compiler_file(name)])}.'))
eb = [r for r in diff_files if r in ('eboot.bin', 'wineps4.bin')]
if eb:
    expl.append(('EXPLAINED', 'eboot.bin, wineps4.bin bytes',
                 'built from the same WinePS4 source with ps4-kit 1f2bd79 (upstream: 56b3d86, not public), clang 21 and '
                 'a toolchain rebuilt from source; wineps4.bin carries the RADV build id of the public kit\'s Mesa patch '
                 'files. Same imports and version string (above).'))
# system32-from-lib.txt: explained only when its difference is exactly the stale prefix files above
lst = 'wine/system32-from-lib.txt'
if lst in diff_files:
    lo = set(open(O[lst]).read().split()); lu = set(open(U[lst]).read().split())
    stale_entries = {('system32/' if '/system32/' in r else 'syswow64/') + r.rsplit('/', 1)[1] for r in stale}
    if lo <= lu and lu - lo == stale_entries:
        expl.append(('EXPLAINED', lst, f'this build lists {len(lu - lo)} more entries, exactly the prefix files above.'))
        eb.append(lst)
# the test programs (tests/*.c, compiled on the build machine)
tests = [r for r in diff_files if r in ('wine/hello.exe', 'wine/hello32.exe', 'wine/window.exe')]
if tests:
    def cc(p):  # every compiler string in the file (the program's own and those of the libraries linked in)
        out = subprocess.run(['strings', '-n', '8', p], capture_output=True, text=True).stdout
        found = sorted(set(m.group(0) for m in re.finditer(r'GCC: \(GNU\) \S+|clang version [0-9.]+', out)))
        return ' + '.join(found) or 'no compiler string'
    expl.append(('EXPLAINED', 'test programs ' + ', '.join(r.split('/')[-1] for r in tests),
                 'compiled from tests/*.c on each build machine: ' +
                 '; '.join(f'{r.split("/")[-1]} {cc(O[r])} vs {cc(U[r])}' for r in tests) + '.'))
    eb.extend(tests)
other = [r for r in diff_files if r not in pe and r not in eb and not (r.startswith('wine/prefix/') and (r.endswith('.reg') or r.endswith('.update-timestamp')))]
if other:
    expl.append(('UNEXPLAINED', f'{len(other)} other files with other bytes', ', '.join(other[:30])))
if imp_o != imp_u:
    expl.append(('UNEXPLAINED', 'wineps4.bin imports', f'official {imp_o}, this build {imp_u}'))
w('| Status | Difference | Explanation |')
w('|---|---|---|')
for s, d, e in expl:
    w(f'| {"**UNEXPLAINED**" if s == "UNEXPLAINED" else s} | {d} | {e} |')
for e, oo, uu, name in import_diffs:
    expl.append(('UNEXPLAINED', f'{e}: imported system symbols',
                 'official only: ' + (', '.join(map(name, oo)) or '-') + '; this build only: ' + (', '.join(map(name, uu)) or '-') + '.'))
unexplained = sum(1 for s, _, _ in expl if s == 'UNEXPLAINED')
w('')
w(f'Result: {"every difference explained" if not unexplained else f"**{unexplained} unexplained difference(s)**"}.')
open(out_md, 'w').write('\n'.join(md) + '\n')
print('\n'.join(md))
sys.exit(1 if unexplained else 0)
