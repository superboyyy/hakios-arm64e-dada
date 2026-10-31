#!/bin/bash
# Make the dada UEFI tree: a clone of 7Night-kqx/uefi-dada (Mu-Silicium with dadaPkg) at the commit in BASE,
# with our changes (uefi-dada.patch) on it. base/tools/dada-build.sh expects it at $HOME/dada-uefi-build.
set -e
cd "$(dirname "$(readlink -f "$0")")"
DST=${1:-$HOME/dada-uefi-build}
[ -e "$DST" ] && { echo "uefi-dada/apply.sh: $DST already exists"; exit 1; }
read -r url commit < BASE
git clone "$url" "$DST"
git -C "$DST" checkout -q "$commit"
git -C "$DST" submodule update --init --recursive
git -C "$DST" apply --whitespace=nowarn "$PWD/uefi-dada.patch"
echo "uefi-dada/apply.sh: done in $DST; next: uefi-dada/README.md"
