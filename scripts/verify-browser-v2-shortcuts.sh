#!/bin/zsh
# Model tests only: no Carbon registration, Browser launch or production preferences.
# ShortcutStore tests use uniquely named, isolated UserDefaults suites.
set -euo pipefail
task_repo_root="${0:A:h:h}"
task_harness_root="$(mktemp -d "${TMPDIR:-/tmp}/browser-v2-shortcuts.XXXXXX")"
export CLANG_MODULE_CACHE_PATH="$task_harness_root/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_harness_root/modules"
python3 - "$task_repo_root" "$task_harness_root" <<'PY'
from pathlib import Path
import sys
repo, package = map(Path, sys.argv[1:])
source = package / 'Sources/ShortcutPolicies'
tests = package / 'Tests/ShortcutPoliciesTests'
source.mkdir(parents=True); tests.mkdir(parents=True)
(package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ShortcutPolicies", platforms: [.macOS(.v15)], targets: [
 .target(name: "ShortcutPolicies", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
 .testTarget(name: "ShortcutPoliciesTests", dependencies: ["ShortcutPolicies"])])
''')
# Exact production value, registry, store and diagnostics code. The unrelated
# iPad notification projection and SwiftUI popover are omitted, never replaced.
command = (repo / 'Straight Up Browser/ShortcutCommand.swift').read_text()
command = command[:command.index('// MARK: - Platform command registry')] + command[command.index('// MARK: - Store'):]
(source / 'ShortcutCommand.swift').write_text(command)
diagnostics = (repo / 'Straight Up Browser/ShortcutDiagnostics.swift').read_text()
(source / 'ShortcutDiagnostics.swift').write_text(diagnostics[:diagnostics.index('struct ShortcutIssueButton')] + '#endif\n')
(source / 'GlobalHotkeyRegistration.swift').write_text((repo / 'Straight Up Browser/GlobalHotkeyRegistration.swift').read_text())
# A declared read-only settings fixture supplies only the existing feature
# switches referenced by registry projections. It is not the code under test.
(source / 'SettingsFixture.swift').write_text('''import Foundation
final class SettingsManager {
 static let shared = SettingsManager()
 let aiFeaturesEnabled = true
 let expandBackForwardShortcuts = false
 let overrideWebsiteQuickOpen = true
}
''')
for name in ['ShortcutDiagnosticsTests.swift', 'GlobalHotkeyRegistrationTests.swift']:
    text = (repo / 'Straight Up BrowserTests' / name).read_text()
    (tests / name).write_text(text.replace('@testable import Browser', '@testable import ShortcutPolicies'))
PY
swift test --package-path "$task_harness_root" --jobs 2 --disable-sandbox 2>&1 | tee "$task_harness_root/test-results.log"
echo "Shortcut model harness: $task_harness_root"
