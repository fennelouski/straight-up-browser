#!/bin/sh
# Executes the production local learning/practice model and its actual acceptance tests.
# The separate PowerUpIntegrationTests requires the app target (Settings + live command sources)
# and remains in the normal Xcode suite. Native UI/IME/media tests are not simulated here.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verification_dir=$(mktemp -d /tmp/browser-v2-powerup.XXXXXX)
trap 'rm -rf "$verification_dir"' EXIT HUP INT TERM
export CLANG_MODULE_CACHE_PATH="$verification_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$verification_dir/module-cache"
mkdir -p "$verification_dir/Sources/Browser" "$verification_dir/Tests/BrowserTests"
cp "$repo/Straight Up Browser/BrowserTestProfile.swift" "$verification_dir/Sources/Browser/BrowserTestProfile.swift"
cp "$repo/Straight Up Browser/PowerUp.swift" "$verification_dir/Sources/Browser/PowerUp.swift"
cp "$repo/Straight Up BrowserTests/PowerUpTests.swift" "$verification_dir/Tests/BrowserTests/PowerUpTests.swift"
cat > "$verification_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BrowserPowerUpVerification", platforms: [.macOS(.v15)], targets: [
    .target(name: "Browser", swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-sandbox"])]),
    .testTarget(name: "BrowserTests", dependencies: ["Browser"], swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-sandbox"])])
])
PACKAGE
swift test --package-path "$verification_dir" --scratch-path "$verification_dir/build" --disable-sandbox --jobs 2
