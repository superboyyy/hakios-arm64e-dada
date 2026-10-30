#!/bin/bash
# The dada screen as the resident loader sees it (the GOP framebuffer the kernel draws into), as PNG:
#   tools/dada-screenshot.sh [out.png]
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
out=${1:-logs/dada-screen.png}
geom=$(timeout 10 fastboot getvar screen 2>&1 | sed -n 's/^screen: //p')
[ -n "$geom" ] || { echo "no screen geometry from the loader"; exit 1; }
timeout 10 fastboot oem screenshot 2>&1 | grep -q OKAY || { echo "the loader has no display"; exit 1; }
timeout 60 fastboot get_staged logs/dada-screen.raw >/dev/null 2>&1 || { echo "fetch failed"; exit 1; }
python3 - logs/dada-screen.raw "$out" $geom <<'PY' && rm -f logs/dada-screen.raw && echo "$out ($geom)"
import struct, sys, zlib
raw, out, width, height, stride = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:6])
data = open(raw, 'rb').read()
rows = bytearray()
for y in range(height):
    line = data[y * stride:y * stride + width * 4]
    rows.append(0)
    rgb = bytearray(width * 3)
    rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]   # BGRX
    rows += rgb
def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
with open(out, 'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))
PY
