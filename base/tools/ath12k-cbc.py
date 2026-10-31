#!/usr/bin/env python3
"""ath12k's qmi.c (generated copy, gen/ath12k-src/qmi.c): the cold-boot calibration Android's cnss2 does on every boot
(DT qcom,wlan-cbc-enabled), before the boot the Wi-Fi is used in:

    firmware ready (cal_done 0) -> cal report (no file) -> WLAN mode CALIBRATION (7) -> CAL_DONE indication (0x3E)
    -> mode OFF -> the device powered down and up -> the firmware boots again, told cal_done 1, its memory segments
    (the CAL_DB one, type 4, holds the results) handed back the same -> firmware ready -> mission mode

cnss2: cnss_main.c cnss_fw_ready_hdlr / cnss_cold_boot_cal_done_hdlr, cnss_qmi.c cnss_wlfw_cal_report_req_send_sync;
Android's log: "WLAN register driver deferred for Calibration", "Calibration took 5540 ms". ath12k reuses a target
memory chunk of the same size and type across the power cycle (ath12k_qmi_alloc_target_mem_chunk), so the results stay.

Why: without it (mission mode straight away, cal_done 0 or 1) peach's firmware died at its first radio work -- the WMI
credits stop right after the vdev is made -- in most runs (wifi23..wifi33, drv1..drv13, 28 October).
Called by tools/mk-ath12k.sh; every mark must be found exactly once.

usage: ath12k-cbc.py gen/ath12k-src/qmi.c
"""
import sys

p = sys.argv[1]
s = open(p).read()


def sub(old, new):
    global s
    assert s.count(old) == 1, "%s: mark found %d times: %r" % (p, s.count(old), old[:60])
    s = s.replace(old, new)


sub('#include "qmi.h"\n', '#include "qmi.h"\n#include "hif.h"\t/* tools/ath12k-cbc.py: the power cycle after calibration */\n'
    '#include "pci.h"\n')

code = r'''
/* The cold-boot calibration (tools/ath12k-cbc.py) */
#define NW_QMI_CAL_REPORT_REQ			0x0026
#define NW_QMI_CAL_REPORT_REQ_MAX_LEN		43
#define NW_QMI_CAL_DONE_IND			0x003E
#define NW_FIRMWARE_MODE_CALIBRATION		7
#define NW_CBC_TIMEOUT_MS			15000

struct nw_cal_report_req {
	u32 meta_data_len;
	u32 meta_data[5];
	u8 cal_file_download_size_valid;
	u64 cal_file_download_size;
};

struct nw_cal_report_resp {
	struct qmi_response_type_v01 resp;
};

struct nw_cal_done_ind {
	char placeholder;
};

static const struct qmi_elem_info nw_cal_report_req_ei[] = {
	{ .data_type = QMI_DATA_LEN, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x01, .offset = offsetof(struct nw_cal_report_req, meta_data_len) },
	{ .data_type = QMI_SIGNED_4_BYTE_ENUM, .elem_len = 5, .elem_size = sizeof(u32), .array_type = VAR_LEN_ARRAY,
	  .tlv_type = 0x01, .offset = offsetof(struct nw_cal_report_req, meta_data) },
	{ .data_type = QMI_OPT_FLAG, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x12, .offset = offsetof(struct nw_cal_report_req, cal_file_download_size_valid) },
	{ .data_type = QMI_UNSIGNED_8_BYTE, .elem_len = 1, .elem_size = sizeof(u64), .array_type = NO_ARRAY,
	  .tlv_type = 0x12, .offset = offsetof(struct nw_cal_report_req, cal_file_download_size) },
	{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },
};

static const struct qmi_elem_info nw_cal_report_resp_ei[] = {
	{ .data_type = QMI_STRUCT, .elem_len = 1, .elem_size = sizeof(struct qmi_response_type_v01),
	  .array_type = NO_ARRAY, .tlv_type = 0x02, .offset = offsetof(struct nw_cal_report_resp, resp),
	  .ei_array = qmi_response_type_v01_ei },
	{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },
};

static const struct qmi_elem_info nw_cal_done_ind_ei[] = {
	{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },
};

static struct completion nw_cbc_done;
static bool nw_cbc_tried;

static void nw_cal_done_ind_cb(struct qmi_handle *qmi_hdl, struct sockaddr_qrtr *sq,
			       struct qmi_txn *txn, const void *data)
{
	complete(&nw_cbc_done);
}

static int nw_qmi_cal_report_send(struct ath12k_base *ab)
{
	struct nw_cal_report_req req = {};
	struct nw_cal_report_resp resp = {};
	struct qmi_txn txn;
	int ret;

	req.cal_file_download_size_valid = 1;
	req.cal_file_download_size = 0;
	ret = qmi_txn_init(&ab->qmi.handle, &txn, nw_cal_report_resp_ei, &resp);
	if (ret < 0)
		return ret;
	ret = qmi_send_request(&ab->qmi.handle, NULL, &txn, NW_QMI_CAL_REPORT_REQ, NW_QMI_CAL_REPORT_REQ_MAX_LEN,
			       nw_cal_report_req_ei, &req);
	if (ret < 0) {
		qmi_txn_cancel(&txn);
		return ret;
	}
	ret = qmi_txn_wait(&txn, msecs_to_jiffies(ATH12K_QMI_WLANFW_TIMEOUT_MS));
	if (ret < 0)
		return ret;
	if (resp.resp.result != QMI_RESULT_SUCCESS_V01)
		return -resp.resp.error ? -resp.resp.error : -EINVAL;
	return 0;
}

static int ath12k_qmi_wlanfw_mode_send(struct ath12k_base *ab, u32 mode);

/* At the first "firmware ready": calibrate, then power the device down and up. True when the power cycle is under way. */
static bool nw_cbc(struct ath12k_base *ab)
{
	unsigned long left;
	u64 t0;
	int ret;

	nw_cbc_tried = true;
	init_completion(&nw_cbc_done);
	ret = nw_qmi_cal_report_send(ab);
	if (ret)
		ath12k_warn(ab, "cbc: cal report: %d (going on)\n", ret);
	ret = ath12k_qmi_wlanfw_mode_send(ab, NW_FIRMWARE_MODE_CALIBRATION);
	if (ret < 0) {	/* (a positive answer is the response's length: this port's qmi_txn_wait) */
		ath12k_warn(ab, "cbc: calibration mode refused: %d: mission mode without it\n", ret);
		return false;
	}
	t0 = lx_now_ms();
	ath12k_info(ab, "cbc: the firmware calibrates\n");
	left = wait_for_completion_timeout(&nw_cbc_done, msecs_to_jiffies(NW_CBC_TIMEOUT_MS));
	ath12k_info(ab, "cbc: calibration %s after %llu ms\n", left ? "DONE" : "TIMED OUT", lx_now_ms() - t0);
	/*
	 * As cnss2: OFF, and the device powered down and up (the calibration firmware is done: it goes to RDDM by itself
	 * when it is left on, run wifi37). It boots again, told cal_done 1.
	 */
	{ extern volatile int nw_trace; extern int hakios_dada_wifi_cbc_cold(void); if (hakios_dada_wifi_cbc_cold()) nw_trace = 1; }
	ret = ath12k_qmi_wlanfw_mode_send(ab, ATH12K_FIRMWARE_MODE_OFF);
	if (ret < 0)
		ath12k_warn(ab, "cbc: mode off: %d\n", ret);
	if (left)
		ab->qmi.cal_done = 1;
	ath12k_info(ab, "cbc: the device powered down and up (cal_done %u)\n", ab->qmi.cal_done);
	/* ath12k_pci_power_down does nothing before the driver has started (ath12k_pci_start sets the flag) */
	set_bit(ATH12K_PCI_FLAG_INIT_DONE, &ath12k_pci_priv(ab)->flags);
	/*
	 * Android goes further here: WLAN_EN low, every regulator off and on again, WLAN_EN high, the link trained afresh
	 * (cnss "WLAN_EN Value: 0" .. "1", 105 ms) -- a cold chip for mission mode, where ours stayed warm. Boot-arg
	 * dadawifi_cbccold=1: the same, through the stuck detector's power cycle (hakios_dada_wifi_cycle) -- BEFORE the
	 * driver's power-down, in that order as the stuck detector does it (after it, the whole SoC stalled: w159a).
	 */
	{
		extern int hakios_dada_wifi_cbc_cold(void);
		extern void hakios_dada_wifi_cycle(void);

		if (hakios_dada_wifi_cbc_cold() == 4) {
			/* =4: wait for the calibration firmware's own dump to begin (MHI says RDDM) and give it 2 s to end, then cut */
			extern int hakios_dada_wifi_rddm_seen(u64);
			u64 from = lx_now_ms();
			int waited = 0;

			while (!hakios_dada_wifi_rddm_seen(from) && waited < 10000) {
				msleep(100);
				waited += 100;
			}
			ath12k_info(ab, "cbc: the calibration firmware's dump %s after %d ms; 2 s more, then the cold cycle\n",
				    hakios_dada_wifi_rddm_seen(from) ? "began" : "NEVER BEGAN", waited);
			msleep(2000);
			hakios_dada_wifi_cycle();
		}
		{ extern volatile int nw_quiet; if (hakios_dada_wifi_cbc_cold()) nw_quiet = 1; }	/* no handler reads the chip until the power-down returns */
		if (hakios_dada_wifi_cbc_cold() == 3) {
			/* =3: first let the calibration firmware finish what it does by itself after OFF (its RDDM into our memory),
			 * the dispatcher serving it, then cut: the cut mid-DMA is what =1 and =2 died of (w163a, w165) */
			msleep(3000);
			hakios_dada_wifi_cycle();
		}
		if (hakios_dada_wifi_cbc_cold() == 1) {
			/* =1: no idle time for the chip anywhere (left idle -- the calibration firmware after OFF, the boot ROM after the
			 * cycle -- it seems to reset itself and the dropped link takes the SoC: w168a, w177a, w179a, w180a); Android is
			 * through all of it in 105 ms */
			hakios_dada_wifi_cycle();
			ath12k_pci_priv(ab)->register_window = 0;
		}
		/* the just-cycled chip's boot ROM given time before the power-down's MHI reset reaches it: written at once it
		 * killed the SoC (w167a, w169a); the stuck detector's reset, which survives, comes later from a queued work */
		if (hakios_dada_wifi_cbc_cold() >= 3) {
			{ extern void hakios_dada_wifi_note(const char *); hakios_dada_wifi_note("cbc: cold: the cycle returned; 1.5 s"); }
			ath12k_info(ab, "cbc: cold: the cycle returned; 1.5 s\n");
			msleep(1500);
			{ extern void hakios_dada_wifi_note(const char *); hakios_dada_wifi_note("cbc: cold: 1.5 s later"); }
			ath12k_info(ab, "cbc: cold: 1.5 s later; the power-down next\n");
			/* the chip's register window is back at its reset value after the cycle; the driver's cache of it is not, and
			 * the power-down's reads through the stale window came back all ones (w172a) */
			ath12k_pci_priv(ab)->register_window = 0;
		}
	}
	ath12k_info(ab, "cbc: the power-down\n");
	ath12k_hif_power_down(ab, false);
	ath12k_info(ab, "cbc: the power-down returned\n");
	{ extern volatile int nw_quiet; nw_quiet = 0; }
	/* dadawifi_cbccold=2: after the power-down instead (its MHI reset stops the calibration firmware's own DMA into our
	 * memory first: cut by the cycle above while it ran, the whole SoC died right after the link came back, w163a) */
	{
		extern int hakios_dada_wifi_cbc_cold(void);
		extern void hakios_dada_wifi_cycle(void);

		if (hakios_dada_wifi_cbc_cold() == 2) {
			msleep(200);
			hakios_dada_wifi_cycle();
		}
	}
	msleep(100);
	ret = ath12k_hif_power_up(ab);
	if (ret)
		ath12k_err(ab, "cbc: power up: %d\n", ret);
	return true;
}
'''

# the code, before the indication handlers (its own is among them) and the event work that calls it
sub('static const struct qmi_msg_handler ath12k_qmi_msg_handlers[] = {\n',
    code.lstrip('\n') + '\nstatic const struct qmi_msg_handler ath12k_qmi_msg_handlers[] = {\n')

# the call: the first "firmware ready", before the driver is started
sub('\t\t\tclear_bit(ATH12K_FLAG_CRASH_FLUSH,\n\t\t\t\t  &ab->dev_flags);\n\t\t\tret = ath12k_core_qmi_firmware_ready(ab);\n',
    '\t\t\tclear_bit(ATH12K_FLAG_CRASH_FLUSH,\n\t\t\t\t  &ab->dev_flags);\n'
    '\t\t\tif (!nw_cbc_tried && !ab->qmi.cal_done && nw_cbc(ab))\n\t\t\t\tbreak;\n'
    '\t\t\tret = ath12k_core_qmi_firmware_ready(ab);\n')

# the indication
sub('\t/* end of list */\n\t{},\n};\n\nstatic int ath12k_qmi_ops_new_server(',
    '\t{\n\t\t.type = QMI_INDICATION,\n\t\t.msg_id = NW_QMI_CAL_DONE_IND,\n\t\t.ei = nw_cal_done_ind_ei,\n'
    '\t\t.decoded_size = sizeof(struct nw_cal_done_ind),\n\t\t.fn = nw_cal_done_ind_cb,\n\t},\n'
    '\t/* end of list */\n\t{},\n};\n\nstatic int ath12k_qmi_ops_new_server(')

open(p, 'w').write(s)
