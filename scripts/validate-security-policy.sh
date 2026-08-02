#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_FILE="Straight Up Browser.xcodeproj/project.pbxproj"
ENTITLEMENTS_FILE="Browser.entitlements"

if grep -q 'ENABLE_APP_SANDBOX = NO;' "$PROJECT_FILE"; then
    echo "Security policy violation: the macOS app sandbox is disabled." >&2
    exit 1
fi

SANDBOX_CONFIGURATION_COUNT="$(
    grep -c 'ENABLE_APP_SANDBOX = YES;' "$PROJECT_FILE"
)"
if [ "$SANDBOX_CONFIGURATION_COUNT" -lt 2 ]; then
    echo "Security policy violation: sandboxing must cover Debug and Release." >&2
    exit 1
fi

require_entitlement() {
    local key="$1"
    if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS_FILE")" != "true" ]; then
        echo "Security policy violation: missing $key entitlement." >&2
        exit 1
    fi
}

require_entitlement 'com.apple.security.app-sandbox'
require_entitlement 'com.apple.security.network.client'
require_entitlement 'com.apple.security.files.downloads.read-write'
require_entitlement 'com.apple.security.files.user-selected.read-write'
require_entitlement 'com.apple.security.assets.pictures.read-write'

if ! grep -q 'Library/Containers' browser-cli/main.swift; then
    echo "Security policy violation: CLI does not target sandbox Application Support." >&2
    exit 1
fi

echo "Security policy passed."
