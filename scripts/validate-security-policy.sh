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
# MCP OAuth uses a one-shot, IPv4-loopback-only callback listener on an
# OS-assigned ephemeral port. Keep the matching sandbox entitlement in the
# release gate so authorization cannot regress into a fixed-port or custom-URL
# workaround that no longer implements the native-app OAuth profile.
require_entitlement 'com.apple.security.network.server'
require_entitlement 'com.apple.security.files.downloads.read-write'
require_entitlement 'com.apple.security.files.user-selected.read-write'
require_entitlement 'com.apple.security.assets.pictures.read-write'

if ! grep -q 'Library/Containers' browser-cli/main.swift; then
    echo "Security policy violation: CLI does not target sandbox Application Support." >&2
    exit 1
fi

# `agent-tasks.json` is a retired, content-bearing schema. Production may only
# identify it for bounded migration/parsing and deletion after the sanitized
# schedule snapshot is durable. It must never regain an executable writer.
LEGACY_TASK_REFERENCE_COUNT="$({
    grep -R --include='*.swift' -h 'agent-tasks\.json' 'Straight Up Browser' || true
} | wc -l | tr -d '[:space:]')"
if [ "$LEGACY_TASK_REFERENCE_COUNT" != "4" ]; then
    echo "Security policy violation: unexpected agent-tasks.json production reference." >&2
    exit 1
fi
if grep -R --include='*.swift' -l 'agent-tasks\.json' 'Straight Up Browser' \
    | grep -Ev '/(AgentLegacyImporter|AgentLegacyMigrationCoordinator|BrowserAgent)\.swift$' \
    | grep -q .; then
    echo "Security policy violation: retired scheduler source escaped its migration allowlist." >&2
    exit 1
fi
if grep -q 'BrowserAgentLegacyScheduler' 'Straight Up Browser/BrowserAgent.swift' \
    || grep -Eq 'storeURL.*agent-tasks\.json|write\(to: legacyURL' \
        'Straight Up Browser/BrowserAgent.swift'; then
    echo "Security policy violation: retired scheduler source has a production writer." >&2
    exit 1
fi

echo "Security policy passed."
