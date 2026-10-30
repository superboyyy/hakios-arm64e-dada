#!/usr/bin/env python3
# The render server's pipeline cache, from the boots that exported it (RedwoodGPU's gpu_export_mb, tools/dada-run.sh: <log>.m2vexp,
# "SHEXR001" blobs of NativeMetal's CacheExport.h) into the pack the next image carries (build.sh GPU2_PIPELINES=; the plug-in imports
# it before the device opens): the union of every export's files, a later export's file in place of an earlier one at the same path, and
# the files of an existing pack (--base) first.
#   m2vpack.py [--base OLD.m2vpack] OUT.m2vpack EXPORT.m2vexp...
# Formats (CacheExport.h): export "SHEXR001", u32 stream bytes, u32 0, stream; pack "SHEXP001", u32 stream bytes, u32 compressed bytes,
# zlib(stream); stream "M2VCACH1", u32 n, root (n bytes), u32 files, then per file u32 path bytes, u32 mode, u32 uid, u32 gid, u64 size,
# path, contents.
import struct, sys, zlib


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
    magic = blob[:8]
    length, third = struct.unpack_from('<II', blob, 8)
    if magic == b'SHEXR001':
        return blob[16:16 + length]
    if magic == b'SHEXP001':
        stream = zlib.decompress(blob[16:16 + third])
        if len(stream) != length:
            raise ValueError('a pack inflates to another length')
        return stream
    raise ValueError('neither an export nor a pack')


def main():
    args = sys.argv[1:]
    base = None
    if args[:1] == ['--base']:
        base, args = args[1], args[2:]
    if len(args) < 2:
        sys.exit(__doc__ or 'm2vpack.py [--base OLD] OUT EXPORT...')
    out, inputs = args[0], ([base] if base else []) + args[1:]
    root, files = b'', {}
    for name in inputs:
        blob = open(name, 'rb').read()
        r, f = files_of(stream_of(blob))
        root = root or r
        files.update(f)
        print(f'{name}: {len(f)} files, {sum(len(v[3]) for v in f.values()) >> 10} KiB')
    parts = [b'M2VCACH1', struct.pack('<I', len(root)), root, struct.pack('<I', len(files))]
    for path in sorted(files):
        mode, uid, gid, data = files[path]
        parts += [struct.pack('<IIIIQ', len(path), mode, uid, gid, len(data)), path, data]
    stream = b''.join(parts)
    packed = zlib.compress(stream, 9)
    with open(out, 'wb') as f:
        f.write(b'SHEXP001' + struct.pack('<II', len(stream), len(packed)) + packed)
    print(f'{out}: {len(files)} files, stream {len(stream) >> 10} KiB, pack {len(packed) >> 10} KiB')


if __name__ == '__main__':
    main()
