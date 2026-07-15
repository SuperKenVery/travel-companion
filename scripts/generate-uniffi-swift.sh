#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
library="${1:-$root/target/debug/libapp_ffi.a}"
output="$root/bindings/app-ffi/generated"

nix_bin="${TC_HOST_NIX:-/nix/var/nix/profiles/default/bin/nix}"
if [[ "${TC_NIX_DEVSHELL:-}" != "1" ]] || ! command -v cargo >/dev/null 2>&1; then
  if [[ ! -x "$nix_bin" ]]; then
    echo "Nix is required at $nix_bin to generate the UniFFI Swift bindings." >&2
    exit 1
  fi
  exec "$nix_bin" develop "$root" --command "$0" "$library"
fi

if [[ ! -f "$library" ]]; then
  echo "UniFFI input library does not exist: $library" >&2
  exit 1
fi

mkdir -p "$output"
rm -f "$output"/*.swift "$output"/*.h
cd "$root"
cargo run --locked -p app-ffi --features bindgen --bin uniffi-bindgen-swift -- \
  "$library" \
  "$output" \
  --swift-sources \
  --headers
