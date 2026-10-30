#!/bin/bash
# Back up whole GPT partitions of dada through the loader, read only ("oem read"): phone in xnuloader.
#   tools/dada-backup-part.sh OUTDIR NAME:SIZEHEX...
out=$1; shift
mkdir -p "$out"
tmp=$(mktemp)
for spec in "$@"; do
	name=${spec%%:*} size=$((${spec#*:}))
	: > "$out/$name.img"
	at=0
	while [ $at -lt $size ]; do
		n=$(( size - at < 2097152 ? size - at : 2097152 ))
		timeout 30 fastboot oem read "$name" "$(printf %x $at)" "$(printf %x $n)" 2>&1 | grep -q OKAY || { echo "$name: read at $at failed"; exit 1; }
		timeout 60 fastboot get_staged "$tmp" >/dev/null 2>&1 && [ "$(stat -f %z "$tmp")" = "$n" ] || { echo "$name: fetch at $at failed"; exit 1; }
		cat "$tmp" >> "$out/$name.img"
		at=$((at + n))
	done
	echo "$name: $(stat -f %z "$out/$name.img") bytes, sha256 $(shasum -a 256 "$out/$name.img" | cut -c1-16)"
done
rm -f "$tmp"
