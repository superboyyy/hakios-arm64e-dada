#!/bin/bash
# Refresh this repository from the working trees the work happens in (they are only read, never changed):
#   KERNEL_TREE   the HakiOS kernel checkout: loader, tools, docs, configs (its whitelist) + the shared user space
#   GPU2_TREE     $GPU2_TREE/xnu12377 = the dada xnu-12377 tree (git, base commit = xnu-12377.121.6);
#                 $GPU2_TREE/src/{metal2vulkan,nativemetal,mesa} + build scripts = GPU2
# Set them in the environment or in tools/export.local (not in git). Files that may not be published are left out
# (see NOTICE.md); the old project name is written as HakiOS throughout; run tools/check-publishable.sh after.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$R/tools/export.local" ] && . "$R/tools/export.local"
K=${KERNEL_TREE:?set KERNEL_TREE (or tools/export.local)}
G=${GPU2_TREE:?set GPU2_TREE (or tools/export.local)}
X=$G/xnu12377

# Paths of the work trees that never belong here: firmware and binaries of others, Apple's files, build output.
skip() {
	case "$1" in
	prebuilt/*|docs/MILESTONE5-*|docs/milestone4/*|docs/milestone5/*|uefi/files/Binaries/*|uefi/files/Resources/DTBs/*|*.replayed*|xnu/files/bsd/dev/redwood_focaltech_fw.h|*.DS_Store|*/__pycache__/*) return 0 ;;
	esac
	return 1
}
copy_list() { # copy_list SRC DST < list of relative paths
	local src=$1 dst=$2 f
	while IFS= read -r f; do
		skip "$f" && continue
		[ -f "$src/$f" ] || continue
		mkdir -p "$dst/$(dirname "$f")"
		cp -p "$src/$f" "$dst/$f"
	done
}

rm -rf "$R/base" "$R/gpu2" "$R/userland" "$R/kernel/"*.patch "$R/kernel/HISTORY.txt"
mkdir -p "$R/base" "$R/kernel" "$R/gpu2/patches" "$R/userland"

# 1. The HakiOS kernel project as we run it: its whitelist, tracked and new files.
git -C "$K" ls-files --cached --others --exclude-standard | copy_list "$K" "$R/base"

# 2. The user space that shares that working tree (its own repository's files only).
git --git-dir="$K/.userland.git" --work-tree="$K" ls-files --cached | copy_list "$K" "$R/userland"
git --git-dir="$K/.userland.git" --work-tree="$K" ls-files --others --exclude-standard -- userland tools/air tools/mesa tools/metal tools/apfs \
	| copy_list "$K" "$R/userland"

# 3. The dada kernel: one diff against Apple's xnu-12377.121.6 (committed state of the work tree).
base=$(git -C "$X" log --format=%H --grep='^xnu-12377.121.6$' | tail -1)
git -C "$X" diff --binary "$base" HEAD -- . ':(exclude)bsd/dev/redwood_focaltech_fw.h' ':(exclude)*.replayed*' > "$R/kernel/xnu-12377.121.6-dada.patch"
git -C "$X" log --format='%h %ad %s' --date=short "$base..HEAD" > "$R/kernel/HISTORY.txt"

# 4. GPU2: our changes on top of each upstream, as diffs (committed and uncommitted), plus the build scripts.
diff_tree() { # diff_tree REPO BASE OUT: committed and working-tree changes, new files included
	local repo=$1 base=$2 out=$3 f
	git -C "$repo" diff --binary "$base" -- . > "$out"
	git -C "$repo" ls-files --others --exclude-standard | while IFS= read -r f; do
		case "$f" in build/*|*.o|*.dylib|*.a) continue ;; esac
		(cd "$repo" && git diff --no-index --binary /dev/null "$f" || true)
	done >> "$out"
}
diff_tree "$G/src/metal2vulkan" 720ef1c "$R/gpu2/patches/metal2vulkan-720ef1c-dada.patch"
diff_tree "$G/src/nativemetal" "$(git -C "$G/src/nativemetal" rev-list --max-parents=0 HEAD)" "$R/gpu2/patches/nativemetal-dada.patch"
diff_tree "$G/src/mesa" "$(git -C "$G/src/mesa" rev-parse HEAD)" "$R/gpu2/patches/mesa-85fda3b-dada.patch"
cp -p "$G/patches/nativemetal-next/"*.patch "$R/gpu2/patches/" 2>/dev/null || true
mkdir -p "$R/gpu2/patches/metal2vulkan-next" && cp -p "$G/patches/m2v/"*.patch "$R/gpu2/patches/metal2vulkan-next/"
cp -p "$G"/build_bridge.sh "$G"/build_plugin.sh "$G"/build_turnip_ios.sh "$G"/M2V-NEXT.md "$R/gpu2/"
mkdir -p "$R/gpu2/rust" "$R/gpu2/docker" "$R/gpu2/tools"
cp -p "$G/rust/arm64e-apple-ios-pauth.json" "$R/gpu2/rust/"
cp -p "$G/docker/Dockerfile" "$R/gpu2/docker/"
cp -p "$G/tools/"*.py "$R/gpu2/tools/"
{
	echo "metal2vulkan  base 720ef1c (github.com/... metal2vulkan, pinned by Data A Live), head $(git -C "$G/src/metal2vulkan" rev-parse --short HEAD)"
	echo "nativemetal   base $(git -C "$G/src/nativemetal" rev-list --max-parents=0 HEAD | cut -c1-7) (UniXNU AdrenoMetal import), head $(git -C "$G/src/nativemetal" rev-parse --short HEAD)"
	echo "mesa          base $(git -C "$G/src/mesa" rev-parse --short HEAD) (Mesa main)"
	echo "xnu           base xnu-12377.121.6, head $(git -C "$X" rev-parse --short HEAD)"
} > "$R/gpu2/BASES.txt"

# 5. No local paths: scratch directories, home directory, the build user's name in kernel banners.
U=$(id -un)
grep -rlIE "$HOME|/private/tmp/[a-z]+-[0-9]+/|/tmp/cl[a]ude-[0-9]+/|$U:xnu" "$R/base" "$R/userland" "$R/gpu2" "$R/kernel" 2>/dev/null \
	| while IFS= read -r f; do
	sed -i '' -E \
		-e "s#/private/tmp/[a-z]+-[0-9]+/[^/]+/[^/]+/scratchpad/xnu12377#\$HOME/hakios-gpu2/xnu12377#g" \
		-e "s#$HOME#\$HOME#g" \
		-e "s#/tmp/cl[a]ude-[0-9]+/#/tmp/#g" \
		-e "s#$U:xnu#user:xnu#g" "$f"
done
# format-patch headers name the repository's author (git config user.name / user.email)
AUTHOR="$(git -C "$R" config user.name) <$(git -C "$R" config user.email)>"
sed -i '' -E "s#^From: .*<.*>\$#From: $AUTHOR#" "$R/gpu2/patches/"*.patch "$R/gpu2/patches/metal2vulkan-next/"*.patch
# Links to the milestone write-ups and logs, which are not published (skip above)
sed -i '' -e 's# Plan: \[MILESTONE5-ARM64E-REAL-HARDWARE.md\](MILESTONE5-ARM64E-REAL-HARDWARE.md)##' "$R/base/docs/ARM64E.md"
sed -i '' -e 's#; see docs/MILESTONE5-ARM64E-REAL-HARDWARE.md\.#.#' "$R/base/common/devices/dada.conf"

# 6. The project is called HakiOS now (oosexgang/hakios-xnu-kernel; the user space moved into it): the old name in
# every file and path, identifiers included (no hakios name existed before, so nothing collides).
for d in base userland gpu2 kernel; do
	grep -rlIi 'hac[k]ios' "$R/$d" | while IFS= read -r f; do
		sed -i '' -e 's#github.com/oosexgang/hac[k]ios-xnu-userland#github.com/oosexgang/hakios-xnu-kernel#g' \
			-e 's/hac[k]ios/hakios/g' -e 's/Hac[k]iOS/HakiOS/g' -e 's/Hac[k]ios/Hakios/g' -e 's/HAC[K]IOS/HAKIOS/g' "$f"
	done
	find "$R/$d" -depth -iname '*hac[k]ios*' | while IFS= read -r f; do
		b=$(basename "$f" | sed -e 's/hac[k]ios/hakios/g' -e 's/Hac[k]iOS/HakiOS/g' -e 's/Hac[k]ios/Hakios/g' -e 's/HAC[K]IOS/HAKIOS/g')
		mv "$f" "$(dirname "$f")/$b"
	done
done
echo "exported into $R"
