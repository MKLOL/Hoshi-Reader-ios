#!/usr/bin/env bash
set -euo pipefail

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
manifest="$HOSHI_CORE_SOURCE/Cargo.toml"
output="$SCRIPT_OUTPUT_FILE_0"
target_dir="$SCRIPT_OUTPUT_FILE_1"

if [[ ! -f "$manifest" ]]; then
    echo "error: Hoshi Core source is missing. Run git submodule update --init." >&2
    exit 1
fi
if ! command -v cargo >/dev/null; then
    echo "error: Install Rust with rustup to build Hoshi Core. See README.md." >&2
    exit 1
fi

libraries=()
for arch in $ARCHS; do
    case "$PLATFORM_NAME:$arch" in
        iphoneos:arm64) target=aarch64-apple-ios ;;
        iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) target=x86_64-apple-ios ;;
        *) echo "error: Unsupported Hoshi Core target $PLATFORM_NAME:$arch" >&2; exit 1 ;;
    esac
    cargo build --locked --offline --release --lib --manifest-path "$manifest" \
        --target "$target" --target-dir "$target_dir"
    libraries+=("$target_dir/$target/release/libhoshi_core.a")
done

staging="$target_dir/libhoshi_core.a"
if [[ "${#libraries[@]}" -eq 1 ]]; then
    cp "${libraries[0]}" "$staging"
else
    xcrun lipo -create "${libraries[@]}" -output "$staging"
fi
if ! cmp -s "$staging" "$output"; then
    mv "$staging" "$output"
fi
