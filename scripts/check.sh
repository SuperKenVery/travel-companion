#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${TC_NIX_DEVSHELL:-}" != "1" ]]; then
  exec nix develop "$root" --command "$0"
fi

cd "$root"
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
xcodegen generate
host_xcodebuild="${TC_HOST_XCODEBUILD:-/usr/bin/xcodebuild}"
host_developer_dir="${TC_HOST_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# mkShell intentionally provides Nix's native compiler wrappers for Rust build
# dependencies.  Xcode also imports environment variables as build settings,
# though, so values such as `LD=ld` would make SwiftPM invoke the linker binary
# where it expects the clang driver.  Keep the Nix PATH for the Rust build phase
# while letting Xcode select every Apple compiler tool itself.
/usr/bin/env \
  -u AR \
  -u AS \
  -u CC \
  -u CPP \
  -u CXX \
  -u LD \
  -u LDPLUSPLUS \
  -u NM \
  -u OBJCOPY \
  -u RANLIB \
  -u SDKROOT \
  -u STRIP \
  -u TOOLCHAINS \
  DEVELOPER_DIR="$host_developer_dir" \
  "$host_xcodebuild" \
  -quiet \
  -project TravelCompanion.xcodeproj \
  -scheme TravelCompanion \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
