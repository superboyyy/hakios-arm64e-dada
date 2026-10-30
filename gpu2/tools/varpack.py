#!/usr/bin/env python3
# /private/var as earlier boots left it, for the next image (build.sh VAR_PACK=; init unpacks it before launchd: userland/src/init.c
# var_pack): the exports of userland/src/stateexport.c (<log>.m2vexp from tools/dada-run.sh, "SHEXR001" blobs whose stream's directory is
# /private/var) merged onto an existing pack.
#   varpack.py [--base OLD.var.pack] OUT.var.pack EXPORT.m2vexp...
# Each export holds whole directories (stateexport.c's list, every file in them), so a later export REPLACES each top directory it
# carries -- the first four path components below /private/var, the directory stateexport.c names -- with all of its files; files iOS removed meanwhile do not come back.
# Directories an export does not carry stay as the base had them.
# Pack: the "M2VCACH1" stream itself, uncompressed (init reads it with plain read()).
# Exports whose directory is not /private/var (the plug-in's own: tools/m2vpack.py) are left out.
import struct, sys, zlib

ROOT = b'/private/var'


def files_of(stream):
    if stream[:8] != b'M2VCACH1':
        raise ValueError('not a cache stream')
    at = 8
    (n,) = struct.unpack_from('<I', stream, at); at += 4
    root = stream[at:at + n]; at += n
    (count,) = struct.unpack_from('<I', stream, at); at += 4
    out = {}
    for _ in range(count):
        plen, mode, uid, gid, size = struct.unpack_from('<IIIIQ', stream, at); at += 24
        path = stream[at:at + plen]; at += plen
        out[path] = (mode, uid, gid, stream[at:at + size]); at += size
        if at > len(stream):
            raise ValueError('a file runs past the stream')
    return root, out


def stream_of(blob):
    if blob[:8] == b'SHEXR001':
        (n,) = struct.unpack_from('<I', blob, 8)
        return blob[16:16 + n]
    if blob[:8] == b'SHEXP001':
        n, z = struct.unpack_from('<II', blob, 8)
        return zlib.decompress(blob[16:16 + z])
    if blob[:8] == b'M2VCACH1':
        return blob
    raise ValueError('not an export, pack or stream')


def top(path):
    return b"/".join(path.split(b"/")[:4])


def main(argv):
    base = None
    if argv[:1] == ['--base']:
        base, argv = argv[1], argv[2:]
    if len(argv) < 2:
        sys.exit('usage: varpack.py [--base OLD.var.pack] OUT.var.pack EXPORT...')
    out, exports = argv[0], argv[1:]
    files = {}
    if base:
        root, files = files_of(stream_of(open(base, 'rb').read()))
        assert root == ROOT, root
        print(f'{base}: {len(files)} files')
    for e in exports:
        root, new = files_of(stream_of(open(e, 'rb').read()))
        if root != ROOT:
            print(f'{e}: directory {root.decode(errors="replace")}, not /private/var: left out (tools/m2vpack.py takes it)')
            continue
        replaced = {top(p) for p in new}
        files = {p: f for p, f in files.items() if top(p) not in replaced}
        files.update(new)
        print(f'{e}: {len(new)} files in {", ".join(sorted(t.decode(errors="replace") for t in replaced))}')
    body = bytearray(b'M2VCACH1' + struct.pack('<I', len(ROOT)) + ROOT + struct.pack('<I', len(files)))
    for path in sorted(files):
        mode, uid, gid, data = files[path]
        body += struct.pack('<IIIIQ', len(path), mode, uid, gid, len(data)) + path + data
    open(out, 'wb').write(body)
    tops = {}
    for p, f in files.items():
        tops[top(p)] = tops.get(top(p), 0) + len(f[3])
    for t, n in sorted(tops.items()):
        print(f'  {t.decode(errors="replace")}: {n // 1024} KB')
    print(f'{out}: {len(files)} files, {len(body) // 1024} KB')


if __name__ == '__main__':
    main(sys.argv[1:])
