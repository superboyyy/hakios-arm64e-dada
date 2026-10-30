#!/usr/bin/env python3
"""ath12k's qmi.c (generated copy, gen/ath12k-src/qmi.c): the QDSS trace configuration downloaded after the AUX
microcode, as Android's cnss2 does it (cnss2 qmi.c cnss_wlfw_qdss_dnld_send_sync; message 0x44, the file in pieces
of 6144 bytes, TLVs 0x10 total size, 0x11 piece, 0x12 data, 0x13 end).

Why: with the host capability's feature list as cnss2 sends it for peach (the AUX bit and nothing else, so no
QDSS_CFG_MISS) the firmware takes M3 and AUX and then waits -- for this file -- before it says "firmware ready"
(run wifi20, 28 October). It is taken: run wifi27 sent qdss_trace_config_v2.cfg, 6241 bytes in 2 pieces. Called by tools/mk-ath12k.sh;
every mark must be found exactly once.

usage: ath12k-qdss.py gen/ath12k-src/qmi.c
"""
import sys

p = sys.argv[1]
s = open(p).read()


def sub(old, new):
    global s
    assert s.count(old) == 1, "%s: mark found %d times: %r" % (p, s.count(old), old[:60])
    s = s.replace(old, new)


code = r'''
/* The QDSS trace configuration (tools/ath12k-qdss.py): peach's firmware waits for it after M3 and AUX. */
#define NW_QMI_QDSS_CFG_DOWNLOAD_REQ		0x0044
#define NW_QMI_QDSS_CFG_DOWNLOAD_REQ_MAX_LEN	6167
#define NW_QMI_QDSS_CFG_PIECE			6144

struct nw_qdss_cfg_req {
	u8 total_size_valid;
	u32 total_size;
	u8 seg_id_valid;
	u32 seg_id;
	u8 data_valid;
	u32 data_len;
	u8 data[NW_QMI_QDSS_CFG_PIECE];
	u8 end_valid;
	u8 end;
};

struct nw_qdss_cfg_resp {
	struct qmi_response_type_v01 resp;
};

static const struct qmi_elem_info nw_qdss_cfg_req_ei[] = {
	{ .data_type = QMI_OPT_FLAG, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x10, .offset = offsetof(struct nw_qdss_cfg_req, total_size_valid) },
	{ .data_type = QMI_UNSIGNED_4_BYTE, .elem_len = 1, .elem_size = sizeof(u32), .array_type = NO_ARRAY,
	  .tlv_type = 0x10, .offset = offsetof(struct nw_qdss_cfg_req, total_size) },
	{ .data_type = QMI_OPT_FLAG, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x11, .offset = offsetof(struct nw_qdss_cfg_req, seg_id_valid) },
	{ .data_type = QMI_UNSIGNED_4_BYTE, .elem_len = 1, .elem_size = sizeof(u32), .array_type = NO_ARRAY,
	  .tlv_type = 0x11, .offset = offsetof(struct nw_qdss_cfg_req, seg_id) },
	{ .data_type = QMI_OPT_FLAG, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x12, .offset = offsetof(struct nw_qdss_cfg_req, data_valid) },
	{ .data_type = QMI_DATA_LEN, .elem_len = 1, .elem_size = sizeof(u16), .array_type = NO_ARRAY,
	  .tlv_type = 0x12, .offset = offsetof(struct nw_qdss_cfg_req, data_len) },
	{ .data_type = QMI_UNSIGNED_1_BYTE, .elem_len = NW_QMI_QDSS_CFG_PIECE, .elem_size = sizeof(u8),
	  .array_type = VAR_LEN_ARRAY, .tlv_type = 0x12, .offset = offsetof(struct nw_qdss_cfg_req, data) },
	{ .data_type = QMI_OPT_FLAG, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x13, .offset = offsetof(struct nw_qdss_cfg_req, end_valid) },
	{ .data_type = QMI_UNSIGNED_1_BYTE, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,
	  .tlv_type = 0x13, .offset = offsetof(struct nw_qdss_cfg_req, end) },
	{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },
};

static const struct qmi_elem_info nw_qdss_cfg_resp_ei[] = {
	{ .data_type = QMI_STRUCT, .elem_len = 1, .elem_size = sizeof(struct qmi_response_type_v01),
	  .array_type = NO_ARRAY, .tlv_type = 0x02, .offset = offsetof(struct nw_qdss_cfg_resp, resp),
	  .ei_array = qmi_response_type_v01_ei },
	{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },
};

static int nw_qmi_qdss_cfg_send(struct ath12k_base *ab)
{
	const struct firmware *fw;
	struct nw_qdss_cfg_req *req;
	struct nw_qdss_cfg_resp resp;
	struct qmi_txn txn;
	const u8 *at;
	size_t left;
	u32 piece = 0;
	int ret = 0;

	fw = ath12k_core_firmware_request(ab, "qdss_trace_config.cfg");
	if (IS_ERR(fw)) {
		ath12k_warn(ab, "qmi qdss: no trace configuration: %ld\n", PTR_ERR(fw));
		return PTR_ERR(fw);
	}
	req = kzalloc(sizeof(*req), GFP_KERNEL);
	if (!req) {
		ath12k_warn(ab, "qmi qdss: no memory for a request of %zu bytes\n", sizeof(*req));
		release_firmware(fw);
		return -ENOMEM;
	}
	at = fw->data;
	left = fw->size;
	while (left) {
		memset(req, 0, sizeof(*req));
		memset(&resp, 0, sizeof(resp));
		req->total_size_valid = 1;
		req->total_size = left;
		req->seg_id_valid = 1;
		req->seg_id = piece;
		req->data_valid = 1;
		req->end_valid = 1;
		if (left > NW_QMI_QDSS_CFG_PIECE) {
			req->data_len = NW_QMI_QDSS_CFG_PIECE;
		} else {
			req->data_len = left;
			req->end = 1;
		}
		memcpy(req->data, at, req->data_len);
		ret = qmi_txn_init(&ab->qmi.handle, &txn, nw_qdss_cfg_resp_ei, &resp);
		if (ret < 0) {
			ath12k_warn(ab, "qmi qdss: piece %u: txn init %d\n", piece, ret);
			break;
		}
		ret = qmi_send_request(&ab->qmi.handle, NULL, &txn, NW_QMI_QDSS_CFG_DOWNLOAD_REQ,
				       NW_QMI_QDSS_CFG_DOWNLOAD_REQ_MAX_LEN, nw_qdss_cfg_req_ei, req);
		if (ret < 0) {
			qmi_txn_cancel(&txn);
			ath12k_warn(ab, "qmi qdss: piece %u: send %d\n", piece, ret);
			break;
		}
		ret = qmi_txn_wait(&txn, msecs_to_jiffies(ATH12K_QMI_WLANFW_TIMEOUT_MS));
		if (ret < 0) {
			ath12k_warn(ab, "qmi qdss: piece %u: no answer %d\n", piece, ret);
			break;
		}
		if (resp.resp.result != QMI_RESULT_SUCCESS_V01) {
			ath12k_warn(ab, "qmi qdss: piece %u refused, result %d, err %d\n", piece,
				    resp.resp.result, resp.resp.error);
			ret = -EINVAL;
			break;
		}
		ret = 0;	/* (the wait answers the response's length here, 7) */
		at += req->data_len;
		left -= req->data_len;
		piece++;
	}
	if (!ret)
		ath12k_info(ab, "qmi qdss: trace configuration sent, %zu bytes in %u pieces\n", fw->size, piece);
	kfree(req);
	release_firmware(fw);
	return ret;
}
'''

# the function, before the load sequence that calls it
sub('/* clang stack usage explodes if this is inlined */\nstatic noinline_for_stack\nint ath12k_qmi_event_load_bdf(',
    code.lstrip('\n') + '\n/* clang stack usage explodes if this is inlined */\nstatic noinline_for_stack\nint ath12k_qmi_event_load_bdf(')

# the call, after the AUX step (which tools/mk-ath12k.sh step 8b has made non-fatal)
i = s.index('int ath12k_qmi_event_load_bdf(')
j = s.index('\n\treturn ret;\n}\n', i)
s = s[:j] + ('\n\n\t/* as cnss2 after AUX (cnss_wlfw_qdss_dnld_send_sync): its failure is not fatal there either */\n'
             '\tif (nw_qmi_qdss_cfg_send(ab))\n\t\tath12k_warn(ab, "qmi qdss: trace configuration not sent\\n");\n'
             '\tret = 0;') + s[j:]

open(p, 'w').write(s)
