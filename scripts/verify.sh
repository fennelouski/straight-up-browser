#!/bin/bash
#
# Runs every build and test gate required before merging or releasing.
#
# Usage: ./scripts/verify.sh
# Override the build cache with DERIVED_DATA_ROOT=/path/to/cache.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Straight Up Browser.xcodeproj"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-build/verification}"
COMMON_SETTINGS=(
    CODE_SIGNING_ALLOWED=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)

echo "Running macOS unit tests..."
xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme "Browser" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_ROOT/macos-tests" \
    -parallel-testing-enabled NO \
    "${COMMON_SETTINGS[@]}"

echo "Building the iOS app..."
xcodebuild build -quiet \
    -project "$PROJECT" \
    -scheme "Browser iOS" \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA_ROOT/ios-build" \
    "${COMMON_SETTINGS[@]}"

echo "Building macOS UI tests..."
xcodebuild build-for-testing -quiet \
    -project "$PROJECT" \
    -scheme "Browser UI" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_ROOT/macos-ui-tests" \
    "${COMMON_SETTINGS[@]}"

echo "All verification gates passed."
