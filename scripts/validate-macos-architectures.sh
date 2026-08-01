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
    for required_arch in arm64 x86_64; do
        if [[ " $architectures " != *" $required_arch "* ]]; then
            echo "Architecture gate failed: $binary has '$architectures'." >&2
            exit 1
        fi
    done
done

echo "Universal architecture gate passed."
