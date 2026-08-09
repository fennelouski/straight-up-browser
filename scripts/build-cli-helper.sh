#!/bin/bash

set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?}"
: "${CONTENTS_FOLDER_PATH:?}"
: "${SRCROOT:?}"
: "${TARGET_TEMP_DIR:?}"
: "${SDKROOT:?}"
: "${MACOSX_DEPLOYMENT_TARGET:?}"

HELPERS_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
CLI_TEMP_DIR="${TARGET_TEMP_DIR}/browser-cli"
mkdir -p "$HELPERS_DIR" "$CLI_TEMP_DIR"

CLI_OUTPUT="${HELPERS_DIR}/browser-cli"
xcrun swiftc \
    -O \
    -swift-version 6 \
    -warnings-as-errors \
    -sdk "$SDKROOT" \
    -target "arm64-apple-macos${MACOSX_DEPLOYMENT_TARGET}" \
    "${SRCROOT}/Straight Up Browser/AgentToolCatalog.swift" \
    "${SRCROOT}/browser-cli/main.swift" \
    "${SRCROOT}/browser-cli/MCPServer.swift" \
    -o "$CLI_OUTPUT"

if [ "${EXPANDED_CODE_SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$CLI_OUTPUT"
else
    codesign --force --sign - "$CLI_OUTPUT"
fi
