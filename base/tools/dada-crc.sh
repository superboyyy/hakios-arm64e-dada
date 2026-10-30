#!/bin/bash
# The resident image in the loader against the file it was sent from, 256 MB at a time:
#   tools/dada-crc.sh <image> <out-prefix>
# Writes <out-prefix>.txt (the loader's lines); prints the parts that differ, "same" if none.
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
img=$1 out=$2
ref=logs/$(basename "$img").crc
if [ ! -f "$ref" ] || [ "$img" -nt "$ref" ]; then
	python3 -c "
import sys, zlib
f = open(sys.argv[1], 'rb'); i = 0
while True:
    b = f.read(256 << 20)
    if not b: break
    print(f'ramdisk crc {i}: {zlib.crc32(b):x}'); i += 1
" "$img" > "$ref"
fi
t0=$(date +%s)
timeout 300 fastboot oem ramdisk crc 2>&1 | grep -q OKAY || { echo "crc: the loader did not answer"; exit 1; }
timeout 20 fastboot oem log >/dev/null 2>&1
timeout 60 fastboot get_staged "$out.raw" >/dev/null 2>&1 || { echo "crc: log fetch failed"; exit 1; }
strings -n 4 "$out.raw" | grep -a 'ramdisk crc [0-9]*:' > "$out.txt"
rm -f "$out.raw"
if diff -q "$out.txt" "$ref" >/dev/null; then
	echo "crc: resident image the same as $img ($(( $(date +%s) - t0 )) s)"
else
	echo "crc: resident image DIFFERS from $img in parts: $(diff "$out.txt" "$ref" | grep '^<' | sed 's/.*crc \([0-9]*\):.*/\1/' | tr '\n' ' ')"
fi
