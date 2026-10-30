#!/bin/bash
# Turnip (Mesa freedreno Vulkan) with UniXNU's Darwin kernel backend, cross-built for iOS 26 arm64e:
# Data A Live's tools/turnip/build_ios.sh with the target moved from arm64 iOS 16 to arm64e iOS 26 (backboardd and
# the other system processes that load it are arm64e). Sources: src/mesa with UniXNU's patches and Data A Live's
# tweaks applied; src/nativeadreno for the ABI header.
#   build_turnip_ios.sh            -> out/turnip/libvulkan_freedreno.dylib, out/turnip/vktest
set -euo pipefail
G=$(cd "$(dirname "$0")" && pwd)
MESA=$G/src/mesa; ABI=$G/src/nativeadreno; OUT=$G/out/turnip; B=$G/build/turnip-ios
export PATH=$G/venv/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH
mkdir -p "$OUT" "$B"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos --find clang); CXX=$(xcrun --sdk iphoneos --find clang++)
AR=$(xcrun --sdk iphoneos --find ar); STRIP=$(xcrun --sdk iphoneos --find strip)
FLAGS="['-target', 'arm64e-apple-ios26.0', '-isysroot', '$SDK', '-fstack-protector-strong']"
cat > "$B/ios.cross" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
objc = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '/usr/bin/false'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64e'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = $FLAGS
cpp_args = $FLAGS
objc_args = $FLAGS
c_link_args = $FLAGS
cpp_link_args = $FLAGS
objc_link_args = $FLAGS
EOF
OPTIONS=(-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=darwin "-Dtu-darwin-abi-dir=$ABI"
	-Dplatforms=macos -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled
	-Dgles2=disabled -Dllvm=disabled -Dshared-glapi=disabled -Dxmlconfig=disabled -Dshader-cache=enabled
	-Dtools= -Dbuild-tests=false -Dvideo-codecs= -Dvulkan-layers= -Dlibunwind=disabled -Dlmsensors=disabled
	-Dvalgrind=disabled -Dexpat=disabled -Dzstd=disabled -Dbuildtype=release -Db_ndebug=true
	-Dtu-builtin-source-id=dada -Dtu-builtin-pack-header=)
if [ ! -f "$B/tu/build.ninja" ]; then
	env CC="$CC" CXX="$CXX" CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS= \
		meson setup "$B/tu" "$MESA" --cross-file "$B/ios.cross" --wrap-mode=nodownload "${OPTIONS[@]}"
fi
# The disk cache's identity of this Turnip: its sources (commit and local changes), not the library's mtime, which every image's copy
# changes (Mesa's default on Darwin): the pipeline pack an earlier boot exported then still matches (tools/m2vpack.py)
BUILD_ID=$( (cd "$MESA" && git rev-parse HEAD && git diff) | shasum -a 256 | cut -c1-40)
if ! grep -q "TU_BUILD_ID_OVERRIDE=\"$BUILD_ID\"" "$B/tu/build.ninja" 2>/dev/null; then
	meson configure "$B/tu" -Dtu-build-id="$BUILD_ID" >/dev/null
fi
echo "turnip build id $BUILD_ID"
ninja -C "$B/tu" src/freedreno/vulkan/libvulkan_freedreno.dylib
LIB=$OUT/libvulkan_freedreno.dylib
cp "$B/tu/src/freedreno/vulkan/libvulkan_freedreno.dylib" "$LIB"
install_name_tool -id /usr/lib/libvulkan_freedreno.dylib "$LIB"
"$STRIP" -x "$LIB"
nm -gU "$LIB" | grep -q ' T _vk_icdGetInstanceProcAddr' || { echo "no vk_icdGetInstanceProcAddr"; exit 1; }
VK=$G/src/data-a-live/tools/vktest
glslangValidator -V --target-env vulkan1.1 --vn fill_spv -o "$B/fill_spv.h" "$VK/fill.comp"
glslangValidator -V --target-env vulkan1.1 --vn tri_vert_spv -o "$B/tri_vert_spv.h" "$VK/tri.vert"
glslangValidator -V --target-env vulkan1.1 --vn tri_frag_spv -o "$B/tri_frag_spv.h" "$VK/tri.frag"
# dada: the driver from the image's share directory (VK_DRIVER overrides), and Turnip's conservative gen8 start (Data A Live:
# no GMEM, no concurrent binning) unless TU_DEBUG is already set
python3 - "$VK/vktest.c" "$B/vktest.c" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace('#define DRIVER "/usr/lib/libvulkan_freedreno.dylib"', '#define DRIVER "/redwood/share/gpu2/libvulkan_freedreno.dylib"')
a = 'void *drv = dlopen(DRIVER, RTLD_NOW | RTLD_LOCAL);'
assert s.count(a) == 1
s = s.replace(a, 'setenv("TU_DEBUG", "sysmem,nocb,startup", 0);\n\tvoid *drv = dlopen(getenv("VK_DRIVER") ? getenv("VK_DRIVER") : DRIVER, RTLD_NOW | RTLD_LOCAL);')
open(sys.argv[2], 'w').write(s)
PY
"$CC" -target arm64e-apple-ios26.0 -isysroot "$SDK" -O2 -Wall -I "$MESA/include" -I "$B" -I "$VK" "$B/vktest.c" -o "$OUT/vktest"
codesign -s - -f "$LIB" "$OUT/vktest"
lipo -info "$LIB" "$OUT/vktest"
otool -L "$LIB" | head -8
ls -l "$LIB" "$OUT/vktest"
