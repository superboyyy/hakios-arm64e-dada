#!/bin/bash
# iOS 26 on the Xiaomi 15 (dada) with everything that works so far, in one line:
#   tools/dada-ios.sh [name] [seconds] [more boot-args...]
#
#   display     the panel through the loader's framebuffer (fbwidth/fbheight)
#   touch       the Synaptics screen (dadatouch=1)
#   buttons     power, volume up, volume down (dadabuttons=1: SPMI arbiter v7, read only)
#   GPU         the Adreno 830, kept for the system (dadagpu=6 dadagpu_keep=1), and the window server
#               compositing through Metal on it (metal=1 metal_profile=1 metal_procs=backboardd), with
#               CoreAnimation's inline SDFs off (they draw black through our compiler: CA_DISABLE_INLINE_SDFS)
#   audio DSP   started and linked (adsp=1 dadaadsp=1): GLINK, QRTR, the charge manager
#   battery     the charge manager's voltage, current, temperature and charging state, the fuel gauge's
#               percentage and capacities (dadagauge=1), into iOS's power source
#   CPU         all 8 cores (the loader offers the two prime cores, MPIDR 0x10000/0x10100; CPUS=8) at their
#               sustained clocks through SCMI (dadacpu=2: 3.53 GHz and 4.09 GHz; the boot loader left 1.99 GHz)
#   sound       the speakers: the two CS35L43 amplifiers (dadaamp=1) and the audio DSP's AudioReach graphs
#               (dadaaudio=2, hakios_dada_audio.c) behind /dev/redwood-audio, iOS's HAL plug-in
#   Bluetooth   the WCN7850-family part over the UART (rampatch, NVM, HCI reset), given to iOS's bluetoothd through
#               com.apple.uart.sk.bluetooth (dadabt=4, exec_env/exec_swap, our BlueTool; verified w94z3: PoweredOn, LE scan)
#   microphone  the WCD9395's analog mics over SoundWire into the TX macro, /dev/redwood-mic while iOS records (dadamic=3)
#   Wi-Fi       NOT by default: dadawifi=4 (ath12k as QCC2072) brings peach up -- MHI, QMI, the cold-boot
#               calibration, firmware ready, WMI -- and has scanned (runs wifi27..wifi29: 30, 38, 32 networks), but
#               most runs the firmware dies at its first radio work (the vdev, the first scan); see memory dada-wifi-bt.
#               Pass dadawifi=4 FIRST on the command line to try it (the first of a boot-arg wins)
#
# The image: (cd userland && ADSP=1 REST=1 OSLOG="" IOS=../ios26pro ARCH=arm64e \
#   CACHE=../ios26pro/23G90__iPhone18,1 RC=rc.launchd26.ca ./build.sh)   -- ADSP=1 puts the audio DSP's
# firmware (fw-adsp-dada/) into the small image. The phone reboots by itself (tools/dada-run.sh).
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
name=${1:-ios}
seconds=${2:-120}
shift 2 2>/dev/null
exec env DSU=2 CPUS=${CPUS:-8} ROOTIMG=userland/root.apfs tools/dada-run.sh "$name" "$seconds" \
	rd=md0 fbwidth=1206 fbheight=2622 vm_compression_limit=262144 \
	dadatouch=1 dadabuttons=1 \
	dadagpu=6 dadagpu_keep=1 metal=1 metal_profile=1 metal_procs=backboardd \
	caenv=CA_DISABLE_FILTER_MERGING=1 caenv=CA_DISABLE_TILE_SHADERS=1 caenv=CA_DISABLE_INLINE_SDFS=1 \
	adsp=1 dadaadsp=1 dadagauge=1 dadaamp=1 dadaaudio=2 dadacpu=3 dadascan=1 \
	dadawifi=1 dadabt=4 'exec_env=bluetoothd:BT_HCI_TRANSPORT=H4:POSIX;BT_CHIP=ACI~BT' \
	exec_swap=BlueTool:/redwood/bin/bluetool btnolpcore=1 dadabt_fake=0x2074,0x207d,0x2031,0x2024,0x204a \
	dadamic=3 \
	"$@"
