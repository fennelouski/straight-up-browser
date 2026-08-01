#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

workflow=".github/workflows/ci.yml"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! grep -Eq "$pattern" "$workflow"; then
        echo "CI policy violation: $message" >&2
        exit 1
    fi
}

require_pattern '^permissions:$' "declare least-privilege workflow permissions"
require_pattern '^  contents: read$' "grant only read access to repository contents"
require_pattern '^concurrency:$' "cancel superseded runs with a concurrency group"
require_pattern '^  DEVELOPER_DIR: /Applications/Xcode_16\.4\.app/Contents/Developer$' \
    "pin the Xcode toolchain"
require_pattern 'uses: actions/checkout@[0-9a-f]{40}' \
    "pin actions/checkout to an immutable commit"

if grep -Eq 'uses: [^ ]+@(main|master|v[0-9]+)$' "$workflow"; then
    echo "CI policy violation: mutable action reference found" >&2
    exit 1
fi

echo "CI workflow policy passed."
