# Licences and third-party notices

## Our work

- `kernel/xnu-12377.121.6-dada.patch` modifies and extends Apple's xnu, published under the Apple Public Source
  License 2.0, and is distributed under the same licence (`LICENSES/APSL-2.0.txt`).
- `base/` and `userland/` are HakiOS (hakios-xnu-kernel; the user space has since moved into it) with our changes; they keep
  HakiOS's licence (`base/LICENSE`, APSL 2.0).
- `tools/` of this repository and the documentation written for it: MIT (`LICENSES/MIT.txt`).

## Files inside the kernel patch that keep their own licence

- `bsd/miscfs/apfs/libdeflate/`, `apfs_deflate.c`: libdeflate, MIT (Eric Biggers; Google LLC)
- `bsd/miscfs/apfs/libzbitmap/`, `apfs_zbitmap.c`: libzbitmap, GPL-2.0+ OR MIT, taken under MIT (Corellium LLC)
- `bsd/dev/hakios_mhi_boot.c` and other files marked so: from UniXNU, BSD-2-Clause-Patent

## UEFI (uefi-dada/)

`uefi-dada/uefi-dada.patch` changes [7Night-kqx/uefi-dada](https://github.com/7Night-kqx/uefi-dada) (Mu-Silicium,
BSD-2-Clause-Patent) and is distributed under the same licence; `apply.sh`, `Dockerfile` and the README there are
MIT like `tools/`. The device drivers that tree builds with (its `Binaries` submodule) are not in this repository.

## GPU patches (gpu2/)

Each patch is distributed under the licence of the project it changes:

| Patch | Project | Licence |
| --- | --- | --- |
| `metal2vulkan-720ef1c-dada.patch`, `metal2vulkan-next/` | metal2vulkan | GPL-2.0-or-later OR LGPL-3.0-or-later |
| `nativemetal-dada.patch`, `020*.patch` | UniXNU NativeMetal / AdrenoMetal | MIT |
| `mesa-85fda3b-dada.patch` | Mesa (Turnip, freedreno) | MIT |

The NativeMetal bundle links metal2vulkan: whoever distributes a built bundle must offer the corresponding
metal2vulkan source under its licence.

## Linux

Our drivers (`hakios_dada_*.c`, `RedwoodGPU.cpp`, ...) name the Linux drivers whose register layouts and bring-up
order they follow (msm/adreno, qcom clocks and PHYs, cs35l41, spi-geni, ...). They are written for xnu, not copied.
The Wi-Fi build script (`base/tools/mk-ath12k.sh`) fetches Linux's ath12k (BSD-3-Clause-Clear) and the MHI host and
QMI code (GPL-2.0) at build time; none of that source is in this repository, and a kernel built with it should not
be distributed as a binary.

## Excluded from this repository

Firmware and binaries of others are never part of it (`tools/export-from-work.sh` leaves them out and
`tools/check-publishable.sh` looks for them): Apple's iOS files and shaders, Qualcomm/Xiaomi firmware (ADSP, GPU,
Wi-Fi, Bluetooth, touch), device trees, prebuilt UEFI drivers, and the touch firmware header
`redwood_focaltech_fw.h` (make it from your own phone with `tools/mk-focaltech-fw.py`).
