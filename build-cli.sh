#!/bin/bash

# Dev-loop build of the CLI tool. The app's Xcode build compiles and signs
# this same source into Browser.app/Contents/Helpers/browser-cli.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building Straight Up Browser CLI..."

xcrun swiftc \
    -O \
    -swift-version 6 \
    -warnings-as-errors \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target arm64-apple-macos15.6 \
    browser-cli/main.swift \
    -o browser-cli-tool

./scripts/validate-macos-architectures.sh browser-cli-tool
echo "CLI tool built successfully: ./browser-cli-tool"
