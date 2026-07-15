#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-Debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${TC_NIX_DEVSHELL:-}" != "1" ]]; then
  exec nix develop "$root" --command "$0" "$configuration"
fi

host_xcrun="${TC_HOST_XCRUN:-/usr/bin/xcrun}"
host_developer_dir="${TC_HOST_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$host_xcrun" || ! -d "$host_developer_dir" ]]; then
  echo "A full Xcode installation is required to build the iPhoneOS artifact." >&2
  exit 1
fi

sdk_root="$(DEVELOPER_DIR="$host_developer_dir" SDKROOT= "$host_xcrun" --sdk iphoneos --show-sdk-path)"
clang="$(DEVELOPER_DIR="$host_developer_dir" SDKROOT= "$host_xcrun" --sdk iphoneos --find clang)"
target="aarch64-apple-ios"

export SDKROOT="$sdk_root"
export DEVELOPER_DIR="$host_developer_dir"
export IPHONEOS_DEPLOYMENT_TARGET="26.0"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$clang"
export CC_aarch64_apple_ios="$clang"
export CFLAGS_aarch64_apple_ios="-isysroot $sdk_root -miphoneos-version-min=26.0"
export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$sdk_root -C link-arg=-miphoneos-version-min=26.0"
# The devShell's pkg-config path contains host macOS libraries. Cross builds
# must link the SQLite supplied by the iPhoneOS SDK instead.
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR

profile="debug"
cargo_args=(build --locked -p tc-app-ffi --target "$target")
if [[ "$configuration" != "Debug" ]]; then
  profile="release"
  cargo_args+=(--release)
fi

cd "$root"
cargo "${cargo_args[@]}"

output="$root/build/ios/$configuration"
mkdir -p "$output"
cp "$root/target/$target/$profile/libtc_app_ffi.a" "$output/libtc_app_ffi.a"
"$root/scripts/generate-uniffi-swift.sh" "$output/libtc_app_ffi.a"
