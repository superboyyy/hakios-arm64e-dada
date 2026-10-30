#!/usr/bin/env python3
"""ath12k's qmi.h and qmi.c (generated copies, gen/ath12k-src/): the target capability response's TLV 0x22, the
firmware's "OL CPR" table, decoded and said as one line per PMU pin:

    ol cpr: VDDD_WLCX_0P9 wake 920 sleep 640          (0 where the firmware gives no value)

Android's cnss2 hands these voltages to AOP for the rail each pin is on (cnss_aop_ol_cpr_cfg_setup, the DT's
qcom,pmu_vreg_map); ath12k skips the TLV. The board code (hakios_dada_wifi.c, plat_log) reads the lines and raises its
own RPMh votes to them: at the DT's lowest voltages the firmware died when the radio came on with iOS up (runs final2..
final4, 28 October). Called by tools/mk-ath12k.sh; every mark must be found exactly once.

usage: ath12k-olcpr.py gen/ath12k-src/qmi.h gen/ath12k-src/qmi.c
"""
import sys


def edit(p, subs):
    s = open(p).read()
    for old, new in subs:
        assert s.count(old) == 1, "%s: mark found %d times: %r" % (p, s.count(old), old[:60])
        s = s.replace(old, new)
    open(p, 'w').write(s)


# cnss2's wlfw_pmu_param_v01 / wlfw_pmu_cfg_v01 (wlan_firmware_service_v01.h)
edit(sys.argv[1], [
    ('struct qmi_wlanfw_cap_resp_msg_v01 {\n',
     'struct nw_pmu_param {\n\tu8 pin_name[32];\n\tu32 wake_volt_valid;\n\tu32 wake_volt;\n'
     '\tu32 sleep_volt_valid;\n\tu32 sleep_volt;\n};\n\n'
     'struct nw_pmu_cfg {\n\tu32 pmu_param_len;\n\tstruct nw_pmu_param pmu_param[16];\n};\n\n'
     'struct qmi_wlanfw_cap_resp_msg_v01 {\n'),
    ('\tstruct qmi_wlanfw_dev_mem_info_s_v01 dev_mem[ATH12K_QMI_WLFW_MAX_DEV_MEM_NUM_V01];\n};\n',
     '\tstruct qmi_wlanfw_dev_mem_info_s_v01 dev_mem[ATH12K_QMI_WLFW_MAX_DEV_MEM_NUM_V01];\n'
     '\tu8 ol_cpr_cfg_valid;\t/* tools/ath12k-olcpr.py */\n\tstruct nw_pmu_cfg ol_cpr_cfg;\n};\n'),
])


def u32(field, struct='nw_pmu_param'):
    return ('\t{ .data_type = QMI_UNSIGNED_4_BYTE, .elem_len = 1, .elem_size = sizeof(u32), .array_type = NO_ARRAY,\n'
            '\t  .tlv_type = 0, .offset = offsetof(struct %s, %s) },\n' % (struct, field))


eis = ('/* the firmware\'s OL CPR table (tools/ath12k-olcpr.py) */\n'
       'static const struct qmi_elem_info nw_pmu_param_ei[] = {\n'
       '\t{ .data_type = QMI_UNSIGNED_1_BYTE, .elem_len = 32, .elem_size = sizeof(u8), .array_type = STATIC_ARRAY,\n'
       '\t  .tlv_type = 0, .offset = offsetof(struct nw_pmu_param, pin_name) },\n'
       + u32('wake_volt_valid') + u32('wake_volt') + u32('sleep_volt_valid') + u32('sleep_volt') +
       '\t{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },\n};\n\n'
       'static const struct qmi_elem_info nw_pmu_cfg_ei[] = {\n'
       '\t{ .data_type = QMI_DATA_LEN, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,\n'
       '\t  .tlv_type = 0, .offset = offsetof(struct nw_pmu_cfg, pmu_param_len) },\n'
       '\t{ .data_type = QMI_STRUCT, .elem_len = 16, .elem_size = sizeof(struct nw_pmu_param),\n'
       '\t  .array_type = VAR_LEN_ARRAY, .tlv_type = 0, .offset = offsetof(struct nw_pmu_cfg, pmu_param),\n'
       '\t  .ei_array = nw_pmu_param_ei },\n'
       '\t{ .data_type = QMI_EOTI, .array_type = NO_ARRAY, .tlv_type = QMI_COMMON_TLV_TYPE },\n};\n\n')

edit(sys.argv[2], [
    ('static const struct qmi_elem_info qmi_wlanfw_cap_resp_msg_v01_ei[] = {\n',
     eis + 'static const struct qmi_elem_info qmi_wlanfw_cap_resp_msg_v01_ei[] = {\n'),
    ('\t\t.offset\t\t= offsetof(struct qmi_wlanfw_cap_resp_msg_v01, dev_mem),\n'
     '\t\t.ei_array\t= qmi_wlanfw_dev_mem_info_s_v01_ei,\n\t},\n',
     '\t\t.offset\t\t= offsetof(struct qmi_wlanfw_cap_resp_msg_v01, dev_mem),\n'
     '\t\t.ei_array\t= qmi_wlanfw_dev_mem_info_s_v01_ei,\n\t},\n'
     '\t{ .data_type = QMI_OPT_FLAG, .elem_len = 1, .elem_size = sizeof(u8), .array_type = NO_ARRAY,\n'
     '\t  .tlv_type = 0x22, .offset = offsetof(struct qmi_wlanfw_cap_resp_msg_v01, ol_cpr_cfg_valid) },\n'
     '\t{ .data_type = QMI_STRUCT, .elem_len = 1, .elem_size = sizeof(struct nw_pmu_cfg), .array_type = NO_ARRAY,\n'
     '\t  .tlv_type = 0x22, .offset = offsetof(struct qmi_wlanfw_cap_resp_msg_v01, ol_cpr_cfg),\n'
     '\t  .ei_array = nw_pmu_cfg_ei },\n'),
    ('\tif (resp.dev_mem_info_valid) {\n\t\tfor (i = 0; i < ATH12K_QMI_WLFW_MAX_DEV_MEM_NUM_V01; i++) {\n',
     '\tif (!resp.ol_cpr_cfg_valid)\n'
     '\t\tath12k_info(ab, "ol cpr: none in the capabilities\\n");\n'
     '\tfor (i = 0; resp.ol_cpr_cfg_valid && i < resp.ol_cpr_cfg.pmu_param_len && i < 16; i++) {\n'
     '\t\tstruct nw_pmu_param *pp = &resp.ol_cpr_cfg.pmu_param[i];\n\n'
     '\t\tath12k_info(ab, "ol cpr: %.32s wake %u sleep %u\\n", pp->pin_name,\n'
     '\t\t\t    pp->wake_volt_valid ? pp->wake_volt : 0, pp->sleep_volt_valid ? pp->sleep_volt : 0);\n'
     '\t}\n\n'
     '\tif (resp.dev_mem_info_valid) {\n\t\tfor (i = 0; i < ATH12K_QMI_WLFW_MAX_DEV_MEM_NUM_V01; i++) {\n'),
])
