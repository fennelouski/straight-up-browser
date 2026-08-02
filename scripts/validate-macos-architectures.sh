#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <Mach-O binary> [binary ...]" >&2
    exit 2
fi

for binary in "$@"; do
    if [ ! -f "$binary" ]; then
        echo "Architecture gate failed: missing $binary" >&2
        exit 1
    fi
    architectures="$(lipo -archs "$binary")"
    if [ "$architectures" != "arm64" ]; then
        echo "Architecture gate failed: $binary must be arm64-only, found '$architectures'." >&2
        exit 1
    fi
done

echo "Apple Silicon architecture gate passed."
