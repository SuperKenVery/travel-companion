#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-Debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"

nix_bin="${TC_HOST_NIX:-/nix/var/nix/profiles/default/bin/nix}"
# Xcode can inherit the devShell marker from the process that launched it while
# replacing PATH for build phases. Treat the marker as valid only when Cargo is
# actually available; otherwise enter the devShell again via Nix's stable host
# path rather than relying on Xcode's restricted PATH.
if [[ "${TC_NIX_DEVSHELL:-}" != "1" ]] || ! command -v cargo >/dev/null 2>&1; then
  if [[ ! -x "$nix_bin" ]]; then
    echo "Nix is required at $nix_bin to build the Rust iPhoneOS artifact." >&2
    exit 1
  fi
  exec "$nix_bin" develop "$root" --command "$0" "$configuration"
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
cargo_args=(build --locked -p app-ffi --target "$target")
if [[ "$configuration" != "Debug" ]]; then
  profile="release"
  cargo_args+=(--release)
fi

cd "$root"
cargo "${cargo_args[@]}"

output="$root/build/ios/$configuration"
mkdir -p "$output"
cp "$root/target/$target/$profile/libapp_ffi.a" "$output/libapp_ffi.a"
"$root/scripts/generate-uniffi-swift.sh" "$output/libapp_ffi.a"
