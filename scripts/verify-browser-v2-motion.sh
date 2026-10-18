#!/bin/zsh
# Executes the production fade policy and window geometry tests without launching
# Browser or writing to the user's application/preferences. Requires Xcode Swift.
set -euo pipefail
task_repo_root="${0:A:h:h}"
task_harness_root="$(mktemp -d "${TMPDIR:-/tmp}/browser-v2-motion.XXXXXX")"
export CLANG_MODULE_CACHE_PATH="$task_harness_root/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_harness_root/modules"

python3 - "$task_repo_root" "$task_harness_root" <<'PY'
from pathlib import Path
import sys

repo, package = map(Path, sys.argv[1:])
source = package / 'Sources/MotionPolicies'
tests = package / 'Tests/MotionPoliciesTests'
source.mkdir(parents=True)
tests.mkdir(parents=True)
(package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MotionPolicies", platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MotionPolicies", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
        .testTarget(name: "MotionPoliciesTests", dependencies: ["MotionPolicies"])
    ])
''')
for name in ['PageFadeCircuitBreaker.swift', 'WindowPlacementPolicy.swift', 'PageFadeLifecycleInbox.swift']:
    (source / name).write_text((repo / 'Straight Up Browser' / name).read_text())

# Extract the unchanged production WindowLayout and its NSRect extension, omitting
# BrowserWindowMotion and WindowChrome, which are unrelated to the policy tests.
window = (repo / 'Straight Up Browser/WindowManager.swift').read_text()
window = 'import AppKit\n' + window[window.index('enum WindowLayout {'):]
# Only the untested persistence methods refer to BrowserWindows. No window is
# created and no frame is applied by the deterministic test methods.
window += '''
final class BrowserWindows {
    struct Record { let id: UUID }
    static let shared = BrowserWindows()
    var records: [Record] = []
    var activeID: UUID? { nil }
    func window(_ id: UUID) -> NSWindow? { nil }
}
'''
(source / 'WindowLayout.swift').write_text(window)
for name in ['PageFadeCircuitBreakerTests.swift', 'WindowLayoutTests.swift', 'PageFadeLifecycleInboxTests.swift']:
    content = (repo / 'Straight Up BrowserTests' / name).read_text()
    (tests / name).write_text(content.replace('@testable import Browser', '@testable import MotionPolicies'))
PY

print "Motion policy harness: $task_harness_root"
xcrun swift test --package-path "$task_harness_root" \
    --jobs 2 \
    --scratch-path "$task_harness_root/build" --cache-path "$task_harness_root/cache" \
    --config-path "$task_harness_root/config" --security-path "$task_harness_root/security" \
    --disable-sandbox 2>&1 | tee "$task_harness_root/test-results.log"
