#!/bin/bash
# The iOS system image kept on dada's own storage, as an Android DSU image ("Dynamic System Updates"):
# Android writes it into userdata beneath the metadata encryption, so it is plaintext on the storage, and
# the loader reads it into the kernel's memory window in about 1.5 s ("oem dsu load"; tools/dada-run.sh
# with DSU=1) instead of 130 s over USB.
#
#   tools/dada-dsu.sh install [image]   (phone in Android) install the image through Android's own DSU
#                                       installer, in a slot of DSU_SIZE bytes (default 24 GiB) so that a
#                                       grown image still fits; never enabled, so the phone keeps booting
#                                       Android. Takes the 5 GB through adb once.
#   tools/dada-dsu.sh patch [image]     (phone in xnuloader) send only the 1 MB pieces that differ from what
#                                       the phone has (logs/dsu-image.sums), "oem dsu patch"; the loader writes
#                                       them inside the image's own extents only and reads each back.
#   tools/dada-dsu.sh status            (phone in Android) gsi_tool status
# Undo: Settings > Developer options > DSU, or the DSU notification's "Discard".
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
cmd=${1:-status}
img=${2:-userland/system.apfs}
SLOT=${DSU_SIZE:-25769803776}
SUMS=logs/dsu-image.sums
PIECE=$((1 << 20))
T() { timeout "$@"; }

sums() {    # sums IMAGE: one hash per 1 MB piece, the slot's whole size (what is past the image is zeros)
	python3 - "$1" "$SLOT" <<'EOF'
import hashlib, sys
path, slot = sys.argv[1], int(sys.argv[2])
piece = 1 << 20
zero = hashlib.sha1(bytes(piece)).hexdigest()
with open(path, 'rb') as f:
    n = 0
    while n * piece < slot:
        b = f.read(piece)
        print(hashlib.sha1(b.ljust(piece, b'\0')).hexdigest() if b else zero)
        n += 1
EOF
}

case "$cmd" in
status)
	adb shell gsi_tool status ;;
install)
	size=$(stat -f %z "$img")
	[ "$size" -le "$SLOT" ] || { echo "dsu: $img ($size bytes) is bigger than the slot ($SLOT): DSU_SIZE="; exit 1; }
	adb devices | grep -q 'device$' || { echo "dsu: the phone is not in Android"; exit 1; }
	gz=userland/dsu-system.gz
	echo "dsu: $img, padded to $SLOT bytes, gzipped"
	{ cat "$img"; head -c $((SLOT - size)) /dev/zero; } | { command -v pigz >/dev/null && pigz -1 || gzip -1; } > "$gz" || exit 1
	adb shell setprop persist.sys.fflag.override.settings_dynamic_system true
	adb push "$gz" /sdcard/Download/dsu-system.gz || exit 1
	adb shell gsi_tool status
	adb shell am start-activity -W -n com.android.dynsystem/com.android.dynsystem.VerificationActivity \
	    -a android.os.image.action.START_INSTALL -d file:///storage/emulated/0/Download/dsu-system.gz \
	    --el KEY_SYSTEM_SIZE "$SLOT" --el KEY_USERDATA_SIZE 2147483648 >/dev/null
	echo "dsu: installing (Android's DSU installer)..."
	# done when the installer's notification has left "ready" (an image already there says so too) for
	# its progress, and come back to it: gsi_tool says "installed" for the old image meanwhile
	note() { adb shell 'dumpsys notification --noredact 2>/dev/null | grep -A30 "pkg=com.android.dynsystem" | grep -m1 "android.text="'; }
	busy=0
	for i in $(seq 1 240); do
		sleep 5
		t=$(note)
		case "$t" in
		*准备就绪*|*ready*|*Ready*) [ $busy = 1 ] && { echo "dsu: ready after ~$((i * 5)) s"; break; } ;;
		"") ;;
		*) busy=1 ;;
		esac
	done
	[ $busy = 1 ] || echo "dsu: never saw the installer at work: check with tools/dada-dsu.sh status and the loader's \"oem dsu\""
	adb shell rm -f /sdcard/Download/dsu-system.gz /sdcard/Download/system_raw.gz
	rm -f "$gz"
	sums "$img" > "$SUMS"
	echo "dsu: done; what the phone has is in $SUMS (tools/dada-run.sh with DSU=1 reads it)" ;;
patch)
	[ -f "$SUMS" ] || { echo "dsu: no $SUMS: install first"; exit 1; }
	size=$(stat -f %z "$img")
	[ "$size" -le "$SLOT" ] || { echo "dsu: $img is bigger than the slot: install again with a bigger DSU_SIZE"; exit 1; }
	sums "$img" > "$SUMS.new"
	# runs of changed pieces, at most 32 MB each
	runs=$(paste -d' ' "$SUMS" "$SUMS.new" | awk -v max=32 '
		{ diff = ($1 != $2) }
		diff && start < 0 { start = NR - 1; len = 0 }
		diff { len++; if (len == max) { print start, len; start = -1 } ; next }
		start >= 0 { print start, len; start = -1 }
		BEGIN { start = -1 } END { if (start >= 0) print start, len }')
	n=$(echo "$runs" | grep -c .)
	[ "$n" = 0 ] && { echo "dsu: nothing changed"; rm -f "$SUMS.new"; exit 0; }
	echo "dsu: $n runs of changed 1 MB pieces, $(echo "$runs" | awk '{s += $2} END {print s}') MB in all"
	tmp=logs/.dsu-piece
	echo "$runs" | while read -r start len; do
		{ dd if="$img" bs=$PIECE skip="$start" count="$len" 2>/dev/null; } > "$tmp"
		# past the image's end the slot holds zeros
		have=$(stat -f %z "$tmp"); [ "$have" -lt $((len * PIECE)) ] && head -c $((len * PIECE - have)) /dev/zero >> "$tmp"
		T 30 fastboot oem dsu patch "$(printf %x $((start * PIECE)))" 2>&1 | grep -q OKAY &&
		T 120 fastboot stage "$tmp" 2>&1 | grep -q OKAY || { echo "dsu: piece at $start MB not written"; rm -f "$tmp"; exit 1; }
	done || exit 1
	rm -f "$tmp"
	mv "$SUMS.new" "$SUMS"
	echo "dsu: patched" ;;
*)
	echo "usage: tools/dada-dsu.sh install|patch|status [image]"; exit 1 ;;
esac
