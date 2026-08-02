#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

release_script="scripts/release.sh"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! grep -Eq "$pattern" "$release_script"; then
        echo "Release policy violation: $message" >&2
        exit 1
    fi
}

require_pattern 'git status --porcelain' "refuse releases from a dirty worktree"
require_pattern 'git describe --tags --exact-match' "require an exact source tag"
require_pattern 'EXPECTED_TAG=' "bind the source tag to app version and build"
require_pattern 'merge-base --is-ancestor' "require the release commit on origin/main"
require_pattern 'codesign --verify --deep --strict' "verify the exported app signature"
require_pattern 'stapler validate' "validate stapled notarization tickets"
require_pattern 'notarytool history' "preflight the notarization profile"
require_pattern 'find-generic-password' "preflight the Sparkle signing key"
require_pattern 'MOUNT_POINT=' "verify the application from the finished DMG"
require_pattern 'APPCAST_SIGNATURE=' "validate generated update metadata"
require_pattern 'release-provenance\.json' "emit a machine-readable provenance record"
require_pattern 'Browser\.dmg\.sha256' "emit a distributable checksum"
require_pattern 'ARCHS=arm64' "build Apple Silicon-only release archives"
require_pattern 'onlyUsePackageVersionsFromResolvedFile' "enforce the resolved Swift package graph"

echo "Release policy passed."
