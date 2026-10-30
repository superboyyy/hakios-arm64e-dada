#!/usr/bin/env python3
"""Read a logical partition of super off dada, through the loader, read only ("oem read super ...").

usage: tools/dada-pull-lp.py EXTENTS.json OUT.img

EXTENTS.json is [[first sector of super, sectors], ...] in the partition's own order (liblp's table,
as tools write it from the loader's survey of super). The phone must be in the loader. Nothing is
written to the phone: each piece is read into the loader's staged buffer and fetched with
"fastboot get_staged".
"""
import json
import os
import subprocess
import sys
import tempfile

CHUNK = 2 << 20


def fastboot(*args, timeout=60):
    r = subprocess.run(['fastboot', *args], capture_output=True, text=True, timeout=timeout)
    if 'OKAY' not in r.stderr + r.stdout:
        sys.exit(f'fastboot {" ".join(args)}: {r.stderr.strip()}')


def main():
    extents = json.load(open(sys.argv[1]))
    out = open(sys.argv[2], 'wb')
    tmp = tempfile.NamedTemporaryFile(delete=False).name
    total = sum(n for _, n in extents) * 512
    done = 0
    for sector, count in extents:
        at, left = sector * 512, count * 512
        while left:
            n = min(left, CHUNK)
            fastboot('oem', 'read', 'super', f'{at:x}', f'{n:x}')
            r = subprocess.run(['fastboot', 'get_staged', tmp], capture_output=True, text=True, timeout=60)
            data = open(tmp, 'rb').read()
            if len(data) != n:
                sys.exit(f'got {len(data)} bytes for {n} at {at:#x}: {r.stderr.strip()}')
            out.write(data)
            at += n
            left -= n
            done += n
            print(f'\r{done >> 20}/{total >> 20} MB', end='', flush=True)
    print()
    os.unlink(tmp)


if __name__ == '__main__':
    main()
