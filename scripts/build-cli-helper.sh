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

read -r -a BUILD_ARCHITECTURES <<< "${ARCHS:-$(uname -m)}"
CLI_SLICES=()
for architecture in "${BUILD_ARCHITECTURES[@]}"; do
    slice="${CLI_TEMP_DIR}/browser-cli-${architecture}"
    xcrun swiftc \
        -O \
        -swift-version 6 \
        -warnings-as-errors \
        -sdk "$SDKROOT" \
        -target "${architecture}-apple-macos${MACOSX_DEPLOYMENT_TARGET}" \
        "${SRCROOT}/browser-cli/main.swift" \
        -o "$slice"
    CLI_SLICES+=("$slice")
done

CLI_OUTPUT="${HELPERS_DIR}/browser-cli"
if [ "${#CLI_SLICES[@]}" -eq 1 ]; then
    cp "${CLI_SLICES[0]}" "$CLI_OUTPUT"
else
    lipo -create "${CLI_SLICES[@]}" -output "$CLI_OUTPUT"
fi

if [ "${EXPANDED_CODE_SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$CLI_OUTPUT"
else
    codesign --force --sign - "$CLI_OUTPUT"
fi
