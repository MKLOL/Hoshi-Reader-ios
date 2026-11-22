#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

dependency=Dependencies/HoshiReaderAndroid
source_dir="${HOSHI_CORE_SOURCE:-$dependency/shared/hoshi-core}"
if [[ -z "${HOSHI_CORE_SOURCE:-}" ]]; then
    git submodule update --init -- "$dependency"
fi
cargo fetch --locked --manifest-path "$source_dir/Cargo.toml" --offline 2>/dev/null ||
    cargo fetch --locked --manifest-path "$source_dir/Cargo.toml"
