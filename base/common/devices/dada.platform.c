/*
 * dada (Xiaomi 15, Snapdragon 8 Elite / SM8750): the live copy is in xnuloader/loader.c next to
 * platform_redwood, with &platform_dada in platforms[].  Every value is explained in docs/PORTING.md
 * ("The loader"); the addresses come from the UniXNU-dada reconnaissance (docs/known-values.md).
 *
 * MPIDR caveat: dada is two clusters -- six Oryon-M at Aff1 0..5 (reg 0x000..0x500) and two prime
 * Oryon-L at Aff2=1 (reg 0x10000, 0x10100).  core_shift=8 addresses only the first cluster (cores
 * 0..5 -> MPIDR 0x000..0x500), which is all the cpus=1 bring-up uses; SMP across both clusters will
 * need the loader's single-shift core model extended.
 */
static const struct platform platform_dada = {
	.name = "dada",
	/* io_base must be non-zero (XNU treats a zero SoC base as "no SoC"); one window over the SoC
	 * peripherals below DRAM (0x80000000): UART7 0xa9c000, UFS 0x1d80000, GIC 0x16000000, timer
	 * 0x16800000 all fall inside 0x00400000..0x40000000. */
	.io_base = 0x00400000, .io_size = 0x3FC00000,
	.gic_dist = 0x16000000, .gic_redist = 0x16080000,   /* APSS: interrupt-controller@16000000 */
	.uart = 0,                                          /* UART7 is a Qualcomm GENI/QUP, not a PL011: log via xl log */
	.log_other_cpu = 1,
	.cores = 8, .core_shift = 8,                        /* Qualcomm numbers cores in MPIDR Aff1 (shift 8) */
	.small_cores = 0x0,                                 /* bring-up: no slow-core special-casing (8 Elite has no little cluster) */
	.fb_base = 0xFC800000,                              /* GOP framebuffer the UEFI reports (1200x2670, stride 0x12c0) */
};
