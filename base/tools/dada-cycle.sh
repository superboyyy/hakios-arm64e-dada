#!/bin/bash
# Bring dada to a resident xnuloader, from wherever it is: Android, the bootloader, or already there.
# Every step is bounded; exits non-zero (and says why) if the phone does not get there.
H=$(cd "$(dirname "$0")/.." && pwd)
IMG=${IMG:-$H/out/dada-usb.img}
T() { timeout "$@"; }

state() {
	# (with DADA_SERIAL set, only that device counts: an emulator on the same machine is always "device". Not ANDROID_SERIAL:
	# fastboot honours that too, and the loader's serial is "xnuloader")
	if T 8 adb devices 2>/dev/null | grep -E "^${DADA_SERIAL:-[^[:space:]]+}[[:space:]]+device$" -q; then echo android; return; fi
	local fb
	fb=$(T 8 fastboot devices 2>/dev/null)
	if [ -n "$fb" ]; then
		local p
		p=$(T 8 fastboot getvar product 2>&1 | grep '^product:')
		case "$p" in
		*xnuloader*) echo xnuloader ;;
		"") echo wedged ;;          # on the bus but not answering: a loader whose USB is stuck
		*) echo bootloader ;;
		esac
		return
	fi
	echo none
}

wait_for() {        # wait_for <state> <seconds>
	local i=0
	while [ $i -lt "$2" ]; do
		[ "$(state)" = "$1" ] && return 0
		sleep 3; i=$((i + 3))
	done
	return 1
}

s=$(state)
echo "phone: $s"
if [ "$s" = xnuloader ] && [ "${FRESH:-0}" = 1 ]; then
	echo "fresh loader asked for: resetting through the watchdog"
	T 10 fastboot oem hang >/dev/null 2>&1
	wait_for android 240 || { echo "phone did not come back to Android"; exit 1; }
	s=android
fi
if [ "$s" = wedged ]; then
	echo "loader not answering: waiting for the watchdog to reset the phone"
	wait_for android 330 || { echo "phone did not come back to Android"; exit 1; }
	s=android
fi
if [ "$s" = none ]; then
	echo "phone not on USB: waiting for it (watchdog reset or boot in progress)"
	i=0
	while [ $i -lt 240 ]; do
		s=$(state); [ "$s" != none ] && break
		sleep 5; i=$((i + 5))
	done
	echo "phone: $s"
	[ "$s" = none ] && { echo "phone did not appear"; exit 1; }
fi
if [ "$s" = android ]; then
	T 15 adb ${DADA_SERIAL:+-s $DADA_SERIAL} reboot bootloader
	wait_for bootloader 60 || { echo "bootloader did not appear"; exit 1; }
	s=bootloader
fi
if [ "$s" = bootloader ]; then
	T 30 fastboot boot "$IMG" 2>&1 | tail -1
	wait_for xnuloader 60 || { echo "xnuloader did not appear"; exit 1; }
fi
echo "phone: xnuloader ready"
