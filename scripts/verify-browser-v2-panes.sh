#!/bin/zsh
set -euo pipefail

TASK_REPOSITORY_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TASK_PACKAGE_ROOT="$(mktemp -d /tmp/browser-v2-pane-tests.XXXXXX)"
TASK_LOG_PATH="${1:-$TASK_REPOSITORY_ROOT/docs/verification/browser-v2-pane-model-tests.log}"
mkdir -p "$TASK_PACKAGE_ROOT/Sources/Browser" "$TASK_PACKAGE_ROOT/Tests/BrowserTests" "$(dirname -- "$TASK_LOG_PATH")"
trap 'rm -rf -- "$TASK_PACKAGE_ROOT"' EXIT

cat > "$TASK_PACKAGE_ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BrowserPaneModelVerification", platforms: [.macOS(.v15)],
    products: [.library(name: "Browser", targets: ["Browser"])],
    targets: [.target(name: "Browser"), .testTarget(name: "BrowserTests", dependencies: ["Browser"])])
SWIFT
cp "$TASK_REPOSITORY_ROOT/Straight Up Browser/BrowserTestProfile.swift" "$TASK_PACKAGE_ROOT/Sources/Browser/BrowserTestProfile.swift"
cp -- "$TASK_REPOSITORY_ROOT/Straight Up Browser/PaneLayout.swift" "$TASK_PACKAGE_ROOT/Sources/Browser/PaneLayout.swift"
cp -- "$TASK_REPOSITORY_ROOT/Straight Up Browser/ColdLayoutStarterScheduler.swift" "$TASK_PACKAGE_ROOT/Sources/Browser/ColdLayoutStarterScheduler.swift"
cp -- "$TASK_REPOSITORY_ROOT/Straight Up BrowserTests/ColdLayoutStarterSchedulerTests.swift" "$TASK_PACKAGE_ROOT/Tests/BrowserTests/ColdLayoutStarterSchedulerTests.swift"
python3 - "$TASK_REPOSITORY_ROOT/Straight Up BrowserTests/PaneLayoutTests.swift" "$TASK_PACKAGE_ROOT/Tests/BrowserTests/PaneLayoutTests.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
marker = "@MainActor\nstruct PaneLayoutTransactionTests"
if source.count(marker) != 1:
    raise SystemExit("Could not identify app-dependent tests; refusing to silently omit tests.")
pathlib.Path(sys.argv[2]).write_text(source.split(marker, 1)[0])
PY

{
    print "Browser v2 pane model verification"
    print "Sources: actual PaneLayout.swift + ColdLayoutStarterScheduler.swift; actual PaneLayoutModelTests + ColdLayoutStarterSchedulerTests."
    print "Excluded: PaneLayoutTransactionTests requires the full Browser app, SwiftData and WebKit."
    print "No package dependencies; temporary package and compiler caches remain under /tmp."
    CLANG_MODULE_CACHE_PATH="$TASK_PACKAGE_ROOT/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$TASK_PACKAGE_ROOT/swift-cache" \
    xcrun swift test --package-path "$TASK_PACKAGE_ROOT" \
        --scratch-path "$TASK_PACKAGE_ROOT/build" \
        --cache-path "$TASK_PACKAGE_ROOT/cache" \
        --config-path "$TASK_PACKAGE_ROOT/config" \
        --security-path "$TASK_PACKAGE_ROOT/security" \
        --disable-sandbox --enable-swift-testing --jobs 2
} 2>&1 | tee "$TASK_LOG_PATH"
