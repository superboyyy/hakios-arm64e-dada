#!/bin/bash
# Build for dada: "loader" (xnuloader + USB boot image), "kernel" (xnu-12377 arm64e), or both.
set -e
H=$(cd "$(dirname "$0")/.." && pwd)
S=${XNU12377:-$HOME/hakios-gpu2/xnu12377}
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH
what=${1:-both}

if [ "$what" = loader ] || [ "$what" = both ]; then
	cd "$H/xnuloader"
	clang --target=aarch64-unknown-windows -ffreestanding -fno-builtin -fno-stack-protector -fshort-wchar \
	    -mgeneral-regs-only -O1 -Wall -Wextra -Wno-unused-parameter -DPAYLOAD_BASE=0xA8000000ULL -DPAYLOAD_MAX_SIZE=0x10000000ULL \
	    -c loader.c -o loader-dada.obj
	lld-link /subsystem:efi_application /entry:efi_main /nodefaultlib /base:0xA1000000 /out:loader-dada.efi loader-dada.obj
	cd "$H"
	python3 xnuloader/mkpayload.py -o out/dada-usb-payload.bin loader.efi=xnuloader/loader-dada.efi --usb
	docker run --rm -v "$H":/work -v $HOME/dada-uefi-build:/work/Mu-Silicium -w /work hakios-uefi bash -lc \
	    'export UEFI_TARGET=dada FD_BASE=0xA7100000 FD_SIZE=0x300000 PAYLOAD_BASE=0xA8000000 HEADER_VERSION=4; python3 mkxnuimg.py -p out/dada-usb-payload.bin -o out/dada-usb.img' | tail -1
fi
if [ "$what" = kernel ] || [ "$what" = both ]; then
	cd "$H"
	# dada's Wi-Fi driver object (peach ath12k); linked into the kernel by xnu-build.sh when it is there
	if [ -d "$H/xnu-deps/build/ath12k/deps/linux" ] || [ "$WIFI" = 1 ]; then
		"$H/tools/mk-ath12k.sh" || { echo "ath12k build failed"; exit 1; }
	fi
	L=$(dirname "$S")/xnu12377-build.log
	XNU_SRC=$S XNU_ARCH=arm64e MACHINE=BCM2837 RC_DARWIN_KERNEL_VERSION=12377.121.6 ./xnu-build.sh -j10 -k > "$L" 2>&1 || { grep -m5 "error:" "$L"; echo "kernel build failed (see $L)"; exit 1; }
	if grep -n 'error:' "$L" | grep -v kextsymboltool; then
		echo "kernel build: errors (see $L)"
		exit 1
	fi
	ls -laL "$S/BUILD/obj/mach.development.bcm2837" | awk '{print "kernel:", $5, $6, $7, $8}'
fi
