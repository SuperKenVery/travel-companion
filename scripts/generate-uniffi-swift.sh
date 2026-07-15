#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
library="${1:-$root/target/debug/libtc_app_ffi.a}"
output="$root/bindings/tc-app-ffi/generated"

if [[ "${TC_NIX_DEVSHELL:-}" != "1" ]]; then
  exec nix develop "$root" --command "$0" "$library"
fi

if [[ ! -f "$library" ]]; then
  echo "UniFFI input library does not exist: $library" >&2
  exit 1
fi

mkdir -p "$output"
cd "$root"
cargo run --locked -p tc-app-ffi --features bindgen --bin uniffi-bindgen-swift -- \
  "$library" \
  "$output" \
  --swift-sources \
  --headers
