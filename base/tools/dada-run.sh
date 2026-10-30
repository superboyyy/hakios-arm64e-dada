#!/bin/bash
# One kernel run on dada, start to finish, without anyone at the phone:
#   tools/dada-run.sh <name> [budget_seconds] [extra boot-args...]
# env: CHECKPOINT=N  BOOTCPU=N (default 2)  KEEP=0 (always reset afterwards) / KEEP=1 (never)
# Brings up the loader (tools/dada-cycle.sh), runs, keeps the newest live log every few seconds
# (so a wedge still leaves the last one). A kernel that came back leaves the loader up for the next
# run, which then skips the trip through Android and, when RESIDENT is the same image, its upload;
# a kernel that did not come back is reset through the watchdog.
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
S=${XNU12377:-$HOME/hakios-gpu2/xnu12377}
K=$S/BUILD/obj/mach.development.bcm2837
name=${1:?name}; shift
budget=${1:-60}; [ $# -gt 0 ] && shift
extra="$* epoch=$(date +%s)"   # the wall clock: no RTC driver, init sets it from this
# DSU=2: no system image in memory at all -- the kernel starts from the small image, whose /sbin/launchd
# (userland/src/stage0dsu.c) mounts the system volume from the phone's storage, read as it is needed
# through the loader's block service (ufs=2: the DSU image is its partition "dsu", /dev/ufs_dsu)
if [ "${DSU:-0}" = 2 ]; then
	RESIDENT=""
	extra="$extra ufs=2"
	# (after such a run the loader has been seen to take 40 s and more before it answers again: wait for it)
	FAILS=${FAILS:-40}
	SLACK=${SLACK:-200}
fi
T() { timeout "$@"; }
stamp=$(date +%H%M%S)
LIVE=logs/$name-$stamp.log

# what the loader that is up holds: its own build and the resident image (forgotten at every reset)
STATE=logs/.dada-loader-state
loader_id=$(stat -f '%m %z' out/dada-usb.img 2>/dev/null)
if [ -f "$STATE" ] && [ "$(sed -n 1p "$STATE")" != "$loader_id" ]; then
	echo "the loader was rebuilt: starting it afresh"
	export FRESH=1
fi
# (shown as it happens, and kept for the checks below)
cycle_out=$(set -o pipefail; tools/dada-cycle.sh | tee /dev/stderr) || { rm -f "$STATE"; exit 1; }
# a loader that was not already up (or was reset) holds nothing yet
[ "$(echo "$cycle_out" | head -1)" = "phone: xnuloader" ] && [ "${FRESH:-0}" != 1 ] || rm -f "$STATE"

# RESIDENT=<image>: the big system image, uploaded once into the kernel's memory window (/dev/md0)
resident_id=""; [ -n "$RESIDENT" ] && resident_id="$RESIDENT $(stat -f '%m %z' "$RESIDENT")"
if [ -n "$RESIDENT" ] && [ -f "$STATE" ] && [ "$(sed -n 2p "$STATE")" = "$resident_id" ]; then
	echo "resident image $RESIDENT already in the loader"
elif [ -n "$RESIDENT" ] && [ "${DSU:-0}" = 1 ]; then
	# DSU=1: the image is on the phone already, installed as an Android DSU image (tools/dada-dsu.sh); the
	# loader reads it from the storage into the memory window (about 1.5 s for 5 GB) -- no USB upload
	t0=$(date +%s)
	size=$(stat -f %z "$RESIDENT")
	T 300 fastboot oem dsu load "$(printf %x "$size")" 2>&1 | grep -q OKAY || {
		echo "the loader could not read the DSU image (fastboot oem log for why)"; rm -f "$STATE"; exit 1; }
	echo "resident image read from the phone's storage (DSU) in $(( $(date +%s) - t0 )) s"
	if [ "${CRC:-1}" = 1 ]; then
		tools/dada-crc.sh "$RESIDENT" "${LIVE%.log}.crc-dsu" | tee /dev/stderr | grep -q 'the same' || {
			echo "the DSU image is not $RESIDENT: reinstall or patch it (tools/dada-dsu.sh)"; rm -f "$STATE"; exit 1; }
	fi
elif [ -n "$RESIDENT" ]; then
	t0=$(date +%s)
	# a fastboot download is at most 4 GB (32-bit size): a bigger image goes in pieces, each after the last
	# ("oem ramdisk append"); the pieces are kept beside the logs for as long as the image is the same
	pieces=("$RESIDENT")
	if [ "$(stat -f %z "$RESIDENT")" -gt 3221225472 ]; then
		P=logs/.resident-pieces
		if [ "$(cat $P/id 2>/dev/null)" != "$resident_id" ]; then
			rm -rf $P && mkdir -p $P
			split -b 3221225472 "$RESIDENT" $P/part.
			echo "$resident_id" > $P/id
		fi
		pieces=($P/part.*)
	fi
	first=1
	for piece in "${pieces[@]}"; do
		if [ $first = 1 ]; then cmd="oem ramdisk"; else cmd="oem ramdisk append"; fi
		T 15 fastboot $cmd 2>&1 | grep -q OKAY || { echo "the loader refused the resident image ($cmd)"; exit 1; }
		T 1800 fastboot stage "$piece" 2>&1 | grep -q OKAY || { echo "resident upload failed ($piece)"; exit 1; }
		first=0
	done
	echo "resident image $RESIDENT uploaded in $(( $(date +%s) - t0 )) s"
fi
printf '%s\n%s\n' "$loader_id" "$resident_id" > "$STATE"
# CRC=1: before the run, the loader's CRC-32 of each 256 MB of the resident image against this machine's
# (logs/<image>.crc): is what the kernel will see what was sent?
if [ "${CRC:-0}" = 1 ] && [ -n "$RESIDENT" ]; then
	tools/dada-crc.sh "$RESIDENT" "${LIVE%.log}.crc-before" || exit 1
fi
cp_arg=(); [ -n "$CHECKPOINT" ] && cp_arg=(--checkpoint "$CHECKPOINT")
python3 xnuloader/mkpayload.py -o out/dada-run-auto.bin kernel="$K" ramdisk="${ROOTIMG:-userland/hello}" "${cp_arg[@]}" \
    --cmdline "loader_return_after=$budget cpus=${CPUS:-1} bootcpu=${BOOTCPU:-2} debug=0x8 $extra" >/dev/null || exit 1
T 30 fastboot stage out/dada-run-auto.bin >/dev/null 2>&1 || { echo "stage failed"; exit 1; }
T 10 fastboot oem run 2>&1 | grep -q OKAY || T 10 fastboot oem run >/dev/null 2>&1
echo "run started: budget $budget s, log -> $LIVE"

fetch() {          # fetch <file>: the loader's log as it is now; 0 if it came back non-empty
	rm -f "$1.tmp"
	T 15 fastboot oem log >/dev/null 2>&1 || return 1
	T 20 fastboot get_staged "$1.tmp" >/dev/null 2>&1 || return 1
	[ -s "$1.tmp" ] || return 1
	mv "$1.tmp" "$1"
}

# the loader does not service USB while it loads and starts the kernel: leave it alone meanwhile
sleep ${WAIT0:-10}
result=""
fails=0
t=${WAIT0:-10}
limit=$((budget + ${SLACK:-40}))
while [ $t -lt $limit ]; do
	sleep ${POLL:-4}; t=$((t + ${POLL:-4}))
	r=$(T 10 fastboot getvar result 2>&1 | grep '^result:' | head -1)
	# "result:" with nothing after it is a loader that no longer knows what it ran: no answer either
	if [ -z "$r" ] || [ -z "$(echo "${r#result:}" | tr -d ' ')" ]; then
		r=""
		fails=$((fails + 1))
		echo "[$t s] no answer ($fails)"
		# the watchdog has already taken the phone back to Android: nothing more to wait for here
		if [ $fails -ge 2 ] && T 5 adb devices 2>/dev/null | grep -E -q "^${DADA_SERIAL:-[^[:space:]]+}[[:space:]]+device$"; then
			echo "[$t s] the phone is back in Android (the watchdog reset it)"
			gone=1
			break
		fi
		[ $fails -ge ${FAILS:-15} ] && break
		continue
	fi
	fails=0
	result=$r
	case "$r" in *running*) fetch "$LIVE" && crumb=$(grep -o 'crumb [0-9]*' "$LIVE" | tail -1) ;; esac
	# KEEP_POLLS=1: every live log kept (<log>.p<seconds>), not only the last -- with iOS up, the loader's 1 MB ring
	# turns over within seconds and a driver's lines from the middle of a run are in none but the polls of then
	[ "${KEEP_POLLS:-0}" = 1 ] && [ -s "$LIVE" ] && cp "$LIVE" "$LIVE.p$t"
	echo "[$t s] $r ${crumb:-}"
	# STOP_ON=<regex>: once the live log shows it, keep that log and end the run (no waiting out the budget)
	case "$r" in *running*)
		if [ -n "$STOP_ON" ] && [ -z "$stopped" ] && grep -a -E -q "$STOP_ON" "$LIVE" 2>/dev/null; then
			cp "$LIVE" "${LIVE%.log}.stop.log"
			echo "[$t s] the log shows /$STOP_ON/: ending the run (log kept in ${LIVE%.log}.stop.log)"
			T 15 fastboot oem stop >/dev/null 2>&1
			stopped=1
		fi ;;
	esac
	case "$r" in *running*) ;; *) break ;; esac
done
if [ "${gone:-0}" = 1 ]; then
	rm -f "$STATE"
	echo "== result: the kernel stopped the phone (watchdog reset); log: $LIVE ($(wc -c < "$LIVE" 2>/dev/null || echo 0) bytes)"
	tail -5 "$LIVE" 2>/dev/null
	exit 3
fi
# once the kernel has returned, the loader's log is its own (32 KB), not the kernel's: keep it beside the live one
# what the loader put together when the kernel came back -- its own log, the kernel's whole log and, after a
# panic, the panic buffer with the backtrace -- is still staged: take it as it is, before "oem log" replaces it
T 30 fastboot get_staged "$LIVE.full" >/dev/null 2>&1 && [ -s "$LIVE.full" ] || rm -f "$LIVE.full"
fetch "$LIVE.after"
[ -s "$LIVE" ] || mv "$LIVE.after" "$LIVE" 2>/dev/null
# the last picture iOS drew (the loader leaves the screen alone after the return)
case "$result" in *returned*) tools/dada-screenshot.sh "${LIVE%.log}.png" 2>&1 | sed 's/^/screen: /' ;; esac
# a screen recording (boot-arg rec_secs=N): staged by the loader, fetched, made a video (tools/recording.py)
case "$result:$extra" in *returned*rec_secs=*)
	if T 30 fastboot oem recording 2>&1 | grep -q OKAY && T 300 fastboot get_staged "${LIVE%.log}.rec" >/dev/null 2>&1; then
		echo "recording: ${LIVE%.log}.rec ($(wc -c < "${LIVE%.log}.rec") bytes)"
		python3 tools/recording.py "${LIVE%.log}.rec" "${LIVE%.log}.mp4" --frames "${LIVE%.log}-frames" 2>&1 | tail -1
	else
		echo "recording: not fetched"
	fi ;;
esac
# the render server's pipeline-cache export (boot-arg gpu_export_mb=N, RedwoodGPU): staged in the recording's place, fetched for
# ~/hakios-gpu2/tools/m2vpack.py to bake into the next image
case "$result:$extra" in *returned*gpu_export_mb=*)
	case " $extra " in *" rec_secs=0 "*|*" rec_secs=0"*) rec_on=0 ;; *rec_secs=*) rec_on=1 ;; *) rec_on=0 ;; esac
	case "$rec_on" in 1) echo "pipeline cache: not fetched (the recording has the loader's slot)" ;; *)
	if T 30 fastboot oem recording 2>&1 | grep -q OKAY && T 300 fastboot get_staged "${LIVE%.log}.m2vexp" >/dev/null 2>&1; then
		echo "pipeline cache: ${LIVE%.log}.m2vexp ($(wc -c < "${LIVE%.log}.m2vexp") bytes)"
	else
		echo "pipeline cache: not fetched"
	fi ;; esac ;;
esac
echo "== result: ${result:-unknown}; log: $LIVE ($(wc -c < "$LIVE" 2>/dev/null || echo 0) bytes)"
grep -E '== PANIC|hakios|STOPPED|EARLY KERNEL' "$LIVE" 2>/dev/null | head -20

back=0
case "$result" in *running*|"") came_back=0 ;; *) came_back=1 ;; esac
if [ "${KEEP:-0}" = 0 ] || [ $fails -ge ${FAILS:-15} ] || { [ "${KEEP:-0}" = auto ] && [ $came_back = 0 ]; }; then
	rm -f "$STATE"
	echo "resetting the phone (watchdog)"
	T 15 fastboot oem stop >/dev/null 2>&1       # a kernel still running makes the loader refuse the rest
	T 10 fastboot oem hang >/dev/null 2>&1
	i=0
	while [ $i -lt 300 ]; do
		T 8 adb devices 2>/dev/null | grep -E -q "^${DADA_SERIAL:-[^[:space:]]+}[[:space:]]+device$" && { echo "phone back in Android after ~$i s"; back=1; break; }
		sleep 5; i=$((i + 5))
	done
	[ $back = 1 ] || { echo "phone not back in Android after 300 s"; exit 2; }
else
	echo "loader left up for the next run"
fi
