#!/bin/bash
# The NativeMetal plugin for dada's iOS 26 as RedwoodMetal.bundle: the kernel's IOAcceleratorES names MetalPluginName
# "RedwoodMetal", and Metal falls back to the bundle's NSPrincipalClass (NativeAdrenoMetalDevice) when the named class is
# not in it. Data A Live's tools/metal/build_plugin.sh moved to arm64e-apple-ios26.0, with our already-built pieces:
# out/bridge/ios (build_bridge.sh ios) and out/turnip (build_turnip_ios.sh), Turnip inside the bundle next to the
# executable (turnip::libraryPath), and glslangValidator for the smoke shaders.
#   build_plugin.sh   -> out/plugin/RedwoodMetal.bundle, out/plugin/mtltest
set -euo pipefail
G=$(cd "$(dirname "$0")" && pwd)
U=$G/src/unixnu; NM=$G/src/nativemetal; NA=$G/src/nativeadreno; MESA=$G/src/mesa; DAL=$G/src/data-a-live
OUT=$G/out/plugin; B=$G/build/plugin
mkdir -p "$OUT" "$B/gen"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
BASE=(-target arm64e-apple-ios26.0 -isysroot "$SDK" -O2 -g -fstack-protector-strong)
BRIDGE=$G/out/bridge/ios/libnative_metal_bridge.a
TURNIP=$G/out/turnip/libvulkan_freedreno.dylib
for f in "$BRIDGE" "$TURNIP"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done

{
	echo '// Generated from NativeMetal/shaders by build_plugin.sh; do not edit.'
	echo '#pragma once'
	echo '#include <stdint.h>'
	for s in "$NM"/shaders/smoke_*; do
		n=$(basename "$s")
		glslangValidator -V --target-env vulkan1.1 -o "$B/$n.spv" "$s" >/dev/null
		spirv-val --target-env vulkan1.1 "$B/$n.spv"
		python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); w=struct.unpack("<%dI" % (len(d)//4), d)
print("static const uint32_t kSpv_%s[] = {" % sys.argv[2].replace(".", "_"))
for i in range(0, len(w), 8): print("    " + ", ".join("0x%08x" % x for x in w[i:i+8]) + ",")
print("};")' "$B/$n.spv" "$n"
	done
} > "$B/gen/NativeTurnipShaders.h"

BUNDLE=$OUT/RedwoodMetal.bundle
rm -rf "$BUNDLE"; mkdir -p "$BUNDLE"
xcrun clang "${BASE[@]}" -std=c11 -c "$G/src/adrenopm4/AdrenoPM4.c" -o "$B/AdrenoPM4.o"
xcrun clang++ "${BASE[@]}" -std=c++17 -fobjc-arc -Wno-deprecated-declarations -bundle \
	-I "$NA" -I "$G/src/adrenopm4" -I "$MESA/include" -I "$B/gen" \
	-x objective-c++ "$NM/NativeAdrenoMetalPlugin.mm" "$NM/NativeBridgeMetalFrontend.mm" -x none \
	"$B/AdrenoPM4.o" "$BRIDGE" -Wl,-dead_strip -lobjc -framework Foundation -framework Metal -framework IOSurface \
	-framework CoreFoundation -o "$BUNDLE/RedwoodMetal"
xcrun strip -x "$BUNDLE/RedwoodMetal"
rm -rf "$BUNDLE/RedwoodMetal.dSYM"
cp "$TURNIP" "$BUNDLE/libvulkan_freedreno.dylib"
plutil -create xml1 "$BUNDLE/Info.plist"
for kv in CFBundleIdentifier=com.apple.RedwoodMetal CFBundleExecutable=RedwoodMetal CFBundlePackageType=BNDL \
	CFBundleVersion=1 CFBundleShortVersionString=1 NSPrincipalClass=NativeAdrenoMetalDevice MinimumOSVersion=26.0; do
	plutil -insert "${kv%%=*}" -string "${kv#*=}" "$BUNDLE/Info.plist"
done
echo "*" > "$OUT/NativeAdrenoMetal.clients"   # beside the bundle (requestedPath)
codesign -s - -f --identifier com.apple.RedwoodMetal "$BUNDLE/RedwoodMetal"
codesign -s - -f "$BUNDLE/libvulkan_freedreno.dylib"

xcrun -sdk iphoneos metal -mios-version-min=16.0 -c "$DAL/tools/metal/mtltest.metal" -o "$B/mtltest.air"
xcrun -sdk iphoneos metallib "$B/mtltest.air" -o "$B/mtltest.metallib"
(cd "$B" && xxd -i mtltest.metallib > gen/mtltest_metallib.h)
xcrun clang "${BASE[@]}" -fobjc-arc -Wall -I "$B/gen" "$DAL/tools/metal/mtltest.m" \
	-framework Foundation -framework Metal -framework IOSurface -o "$OUT/mtltest"
codesign -s - -f "$OUT/mtltest"
otool -L "$BUNDLE/RedwoodMetal" | head -12
ls -l "$BUNDLE" "$OUT/mtltest"
