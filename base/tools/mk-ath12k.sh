#!/bin/bash
# Build the driver of dada's (Xiaomi 15) Wi-Fi chip for our arm64e kernel: Linux's ath12k with the MHI host, QMI and
# QRTR it needs, on UniXNU's Ath12kWifi runtime (a single dispatcher that runs the driver's work, timers and polled
# interrupts, a mac80211 subset and a WPA2 station). Nothing of either is kept in this repository; both are fetched at
# pinned revisions into xnu-deps/build/ath12k:
#
#   Linux v7.0.14            drivers/net/wireless/ath/ath12k (BSD-3-Clause-Clear), drivers/bus/mhi/host, the QMI
#                            library (drivers/soc/qcom/qmi_*.c) and the public headers they include
#   UniXNU/Ath12kWifi        its shim headers and runtime (shim/), the station, QRTR and PCI glue (src/), the board
#                            boundary (include/nw_abi.h), at commit ATH12KWIFI below
#
# The chip is Qualcomm's "peach" (WCN7880, FastConnect 7900, PCI 17cb:110e), which Linux does not know. What it is
# made of, from Qualcomm's own sources (wlan/platform cnss2, qca-wifi-host-cmn hal/wifi3.0, fw-api hw/peach):
#   - its UMAC (REO, TCL, WBM ring registers) is QCC2072's register for register, as is its RX descriptor, and its
#     register window is at 0x3278 as QCC2072's: it is driven as a QCC2072 (ATH12K_HW_QCC2072_HW10);
#   - its SoC map (GCC at 0x1e40000, PCIe wrapper) is WCN7850's: the PCIe hot reset is GCC + 0x304, 0x1e40304;
#   - Android runs it on an external 32 kHz sleep clock (no qcom,sleep-clk-support in dada's device tree);
#   - its files: amss.bin / amss20.bin by chip revision, phy_ucode.elf for "m3.bin", aux_ucode.elf, board data
#     bdwlan.e<board id> (ELF), regdb.bin. The kernel's lx_platform.fw_get does the renaming
#     (bsd/dev/hakios_dada_ath12k.c); the board file name is made here, in core.c.
# Ath12kWifi's own changes for WCN7850 boards (smaller RX rings, the WMI wait, MLO fields in the host capability
# message, on-demand host memory, the address of a radio without one, the scan link, the reorder queue descriptors in
# DMA memory, the RX refill, unknown events shown, HTT stats logged, the MHI pre-load hook) are made again below.
#
# Everything is compiled as arm64e kernel code (-mkernel) and tied into one object that shows only nw_wifi_*; the
# kernel links it when it is there (xnu-build.sh, REDWOOD_LX).
#
# usage: tools/mk-ath12k.sh [fetch]
set -e
LINUX=v7.0.14
ATH12KWIFI=f6bf561f92cc42761bdd417fce1d53fe1db9477c
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
B=$ROOT/xnu-deps/build/ath12k
mkdir -p "$B"
cd "$B"

# --- the sources
if [ ! -f deps/linux/drivers/net/wireless/ath/ath12k/core.c ]; then
	rm -rf deps/linux
	mkdir -p deps
	git clone -q --depth 1 --branch $LINUX --filter=blob:none --sparse \
		https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git deps/linux
	git -C deps/linux sparse-checkout set --no-cone /drivers/net/wireless/ath/ /drivers/bus/mhi/ /include/ \
		/drivers/soc/qcom/qmi_interface.c /drivers/soc/qcom/qmi_encdec.c
fi
if [ "$(git -C ath12kwifi rev-parse HEAD 2>/dev/null)" != "$ATH12KWIFI" ]; then
	rm -rf ath12kwifi
	git clone -q https://github.com/UniXNU/Ath12kWifi.git ath12kwifi
	git -C ath12kwifi checkout -q $ATH12KWIFI
fi
[ "$1" = fetch ] && { echo "mk-ath12k.sh: sources in $B"; exit 0; }
L=$B/deps/linux
A=$L/drivers/net/wireless/ath/ath12k
W=$B/ath12kwifi

# --- the trees the sources are compiled from: public headers as they are (pinned/), the driver's and MHI's files as
# links, those that are changed as copies
rm -rf gen
mkdir -p gen/pinned/linux/soc/qcom gen/pinned/net gen/pinned/uapi/linux gen/ath12k-src/wifi7 gen/mhi-src
for h in linux/mhi.h linux/ieee80211.h linux/soc/qcom/qmi.h net/cfg80211.h net/regulatory.h net/codel.h \
	net/ieee80211_radiotap.h; do
	ln -s $L/include/$h gen/pinned/$h
done
for f in $L/include/linux/ieee80211-*.h; do ln -s $f gen/pinned/linux/; done
ln -s $L/include/uapi/linux/nl80211.h gen/pinned/linux/nl80211.h
ln -s $L/include/uapi/linux/rfkill.h gen/pinned/linux/rfkill.h
ln -s $L/include/uapi/linux/rfkill.h gen/pinned/uapi/linux/rfkill.h
ln -s $L/include/net/mac80211.h gen/pinned/net/mac80211.real.h
for f in $A/*.c $A/*.h; do ln -s $f gen/ath12k-src/; done
for f in $A/wifi7/*.c $A/wifi7/*.h; do ln -s $f gen/ath12k-src/wifi7/; done
rm gen/ath12k-src/trace.h
{
	echo '#ifndef LX_ATH12K_TRACE_H'
	echo '#define LX_ATH12K_TRACE_H'
	grep -ohE "trace_ath12k_[a-z_0-9]+" $A/*.c $A/*.h $A/wifi7/*.c | sort -u | sed 's/.*/#define &(...) ((void)0)/'
	echo '#endif'
} > gen/ath12k-src/trace.h
H=$L/drivers/bus/mhi/host
for f in $H/*.c $H/internal.h; do ln -s $f gen/mhi-src/; done
cp $W/shim/mhi/trace.h gen/mhi-src/trace.h
ln -s $L/drivers/bus/mhi/common.h gen/common.h

# change FILE (relative to gen/) with the python below: every edit must find its mark exactly once
edit() {
	local f=gen/$1
	local src
	src=$(readlink "$f" || true)
	[ -n "$src" ] && { rm "$f"; cp "$src" "$f"; }
	python3 -I -c "$2" "$f"
}
PY_HEAD='import sys
p = sys.argv[1]; s = open(p).read()
def sub(old, new, n=1):
    global s
    assert s.count(old) == n, "%s: mark not found %d times: %r" % (p, n, old[:60])
    s = s.replace(old, new)
'
PY_TAIL='
open(p, "w").write(s)'

# 1. the RX refill ring and the MAC rings: 512 and 128 buffers (the DMA window is small; a MAC that receives nothing
#    must not hoard the buffers)
edit ath12k-src/dp.h "$PY_HEAD
sub('#define DP_RXDMA_BUF_RING_SIZE\t\t4096', '#define DP_RXDMA_BUF_RING_SIZE\t\t512')
sub('#define DP_RX_MAC_BUF_RING_SIZE\t\t2048', '#define DP_RX_MAC_BUF_RING_SIZE\t\t128')$PY_TAIL"

# 2. ath12k_wmi_cmd_send's wait has the sending as its condition: evaluated once per round, never after it succeeded;
#    an event the driver does not know is shown whole
edit ath12k-src/wmi.c "$PY_HEAD
i = s.index('int ath12k_wmi_cmd_send('); j = s.index('\n}\n', i)
assert s[i:j].count('wait_event_timeout(') == 1
s = s[:i] + s[i:j].replace('wait_event_timeout(', 'wait_event_timeout_once(') + s[j:]
sub('\t\tath12k_dbg(ab, ATH12K_DBG_WMI, \"Unknown eventid: 0x%x\\\\n\", id);\n',
    '\t\tath12k_dbg(ab, ATH12K_DBG_WMI, \"Unknown eventid: 0x%x\\\\n\", id);\n'
    '\t\tath12k_dbg_dump(ab, ATH12K_DBG_WMI, NULL, \"\", skb->data, skb->len);\n')$PY_TAIL"

# 3. hw.c: no radio switch on WCN7850 boards; peach (driven as QCC2072) on the board's sleep clock
edit ath12k-src/wifi7/hw.c "$PY_HEAD
sub('\t\t.rfkill_pin = 48,', '\t\t.rfkill_pin = 0,')
# (the chip's own sleep clock instead changed nothing: run wifi39, 28 October; Android's DT has no qcom,sleep-clk-support)
i = s.index('.name = \"qcc2072 hw1.0\"')
j = s.index('.internal_sleep_clock = true,', i)
s = s[:j] + '.internal_sleep_clock = false,\t/* peach: dada runs it on the PMIC sleep clock */' + s[j + len('.internal_sleep_clock = true,'):]$PY_TAIL"

# 4. qmi.c / qmi.h: the MLO fields always in the host capability message (the firmware sizes its MLO peers by them);
#    host memory on demand offered (TLV 0x33) and the firmware's answer to it read (TLV 0x17)
edit ath12k-src/qmi.c "$PY_HEAD
sub('\tif (!ag->mlo_capable) {\n\t\tath12k_dbg(ab, ATH12K_DBG_QMI,\n\t\t\t   \"MLO is disabled hence skip QMI MLO cap\");\n\t\treturn 0;\n\t}\n\n', '')
def elem(tlv, struct, field, flag):
    return ('\t{\n\t\t.data_type\t= %s,\n\t\t.elem_len\t= 1,\n\t\t.elem_size\t= sizeof(u8),\n\t\t.array_type\t= NO_ARRAY,\n'
            '\t\t.tlv_type\t= %s,\n\t\t.offset\t\t= offsetof(%s, %s),\n\t},\n'
            % ('QMI_OPT_FLAG' if flag else 'QMI_UNSIGNED_1_BYTE', tlv, struct, field + ('_valid' if flag else '')))
for mark, tlv, struct, field in (('\t\t\t\t\t   feature_list),\n\t},\n', '0x33', 'struct qmi_wlanfw_host_cap_req_msg_v01', 'nw_on_demand_mem'),
                                 ('\t\t\t\t\t   single_chip_mlo_support),\n\t},\n', '0x17', 'struct qmi_wlanfw_phy_cap_resp_msg_v01', 'nw_on_demand_ddr')):
    sub(mark, mark + elem(tlv, struct, field, True) + elem(tlv, struct, field, False))
old = '\tif (resp.single_chip_mlo_support_valid && resp.single_chip_mlo_support)\n\t\tab->single_chip_mlo_support = true;\n'
sub(old, old + '\tnw_on_demand_ddr = resp.nw_on_demand_ddr_valid && resp.nw_on_demand_ddr;\n')
old = '\tret = ath12k_host_cap_parse_mlo(ab, &req);\n'
sub(old, '\treq.nw_on_demand_mem_valid = 1;\n\treq.nw_on_demand_mem = 1;\n\n' + old)
sub('#include \"qmi.h\"\n', '#include \"qmi.h\"\n\nstatic u8 nw_on_demand_ddr;\t/* the firmware takes host memory on demand */\n')$PY_TAIL"
edit ath12k-src/qmi.h "$PY_HEAD
sub('\tu64 feature_list;\n\n};', '\tu64 feature_list;\n\tu8 nw_on_demand_mem_valid;\n\tu8 nw_on_demand_mem;\n};')
sub('\tu8 single_chip_mlo_support;\n};', '\tu8 single_chip_mlo_support;\n\tu8 nw_on_demand_ddr_valid;\n\tu8 nw_on_demand_ddr;\n};')
sub('QMI_WLANFW_HOST_CAP_REQ_MSG_V01_MAX_LEN\t\t261', 'QMI_WLANFW_HOST_CAP_REQ_MSG_V01_MAX_LEN\t\t265')
sub('QMI_WLANFW_PHY_CAP_RESP_MSG_V01_MAX_LEN\t\t18', 'QMI_WLANFW_PHY_CAP_RESP_MSG_V01_MAX_LEN\t\t22')$PY_TAIL"

# 5. mac.c: a radio whose address is not valid, or the chip maker's random default (00:03:7f:..), takes the board's
#    (nw_board_mac: wlan_mac.bin); a station without links scans on its own link
edit ath12k-src/mac.c "$PY_HEAD
old = '\t\t\tar->mac_addr[4] += ar->pdev_idx;\n\t\t}\n'
sub(old, old + '\t\tif (!is_valid_ether_addr(ar->mac_addr) ||\n\t\t    (!ar->mac_addr[0] && ar->mac_addr[1] == 0x03 && ar->mac_addr[2] == 0x7f)) {\n'
    '\t\t\tnw_board_mac(ar->mac_addr);\n\t\t\tar->mac_addr[4] += ar->pdev_idx;\n\t\t}\n')
sub('#include \"mac.h\"\n', '#include \"mac.h\"\nvoid nw_board_mac(u8 *a);\n')
old = '\tscan_links_map = ~ahvif->links_map & ATH12K_SCAN_LINKS_MASK;\n'
sub(old, '\tif (!ahvif->links_map)\n\t\treturn 0;\n' + old)$PY_TAIL"

# 6. the RX reorder queue descriptors, which the chip reads, in DMA memory; buffers taken from a destination ring go
#    back to the refill ring even when none completed a frame
edit ath12k-src/wifi7/dp_rx.c "$PY_HEAD
sub('vaddr = kzalloc(hw_desc_sz + HAL_LINK_DESC_ALIGN - 1, GFP_ATOMIC);', 'vaddr = lx_dma_zalloc(hw_desc_sz + HAL_LINK_DESC_ALIGN - 1);')
old = ('\tif (!total_msdu_reaped)\n\t\tgoto exit;\n\n\tfor (device_id = 0; device_id < ATH12K_MAX_DEVICES; device_id++) {\n'
       '\t\tif (!num_buffs_reaped[device_id])\n\t\t\tcontinue;\n\n\t\tpartner_dp = ath12k_dp_hw_grp_to_dp(dp_hw_grp, device_id);\n'
       '\t\trx_ring = &partner_dp->rx_refill_buf_ring;\n\n\t\tath12k_dp_rx_bufs_replenish(partner_dp,')
sub(old, old.replace('\tif (!total_msdu_reaped)\n\t\tgoto exit;\n\n', ''))
sub('exit:\n\treturn total_msdu_reaped;', '\treturn total_msdu_reaped;')$PY_TAIL"
edit ath12k-src/dp_rx.c "$PY_HEAD
sub('\t\tkfree(tid_qbuf->vaddr);', '\t\tlx_dma_kfree(tid_qbuf->vaddr);')$PY_TAIL"

# 7. the firmware's extended statistics to the log (no debugfs)
edit ath12k-src/dp_htt.c "$PY_HEAD
sub('\t\tath12k_debugfs_htt_ext_stats_handler(ab, skb);',
    '\t\t{ extern void nw_htt_ext_stats(struct ath12k_base *, struct sk_buff *); nw_htt_ext_stats(ab, skb); }')$PY_TAIL"

# 8. MHI: the boot loader gets its contexts (and time after the reset) before the image is offered
edit mhi-src/boot.c "$PY_HEAD
old = '\tret = request_firmware(&firmware, fw_name, dev);'
sub(old, '\t{ extern void nw_mhi_pre_load(struct mhi_controller *); nw_mhi_pre_load(mhi_cntrl); }\n' + old)$PY_TAIL"

# 8b. qmi.c: the AUX step non-fatal, in cnss2's order (after M3). Calibration is NOT reported done (cal_done stays
#     ath12k's 0): Android's cnss2 says done only on its second boot, after a cold-boot calibration boot ("Calibration
#     took 5540 ms") whose results stay in the firmware's memory segments. Saying done without one left the firmware
#     with no calibration, and it hung hard at the first use of the radio (vdev create / first scan) in 4 runs of 5
#     (wifi23..wifi27, 28 October). (The M3/AUX refusals of wifi12..wifi17 were the feature list, step 8c.)
edit ath12k-src/qmi.c "$PY_HEAD
sub('\t\t\tath12k_warn(ab, \"qmi failed to send aux_uc info req: %d\\\\n\", ret);\n\t\t\treturn ret;\n',
    '\t\t\tath12k_warn(ab, \"qmi failed to send aux_uc info req: %d (going on without it)\\\\n\", ret);\n\t\t\tret = 0;\n')$PY_TAIL"

# 8c. hw.c: the host capability's feature list as Android's cnss2 sends it for peach: the AUX microcode bit and
#     nothing else (cnss2 main.c: CNSS_AUX_UC_SUPPORT_V01 for PEACH/COLOGNE/FIG; dada's DT has no rc-ep-short-channel).
#     With QDSS_CFG_MISS and PCIE_PERST_NO_PULL as well the firmware said "ready" after the first of M3/AUX
edit ath12k-src/wifi7/hw.c "$PY_HEAD
i = s.index('.name = \"qcc2072 hw1.0\"')
old = ('.qmi_cnss_feature_bitmap = BIT(CNSS_QDSS_CFG_MISS_V01) |\n\t\t\t\t\t   BIT(CNSS_PCIE_PERST_NO_PULL_V01) |\n'
       '\t\t\t\t\t   BIT(CNSS_AUX_UC_SUPPORT_V01),')
j = s.index(old, i)
s = s[:j] + '.qmi_cnss_feature_bitmap = BIT(CNSS_AUX_UC_SUPPORT_V01),\t/* as cnss2 for peach */' + s[j + len(old):]$PY_TAIL"

# 8e. qmi.c: host memory on demand NOT offered: Android's cnss2 sends no TLV 0x33 in its host capability (its IDL ends at
#     0x31, gpio_config), and with it offered peach's firmware stopped answering WMI -- no more credits -- a few commands
#     after the first vdev (runs wifi24/wifi25, "htc insufficient credits" until "wmi command 20488 timeout")
edit ath12k-src/qmi.c "$PY_HEAD
sub('\treq.nw_on_demand_mem_valid = 1;\n\treq.nw_on_demand_mem = 1;\n', '\t/* host memory on demand: not offered, as cnss2 does not (tools/mk-ath12k.sh 8e) */\n')$PY_TAIL"

# 8d. qmi.c: the QDSS trace configuration after AUX, as cnss2 sends it (tools/ath12k-qdss.py says why)
python3 -I "$ROOT/tools/ath12k-qdss.py" gen/ath12k-src/qmi.c

# 8f. qmi.h/qmi.c: the firmware's OL CPR table (target capabilities, TLV 0x22) said as "ol cpr: PIN wake MV sleep MV"
#     lines, which hakios_dada_wifi.c turns into its RPMh votes (what cnss2 hands AOP)
for f in qmi.h qmi.c; do src=$(readlink gen/ath12k-src/$f || true); [ -n "$src" ] && { rm gen/ath12k-src/$f; cp "$src" gen/ath12k-src/$f; }; done
python3 -I "$ROOT/tools/ath12k-olcpr.py" gen/ath12k-src/qmi.h gen/ath12k-src/qmi.c

# 8g. qmi.c: the cold-boot calibration before the boot that is used, as cnss2 does it (tools/ath12k-cbc.py says why)
python3 -I "$ROOT/tools/ath12k-cbc.py" gen/ath12k-src/qmi.c

# 8h. MHI pm.c: mhi_power_down waits for its disable transition with flush_work, which this port defines as a cancel; the
#     transition stayed queued and was the first thing the state worker did at the next power up ("Processing disable
#     transition" right after "Power on setup success", run wifi36). Run it here, as Linux's flush_work would.
edit mhi-src/pm.c "$PY_HEAD
sub('\t/* Wait for shutdown to complete */\n\tflush_work(&mhi_cntrl->st_worker);\n',
    '\t/* Wait for shutdown to complete (this port: flush_work cancels; the transition is run here) */\n'
    '\tif (cancel_work_sync(&mhi_cntrl->st_worker))\n\t\tmhi_cntrl->st_worker.func(&mhi_cntrl->st_worker);\n')$PY_TAIL"

# 9. peach (17cb:110e): probed as a QCC2072
edit ath12k-src/wifi7/pci.c "$PY_HEAD
sub('#define QCC2072_DEVICE_ID\t\t0x1112\n', '#define QCC2072_DEVICE_ID\t\t0x1112\n#define PEACH_DEVICE_ID\t\t\t0x110e\t/* WCN7880: QCC2072 inside */\n')
sub('\t{ PCI_VDEVICE(QCOM, QCC2072_DEVICE_ID) },\n', '\t{ PCI_VDEVICE(QCOM, QCC2072_DEVICE_ID) },\n\t{ PCI_VDEVICE(QCOM, PEACH_DEVICE_ID) },\n')
sub('\tcase QCC2072_DEVICE_ID:\n\t\tab->id.bdf_search', '\tcase QCC2072_DEVICE_ID:\n\tcase PEACH_DEVICE_ID:\n\t\tab->id.bdf_search')$PY_TAIL"

# 10. ... with WCN7850's GCC: the PCIe hot reset at 0x1e40304
edit ath12k-src/wifi7/hal_qcc2072.c "$PY_HEAD
sub('.gcc_gcc_pcie_hot_rst = 0x1e65304,', '.gcc_gcc_pcie_hot_rst = 0x1e40304,\t/* peach: GCC at 0x1e40000 (fw-api hw/peach msmhwiobase.h) */')$PY_TAIL"

# 11. ... and its board data by Android's names before board.bin: bdwlan.e<id> (an ELF), bdwlan<hi>.e<lo> for ids
#     above 0xff, bdwlan.elf (cnss2 qmi.c cnss_get_bdf_file_name)
edit ath12k-src/core.c "$PY_HEAD
old = '\tbd_api = 1;\n\tret = ath12k_core_fetch_board_data_api_1(ab, bd, ATH12K_DEFAULT_BOARD_FILE);\n'
sub(old, '\tbd_api = 1;\n\t{\n\t\tchar peach[24];\n\t\tu32 id = ab->qmi.target.board_id;\n\n'
    '\t\tif (id < 0xff)\n\t\t\tsnprintf(peach, sizeof(peach), \"bdwlan.e%02x\", id);\n'
    '\t\telse if (id == 0xff)\n\t\t\tsnprintf(peach, sizeof(peach), \"bdwlan.elf\");\n'
    '\t\telse\n\t\t\tsnprintf(peach, sizeof(peach), \"bdwlan%02x.e%02x\", (id >> 8) & 0xff, id & 0xff);\n'
    '\t\tath12k_info(ab, \"board data: board id 0x%x, %s\\\\n\", id, peach);\n'
    '\t\tif (!ath12k_core_fetch_board_data_api_1(ab, bd, peach) ||\n'
    '\t\t    !ath12k_core_fetch_board_data_api_1(ab, bd, \"bdwlan.elf\"))\n\t\t\tgoto success;\n\t}\n'
    + old.replace('\tbd_api = 1;\n', ''))$PY_TAIL"

# 12. A firmware that stops answering is restarted, not given up on. On dada the firmware dies at its first radio work in
#     most boots (the WMI credits stop after the first vdev; nothing the host sends differs from the boots that work, see
#     memory dada-wifi-bt), so a run lives or dies by one throw. The driver has its own recovery for a crashed firmware
#     (ath12k_core_reset: power down, power up, the firmware's boot and QMI again, then ieee80211_restart_hw); the runtime
#     never started it (a hang is no crash: no SYS_ERR), and its ieee80211_restart_hw was empty. Now: the stuck detector
#     (nw_wifi.c, a WMI command timeout) queues the reset, at most NW_RESTARTS_MOST times, and asks for the RAM dump only
#     after the last; the wireless stack's half of a restart is done as mac80211 does it (start, the interface added
#     again -- the driver clears its own part of it -- reconfig_complete), then a scan from scratch (nw_sta_restart).
#     These three files of the runtime are compiled from copies in gen/src.
mkdir -p gen/src
cp $W/src/nw_wifi.c $W/src/nw_mac80211.c $W/src/nw_sta.c gen/src/
edit src/nw_wifi.c "$PY_HEAD
sub('static void wmi_stuck(void) {\n',
    '/* the driver restarts a firmware that stopped answering (tools/mk-ath12k.sh 12), this many times at most */\n'
    '#define NW_RESTARTS_MOST 6\nstatic int g_restarts;\n'
    '/* the chip power-cycled before the driver\\'s reset touches it (tools/mk-ath12k.sh 14) */\n'
    'void hakios_dada_wifi_cycle(void);\n'
    'void nw_wifi_restarted(void) { g_wmi_stuck = 0; }\n'
    'static void wmi_stuck(void) {\n')
sub('  lx_log(3, \"stuck: asking for the RAM dump: %d\", mhi_force_rddm_mode(ath12k_pci_priv(ab)->mhi_ctrl));\n',
    '  if (g_restarts < NW_RESTARTS_MOST) {\n'
    '    g_restarts++; g_wmi_stuck = 3;\n'
    '    hakios_dada_wifi_cycle();\n'
    '    lx_log(3, \"stuck: the firmware is restarted (%d of %d)\", g_restarts, NW_RESTARTS_MOST);\n'
    '    queue_work(ab->workqueue_aux, &ab->reset_work);\n'
    '    return;\n'
    '  }\n'
    '  lx_log(3, \"stuck: asking for the RAM dump: %d\", mhi_force_rddm_mode(ath12k_pci_priv(ab)->mhi_ctrl));\n')$PY_TAIL"
edit src/nw_mac80211.c "$PY_HEAD
sub('void ieee80211_restart_hw(struct ieee80211_hw *hw) { (void)hw; lx_log(4, \"wifi: firmware restart requested\"); }',
    '/* the wireless stack restarts the interface after the driver restarted the firmware: later, from the dispatcher, as mac80211 does (the\\n'
    ' * driver calls this with its group lock held) */\\n'
    'static struct work_struct g_restart_work;\\n'
    'static void restart_run(struct work_struct *w) { extern void nw_sta_restart(struct ieee80211_hw *); (void)w; if (g_hw) nw_sta_restart(g_hw); }\\n'
    'void ieee80211_restart_hw(struct ieee80211_hw *hw) {\\n'
    '  (void)hw; lx_log(4, \"wifi: firmware restarted: the interface is set up again\");\\n'
    '  INIT_WORK(&g_restart_work, restart_run); lx_queue_work(&g_restart_work); }')$PY_TAIL"
edit src/nw_sta.c "$PY_HEAD
s += ('\n/* After the driver restarted its firmware (tools/mk-ath12k.sh 12): what mac80211 does for a restart -- the device started, the station\n'
      ' * interface added again, the restart said complete -- and the station from scratch, a scan first. A connection that was up went with the\n'
      ' * firmware: it is told lost. */\n'
      'void nw_wifi_restarted(void);\n'
      'void nw_sta_restart(struct ieee80211_hw *hw) {\n'
      '  int r, was = C.state;\n'
      '  lx_cancel_delayed(&g_timer);\n'
      '  g_scan_running = 0; g_connect_waits = 0; memset(&C, 0, sizeof C); C.state = NW_STA_OFF;\n'
      '  nw_wifi_bss_set(0, 0, 0, 0); nw_wifi_sta_set(0); nw_wifi_chanctx_set(0);\n'
      '  if (!g_vif || !g_ops) return;\n'
      '  r = g_ops->start(hw); if (r) { lx_log(3, \"wifi: restart: start failed: %d\", r); nw_wifi_stats.last_err = r; return; }\n'
      '  r = g_ops->add_interface(hw, g_vif); if (r) { lx_log(3, \"wifi: restart: add interface failed: %d\", r); nw_wifi_stats.last_err = r; return; }\n'
      '  if (g_ops->reconfig_complete) g_ops->reconfig_complete(hw, IEEE80211_RECONFIG_TYPE_RESTART);\n'
      '  C.state = NW_STA_IDLE; nw_wifi_stats.stage = 4; nw_wifi_stats.last_err = 0;\n'
      '  g_req.kind = REQ_SCAN; g_scan_directed = 0;\n'
      '  lx_log(6, \"wifi: firmware restarted: the interface is up again, scanning\");\n'
      '  if (was >= NW_STA_AUTH && g_ev.link_lost) g_ev.link_lost(0);\n'
      '  nw_wifi_restarted(); }\n')$PY_TAIL"

# 13. The radio takes the board's address always, not only when its own is missing: en0 is made at kernel start, long
#     before the firmware says what it has, and iOS knows the interface by that address (hakios_dada_wlan.c: wifi_mac=,
#     else the phone's wlan_mac.bin, else a local one); a radio with another address would get no frames for en0.
edit ath12k-src/mac.c "$PY_HEAD
sub('\t\tif (!is_valid_ether_addr(ar->mac_addr) ||\n\t\t    (!ar->mac_addr[0] && ar->mac_addr[1] == 0x03 && ar->mac_addr[2] == 0x7f)) {\n',
    '\t\t{\t/* the board\\'s address, always (tools/mk-ath12k.sh 13) */\n')$PY_TAIL"

# 14. ... and the chip power-cycled for it, first. A hung firmware leaves the chip's boot ROM in SYS_ERR, which the
#     driver's soft reset and MHI's reset do not clear ("Failed to reset MHI due to syserr state", run rec1), and the
#     driver's power-down writing MHI reset into the hung chip stopped the whole SoC (run rec2). So, as Android's cnss
#     recovers it, the stuck detector has the kernel take the chip down and up and train the link again
#     (hakios_dada_wifi_cycle(), hakios_dada_wifi.c: PERST# and WLAN_EN down, up, the link) before it queues the
#     reset: the driver's power-down and power-up then meet a chip fresh in its boot ROM, as at the first boot.

# 15. A settle after the scan vdev is created, before its first WMI set_param (NSS/chainmask) -- the command that times
#     out and stops the WMI credits in most boots (runs rec1/rec2: "failed to set vdev 0 chainmask ... -11", the
#     firmware alive in mission mode but not answering). The guess: this peach firmware (cld3's, not ath12k's) is not
#     done with vdev_create's own async work when the set_param arrives and wedges. Off by default (boot-arg
#     dadawifi_settle=MS turns it on), so the shared tree is unchanged for anyone not trying it.
edit ath12k-src/mac.c "$PY_HEAD
old = '\tath12k_dbg(ab, ATH12K_DBG_MAC, \"vdev %pM created, vdev_id %d\\\\n\",\n\t\t   vif->addr, arvif->vdev_id);\n'
sub(old, old + '\t{ extern void hakios_dada_wifi_settle(void); hakios_dada_wifi_settle(); }\t/* tools/mk-ath12k.sh 15 */\n')$PY_TAIL"

# 16. Skip the per-vdev WMI_VDEV_PARAM_NSS set_param that ath12k sends right after vdev_create. Qualcomm's cld3 host
#     puts nss in vdev_create itself (the per-band wmi_vdev_txrx_streams, which ath12k also sends) and does NOT send a
#     separate NSS param; on peach the firmware stops replenishing HTC credits a few params into this first burst
#     ("failed to set vdev 0 chainmask ... -11", runs bt1/bt2). Off by default (boot-arg dadawifi_nonss=1).
edit ath12k-src/mac.c "$PY_HEAD
old = '\tnss = hweight32(ar->cfg_tx_chainmask) ? : 1;\n\tret = ath12k_wmi_vdev_set_param_cmd(ar, arvif->vdev_id,\n\t\t\t\t\t    WMI_VDEV_PARAM_NSS, nss);\n'
sub(old, '\tnss = hweight32(ar->cfg_tx_chainmask) ? : 1;\n\t{ extern int hakios_dada_wifi_skip_nss(void); if (hakios_dada_wifi_skip_nss()) goto nss_done_16; }\t/* tools/mk-ath12k.sh 16 */\n\tret = ath12k_wmi_vdev_set_param_cmd(ar, arvif->vdev_id,\n\t\t\t\t\t    WMI_VDEV_PARAM_NSS, nss);\n')
sub('\t\t\t    arvif->vdev_id, ar->cfg_tx_chainmask, nss, ret);\n\t\tgoto err_vdev_del;\n\t}\n', '\t\t\t    arvif->vdev_id, ar->cfg_tx_chainmask, nss, ret);\n\t\tgoto err_vdev_del;\n\t}\nnss_done_16:\t;\n')$PY_TAIL"

# 17. Idle power save (WMI_PDEV_PARAM_IDLE_PS_CONFIG=1, pdev param 44) is what ath12k sends right before the first vdev
#     create (hw_params.idle_ps=true for the qcc2072/wcn7850 profile). With it the firmware power-collapses its MAC/PHY
#     and has to bring the RF rails back through SW_CTRL -> PDC at the first radio work; CBC (no idle PS) never hangs.
#     boot-arg dadawifi_noidleps=1 skips it.
edit ath12k-src/mac.c "$PY_HEAD
sub('\t/* allow device to enter IMPS */\n\tif (ab->hw_params->idle_ps) {\n',
    '\t/* allow device to enter IMPS */\n\tif (ab->hw_params->idle_ps && ({ extern int hakios_dada_wifi_idle_ps(void); hakios_dada_wifi_idle_ps(); })) {\t/* tools/mk-ath12k.sh 17 */\n')$PY_TAIL"

# 18. The hw mode ath12k puts the chip in (WMI_PDEV_SET_HW_MODE DBS=1). peach lists only SINGLE(0) and DBS_OR_SBS(5);
#     cld3 (MCL) sends none (preferred_hw_mode MAX, firmware stays in SMM). boot-arg dadawifi_hwmode=N: 255 none, 0 SINGLE,
#     5 DBS_OR_SBS, default 1 (as before).
edit ath12k-src/core.c "$PY_HEAD
sub('\t\tret = ath12k_wmi_set_hw_mode(ab, WMI_HOST_HW_MODE_DBS);\n',
    '\t\t{ extern int hakios_dada_wifi_hw_mode(void); int m = hakios_dada_wifi_hw_mode();\t/* tools/mk-ath12k.sh 18 */\n'
    '\t\tret = m < 0 ? 0 : ath12k_wmi_set_hw_mode(ab, (enum wmi_host_hw_mode_config_type)m); }\n')$PY_TAIL"

# 19. qcacld's platform TX power limit (hdd_features_init -> wma_process_tx_power_limits): WMI_PDEV_PARAM_TXPOWER_LIMIT2G/5G
#     with WMI_PDEV_PARAM_TXPOWER_REASON_SAR (1) in bits 15:8 and the value (TxPower2g/5g default 30) in bits 7:0, once at
#     start; ath12k never sends it. On the Xiaomi Pad 8 Pro (same WCN7860 = peach, same WLAN.GNG.1.0.c2-00047) the link
#     stalled above ~20 dBm without it (yzddmr6/linux-sm8750-piano d9d029f0c). boot-arg dadawifi_sar=N (0 = not sent).
edit ath12k-src/mac.c "$PY_HEAD
sub('\trcu_assign_pointer(ab->pdevs_active[ar->pdev_idx],\n\t\t\t   &ab->pdevs[ar->pdev_idx]);\n',
    '\t{ extern int hakios_dada_wifi_sar(void); int sar = hakios_dada_wifi_sar();\t/* tools/mk-ath12k.sh 19 */\n'
    '\t  if (sar > 0) {\n'
    '\t\tret = ath12k_wmi_pdev_set_param(ar, WMI_PDEV_PARAM_TXPOWER_LIMIT2G, (1u << 8) | (u32)sar, pdev->pdev_id);\n'
    '\t\tif (!ret) ret = ath12k_wmi_pdev_set_param(ar, WMI_PDEV_PARAM_TXPOWER_LIMIT5G, (1u << 8) | (u32)sar, pdev->pdev_id);\n'
    '\t\tif (ret) ath12k_warn(ab, \"sar txpower limit: %d\\\\n\", ret);\n'
    '\t\tar->txpower_limit_2g = ar->txpower_limit_5g = (1u << 8) | (u32)sar;\n'
    '\t  } }\n'
    '\trcu_assign_pointer(ab->pdevs_active[ar->pdev_idx],\n\t\t\t   &ab->pdevs[ar->pdev_idx]);\n')$PY_TAIL"

# 20. Passive scans only (no probe requests: the radio never transmits while scanning). boot-arg dadawifi_passive=1. A test of
#     whether the firmware's death at its first radio work is a transmit (PA supply) problem.
edit ath12k-src/mac.c "$PY_HEAD
sub('\tif (req->n_ssids) {\n\t\targ->num_ssids = req->n_ssids;\n',
    '\tif (req->n_ssids && !({ extern int hakios_dada_wifi_passive(void); hakios_dada_wifi_passive(); })) {\t/* tools/mk-ath12k.sh 20 */\n\t\targ->num_ssids = req->n_ssids;\n')$PY_TAIL"

# 21. The host-capability nm_modem bits ath12k sends with internal_sleep_clock: HOST_CSTATE_BIT ("not a Qualcomm platform":
#     the firmware does not count on the SoC's PDC/AOP for its power states) and the internal sleep clock. The Xiaomi Pad 8
#     Pro (mainline wcn7860 entry, same chip and firmware) runs with both and its Wi-Fi works; our one earlier try (wifi39)
#     proves nothing at a ~25% random pass rate. boot-arg dadawifi_nmmodem=1.
edit ath12k-src/qmi.c "$PY_HEAD
sub('\tif (ab->hw_params->internal_sleep_clock) {\n\t\treq.nm_modem_valid = 1;\n',
    '\tif (ab->hw_params->internal_sleep_clock || ({ extern int hakios_dada_wifi_nm_modem(void); hakios_dada_wifi_nm_modem(); })) {\t/* tools/mk-ath12k.sh 21 */\n\t\treq.nm_modem_valid = 1;\n')$PY_TAIL"

# 22. After the stuck detector has power-cycled the chip (hakios_dada_wifi_cycle: WLAN_EN down/up, link trained again),
#     the driver's reset path writes MHI RESET into the fresh chip and waits for it to clear for the controller's whole
#     timeout_ms (run w71r1: "Triggering MHI Reset in device", then nothing for 170 s). A chip just powered on cannot be
#     touching host memory: that reset is skipped once after a cycle.
edit mhi-src/pm.c "$PY_HEAD
sub('\t/* Trigger MHI RESET so that the device will not access host memory */\n\tif (!MHI_PM_IN_FATAL_STATE(mhi_cntrl->pm_state)) {\n\t\t/* Skip MHI RESET if in RDDM state */\n',
    '\t/* Trigger MHI RESET so that the device will not access host memory */\n\tif (!MHI_PM_IN_FATAL_STATE(mhi_cntrl->pm_state) && !({ extern int hakios_dada_wifi_just_cycled(void); hakios_dada_wifi_just_cycled(); })) {\t/* tools/mk-ath12k.sh 22 */\n\t\t/* Skip MHI RESET if in RDDM state */\n')$PY_TAIL"

# 23. The host capability's feature list, boot-arg dadawifi_features=MASK (default: hw_params, AUX_UC only = 0x40). The Xiaomi
#     Pad 8 Pro (same chip/fw, Wi-Fi works) sends PERST_NO_PULL | AUX_UC = 0x50 with QDSS sent (QDSS_CFG_MISS not set).
edit ath12k-src/qmi.c "$PY_HEAD
sub('\t\treq.feature_list = ab->hw_params->qmi_cnss_feature_bitmap;\n',
    '\t\treq.feature_list = ({ extern uint64_t hakios_dada_wifi_features(uint64_t); hakios_dada_wifi_features(ab->hw_params->qmi_cnss_feature_bitmap); });\t/* tools/mk-ath12k.sh 23 */\n')$PY_TAIL"

# 24. No cold-boot calibration (boot-arg dadawifi_nocbc=1), as mainline / the Pad 8 Pro.
edit ath12k-src/qmi.c "$PY_HEAD
sub('if (!nw_cbc_tried && !ab->qmi.cal_done && nw_cbc(ab))',
    'if (!nw_cbc_tried && !ab->qmi.cal_done && !({ extern int hakios_dada_wifi_no_cbc(void); hakios_dada_wifi_no_cbc(); }) && nw_cbc(ab))')$PY_TAIL"

# 25. What the WLAN firmware asks the name service for (QRTR NEW_LOOKUP) and which servers appear: does it look for a modem
#     service (LTE coex / DMS) we never have? Logged, nothing answered differently.
cp $W/src/nw_qrtr.c gen/src/
edit src/nw_qrtr.c "$PY_HEAD
sub('  switch (le32_to_cpu(p->cmd)) {\n  case QRTR_TYPE_HELLO:',
    '  if (le32_to_cpu(p->cmd) == QRTR_TYPE_NEW_LOOKUP || le32_to_cpu(p->cmd) == QRTR_TYPE_NEW_SERVER)\n'
    '    pr_info(\"qrtr: node %u port %u: %s service %u instance %u\\\\n\", src_node, src_port,\n'
    '            le32_to_cpu(p->cmd) == QRTR_TYPE_NEW_LOOKUP ? \"LOOKUP\" : \"SERVER\", le32_to_cpu(p->server.service), le32_to_cpu(p->server.instance));\t/* tools/mk-ath12k.sh 25 */\n'
    '  switch (le32_to_cpu(p->cmd)) {\n  case QRTR_TYPE_HELLO:')$PY_TAIL"

# 26. One WMI command in the firmware at a time, as Android: cld3's WCNSS_qcom_cfg.ini gWmiCreditCount=1 caps HTC's
#     TotalTransmitCredits (htc_wait_target) so the next command waits for the previous one's credit. peach offers 2; with
#     2 a VDEV_SET_PARAM reaches the firmware while it is still doing VDEV_CREATE's first PHY bring-up -- where it hangs.
#     Boot-arg dadawifi_credits=N (default 0: the firmware's count).
edit ath12k-src/htc.c "$PY_HEAD
sub('\thtc->total_transmit_credits = credit_count;\n',
    '\thtc->total_transmit_credits = ({ extern uint32_t hakios_dada_wifi_credits(uint32_t); hakios_dada_wifi_credits(credit_count); });\t/* tools/mk-ath12k.sh 26 */\n')$PY_TAIL"

# 27. The firmware's voltage-corner mode, as cld3 on peach-v2 (CONFIG_WLAN_DYNAMIC_CVM: hdd_set_vc_mode_config sends gConfigVCmode,
#     default 0x5 = static LOW SVS for 11a/b/g, static SVS for the rest) as pdev param WMI_PDEV_UPDATE_WDCVS_ALGO (0x9a), after
#     ready, before any vdev. Boot-arg dadawifi_vcmode=N (0: not sent).
edit ath12k-src/mac.c "$PY_HEAD
sub('\tret = ath12k_wmi_pdev_set_param(ar, WMI_PDEV_PARAM_PMF_QOS,\n',
    '\t{ extern uint32_t hakios_dada_wifi_vcmode(void); uint32_t vc = hakios_dada_wifi_vcmode();\t/* tools/mk-ath12k.sh 27 */\n'
    '\t  if (vc != 0 && ath12k_wmi_pdev_set_param(ar, 0x9a, vc, pdev->pdev_id) != 0) ath12k_warn(ab, \"vc mode %u refused\\\\n\", vc); }\n'
    '\tret = ath12k_wmi_pdev_set_param(ar, WMI_PDEV_PARAM_PMF_QOS,\n')$PY_TAIL"

# 28. The coex configuration cld3 sends after a STA vdev is created (hdd_send_coex_config_params, its ini defaults):
#     WMI_COEX_CONFIG_CMDID {vdev, type, arg1..6} for TX_POWER(12)=0x0a0a, HANDOVER_RSSI(19)=-80, BTC_MODE(24)=0,
#     ANTENNA_ISOLATION(25)=25, BT_LOW_RSSI(26)=-65, BT_INTERFERENCE(27)=-25,-21,-20,-16,-15,-11, SCO_ALLOW_2G_SCAN(42)=1.
#     Here right after VDEV_CREATE, before the parameter burst the firmware dies in. Boot-arg dadawifi_coex=1.
edit ath12k-src/wmi.c "$PY_HEAD
sub('int ath12k_wmi_pdev_set_ps_mode(struct ath12k *ar, int vdev_id, u32 enable)\n',
    'int ath12k_wmi_coex_config(struct ath12k *ar, u32 vdev_id, u32 type, const u32 *args)\t/* tools/mk-ath12k.sh 28 */\n'
    '{\n'
    '\tstruct ath12k_wmi_pdev *wmi = ar->wmi;\n'
    '\tstruct sk_buff *skb = ath12k_wmi_alloc_skb(wmi->wmi_ab, 9 * sizeof(__le32));\n'
    '\t__le32 *cmd;\n'
    '\tint ret;\n'
    '\n'
    '\tif (!skb)\n'
    '\t\treturn -ENOMEM;\n'
    '\tcmd = (__le32 *)skb->data;\n'
    '\tcmd[0] = ath12k_wmi_tlv_cmd_hdr(WMI_TAG_COEX_CONFIG_CMD, 9 * sizeof(__le32));\n'
    '\tcmd[1] = cpu_to_le32(vdev_id);\n'
    '\tcmd[2] = cpu_to_le32(type);\n'
    '\tfor (int i = 0; i < 6; i++)\n'
    '\t\tcmd[3 + i] = cpu_to_le32(args[i]);\n'
    '\tret = ath12k_wmi_cmd_send(wmi, skb, WMI_COEX_CONFIG_CMDID);\n'
    '\tif (ret)\n'
    '\t\tdev_kfree_skb(skb);\n'
    '\treturn ret;\n'
    '}\n'
    '\n'
    'int ath12k_wmi_pdev_set_ps_mode(struct ath12k *ar, int vdev_id, u32 enable)\n')$PY_TAIL"
edit ath12k-src/mac.c "$PY_HEAD
sub('\t{ extern void hakios_dada_wifi_settle(void); hakios_dada_wifi_settle(); }\t/* tools/mk-ath12k.sh 15 */\n',
    '\t{ extern void hakios_dada_wifi_settle(void); hakios_dada_wifi_settle(); }\t/* tools/mk-ath12k.sh 15 */\n'
    '\t{ extern int hakios_dada_wifi_coex(void); extern int ath12k_wmi_coex_config(struct ath12k *, u32, u32, const u32 *);\t/* 28 */\n'
    '\t  static const u32 coex[7][7] = { { 12, 0x0a0a }, { 19, (u32)-80 }, { 24, 0 }, { 25, 25 }, { 26, (u32)-65 },\n'
    '\t\t{ 27, (u32)-25, (u32)-21, (u32)-20, (u32)-16, (u32)-15, (u32)-11 }, { 42, 1 } };\n'
    '\t  if (hakios_dada_wifi_coex())\n'
    '\t\tfor (int i = 0; i < 7; i++)\n'
    '\t\t\tif (ath12k_wmi_coex_config(ar, arvif->vdev_id, coex[i][0], &coex[i][1]))\n'
    '\t\t\t\tath12k_warn(ab, \"coex config %u not sent\\\\n\", coex[i][0]); }\n')$PY_TAIL"

# 29. At the hang, the firmware made to crash and dump through host SOL (gpio202): cnss2 asserts it "to retry RDDM" when the
#     MHI way fails (cnss_pci_assert_host_sol) -- and ours (mhi_force_rddm_mode) did fail at the hang. Its dump then says
#     where the firmware was stuck (rddm_scan). Boot-arg dadawifi_solrddm=1 (no restart then).
edit src/nw_wifi.c "$PY_HEAD
sub('  for (int p = 1; p <= 4; p++) ring_state(ab, p);\n',
    '  for (int p = 1; p <= 4; p++) ring_state(ab, p);\n'
    '  { extern int hakios_dada_wifi_sol_crash(void); if (hakios_dada_wifi_sol_crash()) { g_wmi_stuck = 3; return; } }\t/* tools/mk-ath12k.sh 29 */\n')$PY_TAIL"

# 30. A trace of the dispatcher while nw_trace is set (tools/ath12k-cbc.py: from the calibration's OFF on): every timer and
#     queued work it runs, with the time and the function (as an offset from lx_now_ms), to see what runs last before the
#     cold path dies at its random places.
mkdir -p gen/shim/src
cp $W/shim/src/lx_rt.c gen/shim/src/lx_rt.c
edit shim/src/lx_rt.c "$PY_HEAD
sub('volatile uint64_t nw_wifi_where[4];\n',
    'volatile uint64_t nw_wifi_where[4];\nvolatile int nw_trace;\t/* tools/mk-ath12k.sh 30 */\nvolatile int nw_quiet;\t/* 30: no handler is offered a look while set */\n')
sub('  { static u64 last_raise; u64 t = lx_now_ms(); if (t != last_raise) { last_raise = t; lx_irq_raise_all(); } }\n',
    '  { static u64 last_raise; u64 t = lx_now_ms(); if (t != last_raise && !nw_quiet) { last_raise = t; lx_irq_raise_all(); } }\n')
sub('  nw_wifi_where[2] = g_depth; nw_wifi_where[3] = lx_now_ms(); }\n',
    '  nw_wifi_where[2] = g_depth; nw_wifi_where[3] = lx_now_ms();\n'
    '  if (nw_trace && (kind == 2 || kind == 3)) lx_log(6, \"trace %llu ms: %s +%#llx depth %d\", (unsigned long long)lx_now_ms(), kind == 2 ? \"timer\" : \"work\", (unsigned long long)nw_wifi_where[1], g_depth); }\n')$PY_TAIL"

# --- compile
SOURCES="src/nw_crypto src/nw_debug src/nw_mac80211 src/nw_mhi src/nw_net src/nw_pci src/nw_qrtr src/nw_qrtr_mhi src/nw_sta
	src/nw_wifi shim/src/lx_rt shim/src/mhi_hook"
MHI="init main pm boot"
QMI="qmi_interface qmi_encdec"
DRIVER="ce core dbring dp dp_htt dp_mon dp_peer dp_rx dp_tx fw hal htc mac mhi p2p pci peer qmi reg wmi
	wifi7/ce wifi7/core wifi7/dp wifi7/dp_mon wifi7/dp_rx wifi7/dp_tx wifi7/hal wifi7/hal_qcc2072 wifi7/hal_qcn9274
	wifi7/hal_rx wifi7/hal_tx wifi7/hal_wcn7850 wifi7/hw wifi7/mhi wifi7/pci wifi7/wmi"
CC="clang -target arm64e-apple-ios16.5"
CINC=$(clang -print-resource-dir)/include
CFLAGS="-mkernel -mgeneral-regs-only -fno-builtin -fno-common -ffreestanding -fno-strict-aliasing -nostdinc
	-isystem $W/shim/libc -isystem $CINC -std=gnu11 -O2 -g0 -w -DCONFIG_ATH12K_DEBUG -include lx_pci.h
	-I$W/shim/include -I$W/include -I$B/gen/pinned -I$W/src -I$B/gen/ath12k-src -I$B/gen/ath12k-src/wifi7"
rm -rf obj out
mkdir -p obj out
compile() {	# compile SOURCE OBJECT [FLAGS]
	local src=$1 obj=$2
	shift 2
	$CC $CFLAGS "$@" -c "$src" -o "$obj" 2> "$obj.err" || rm -f "$obj"
}
for f in $SOURCES; do
	src=$W/$f.c
	[ -f gen/$f.c ] && src=gen/$f.c         # a file of the runtime this script changes (12)
	compile $src obj/$(basename $f).o -I$B/gen/mhi-src &
done
for f in $MHI; do compile gen/mhi-src/$f.c obj/mhi_$f.o -I$B/gen/mhi-src & done
for f in $QMI; do compile $L/drivers/soc/qcom/$f.c obj/$f.o & done
wait
for f in $DRIVER; do compile gen/ath12k-src/$f.c obj/ath12k_$(echo $f | tr / _).o & done
wait
bad=
for f in obj/*.err; do
	[ -s "$f" ] && [ ! -f "${f%.err}" ] && { echo "--- $(basename "$f" .o.err)"; grep -m6 -A3 "error:" "$f"; bad=1; }
done
[ -z "$bad" ] || exit 1

# --- one object; what it still asks for must be the kernel's (the C library XNU has under the same names)
LD=$ROOT/xnu-deps/host/bin/ld64
$LD -r -arch arm64e obj/*.o -o out/all.o 2> out/ld.err || { cat out/ld.err; exit 1; }
KERNEL="hakios_dada_wifi_note hakios_dada_wifi_rddm_seen hakios_dada_wifi_cbc_cold hakios_dada_wifi_sol_crash hakios_dada_wifi_coex hakios_dada_wifi_vcmode hakios_dada_wifi_credits hakios_dada_wifi_cycle hakios_dada_wifi_settle hakios_dada_wifi_skip_nss hakios_dada_wifi_idle_ps hakios_dada_wifi_hw_mode hakios_dada_wifi_sar hakios_dada_wifi_passive hakios_dada_wifi_nm_modem hakios_dada_wifi_just_cycled hakios_dada_wifi_features hakios_dada_wifi_no_cbc memcmp memcpy memmove memset strcmp strncmp strlen strnlen strchr strrchr strncpy strlcpy strlcat strtoul bzero
	snprintf vsnprintf __stack_chk_fail __stack_chk_guard"
nm -u out/all.o | sed 's/^_//' | sort -u > out/undefined.txt
missing=
for s in $(cat out/undefined.txt); do
	case " $(echo $KERNEL) " in *" $s "*) continue ;; esac
	echo "mk-ath12k.sh: nothing defines $s" >&2
	missing=1
done
[ -z "$missing" ] || exit 1
printf '_nw_wifi_*\n_lx_stack_peak\n_lx_depth_peak\n' > out/exported.txt
$LD -r -arch arm64e -exported_symbols_list out/exported.txt out/all.o -o out/ath12k.o 2> out/ld.err || { cat out/ld.err; exit 1; }
rm -f out/all.o
echo "mk-ath12k.sh: out/ath12k.o: $(size out/ath12k.o 2>/dev/null | awk 'NR == 2 { print $1 + $2 + $3 }') bytes;" \
	"asks the kernel for $(wc -l < out/undefined.txt | tr -d ' ') names"
