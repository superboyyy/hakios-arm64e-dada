#!/bin/bash
# The native Metal bridge (src/nativemetal/bridge/NativeMetalBridge.rs: the metal2vulkan runtime behind a C ABI) as a static library,
# from src/metal2vulkan as it stands (pin 720ef1c + NativeMetal's bridge patches + Data A Live's m2v patches + patches/m2v).
# UniXNU's scripts/build-native-metal-bridge.py and Data A Live's tools/metal/build_plugin.sh, without their exact-patch-set checks.
#   build_bridge.sh host   -> out/bridge/host/libnative_metal_bridge.a   (aarch64-apple-darwin, for the Mac instruments)
#   build_bridge.sh ios    -> out/bridge/ios/libnative_metal_bridge.a    (arm64e-apple-ios: nightly, -Zbuild-std; iOS 26's system
#                                                                         processes that load the plugin are arm64e)
set -euo pipefail
G=$(cd "$(dirname "$0")" && pwd)
WHAT=${1:-host}
M2V=$G/src/metal2vulkan; NM=$G/src/nativemetal; B=$G/build/bridge; OUT=$G/out/bridge/$WHAT
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
mkdir -p "$B" "$OUT"
LLVM_AS=/opt/homebrew/opt/llvm/bin/llvm-as
"$LLVM_AS" -o "$B/runtime_examples.air" "$M2V/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
"$LLVM_AS" -o "$B/function_constant.air" "$M2V/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
# sha2's assembly goes through cc-rs, which treats the pauthtest ABI as Linux musl: the iOS build takes the portable Rust code
SHA2_ASM=', features = ["asm"]'; [ "$WHAT" = ios ] && SHA2_ASM=
cat > "$B/Cargo.toml" <<EOF
[package]
name = "native-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.98"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$NM/bridge/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$M2V/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$M2V/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10"$SHA2_ASM }
[profile.release]
panic = "unwind"
debug = 1
EOF
# the translator source keys the shader cache (PrimeShaders.h): its pin and every change on top of it
RID=$( (git -C "$M2V" rev-parse HEAD; git -C "$M2V" diff HEAD) | shasum -a 256 | cut -c1-32)
export NMB_RUNTIME_ID=$RID NMB_FIXTURE_AIR=$B/runtime_examples.air NMB_FC_AIR=$B/function_constant.air
export IPHONEOS_DEPLOYMENT_TARGET=26.0 MACOSX_DEPLOYMENT_TARGET=14.0
case "$WHAT" in
host)
	cargo +1.98.0 build --release --manifest-path "$B/Cargo.toml" --target aarch64-apple-darwin --target-dir "$G/build/m2v-target"
	cp "$G/build/m2v-target/aarch64-apple-darwin/release/libnative_metal_bridge.a" "$OUT/" ;;
ios)
	# arm64e's pointer authentication (Apple's ABI: indirect calls via blraaz, signed function pointers in data, signed returns),
	# for std as well: without it the Rust code calls C's signed function pointers (Turnip's entry points) with a plain blr and
	# jumps to a non-canonical address (g2vk2: backboardd and mtltest, esr 0x82000004), and hands C unsigned ones its blraaz
	# rejects. rustc honours -Zpointer-authentication only for the pauthtest ABI, so rust/arm64e-apple-ios-pauth.json is the
	# built-in arm64e-apple-ios spec with that ABI (Mach-O output unchanged, cpu subtype arm64e).
	T=$G/rust/arm64e-apple-ios-pauth.json
	PAUTHTEST_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" CC_arm64e_apple_ios_pauth="$(xcrun --sdk iphoneos --find clang)" \
	CFLAGS_arm64e_apple_ios_pauth="-target arm64e-apple-ios26.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)" \
	RUSTFLAGS="-Zpointer-authentication=+calls,+return-addresses,+auth-traps,+intrinsics" \
	cargo +nightly build --release --manifest-path "$B/Cargo.toml" --target "$T" -Zjson-target-spec -Zbuild-std=std,panic_unwind \
		--target-dir "$G/build/m2v-target"
	cp "$G/build/m2v-target/arm64e-apple-ios-pauth/release/libnative_metal_bridge.a" "$OUT/" ;;
*) echo "usage: build_bridge.sh host|ios"; exit 2 ;;
esac
echo "runtime id $RID"
ls -l "$OUT/libnative_metal_bridge.a"
