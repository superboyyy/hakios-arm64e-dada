# UEFI for dada

The Xiaomi 15 boots through Mu-Silicium UEFI, started from the stock bootloader with `fastboot boot` (nothing is
flashed). The dada port is [7Night-kqx/uefi-dada](https://github.com/7Night-kqx/uefi-dada), a Mu-Silicium tree with
`dadaPkg`; we only add the hook that starts our XNU loader.

What is here:

- `BASE`: the uefi-dada repository and commit our changes are made on;
- `uefi-dada.patch`: our changes to it:
  `BootShim/BootShim.S` (copies the "XNUP" payload that follows the UEFI image to `PAYLOAD_BASE`, and sizes the
  image so the bootloader loads the payload too),
  `BootManagerLib` (`XnuLoader.[ch]`: starts the XNU loader from that payload instead of the boot menu);
- `apply.sh`: clones uefi-dada at `BASE` (with its submodules) and applies the patch;
- `Dockerfile`: the build environment (`hakios-uefi`).

The device drivers come from uefi-dada's `Binaries` submodule (7Night-kqx/Device-Binaries), fetched by
`apply.sh`; they are not part of this repository.

## Building

```sh
uefi-dada/apply.sh                                    # -> $HOME/dada-uefi-build
docker build -t hakios-uefi -f uefi-dada/Dockerfile $HOME/dada-uefi-build
docker run --rm -v $HOME/dada-uefi-build:/work -w /work hakios-uefi \
    python3 build_uefi.py -d dada -r RELEASE          # -> Build/dadaPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd
```

Then `base/tools/dada-build.sh loader` builds the XNU loader and packs the shim, the UEFI image and the loader
into `base/out/dada-usb.img` (the addresses come from dadaPkg's memory map: FD at `0xA7100000`, size `0x300000`,
payload at `0xA8000000`, boot image header version 4).

## Licence

uefi-dada and Mu-Silicium are BSD-2-Clause-Patent; `uefi-dada.patch` is under the same licence.
