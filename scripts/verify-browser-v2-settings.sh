#!/bin/bash
# Run the real core implementation and its checked-in acceptance tests without
# launching the app test host. Shared policy/catalog sources are compiled whole;
# the Foundation-only entry-point enum and CLI authorization declarations are
# extracted verbatim from their app source owners, never replaced by stubs.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/browser-v2-settings.XXXXXX")"
trap 'rm -rf -- "$harness_dir"' EXIT

mkdir -p "$harness_dir/Sources/Browser" "$harness_dir/Tests/BrowserTests"
cp "$repo_dir/Straight Up Browser/SettingsAssistant.swift" "$harness_dir/Sources/Browser/SettingsAssistant.swift"
cp "$repo_dir/Straight Up Browser/AgentToolCatalog.swift" "$harness_dir/Sources/Browser/AgentToolCatalog.swift"
cp "$repo_dir/Straight Up Browser/AgentPolicyEngine.swift" "$harness_dir/Sources/Browser/AgentPolicyEngine.swift"
awk '/^nonisolated enum AgentRunEntryPoint:/ { include=1 } include { print } include && /^}/ { exit }' \
    "$repo_dir/Straight Up Browser/AgentRunModels.swift" > "$harness_dir/Sources/Browser/AgentRunEntryPoint.swift"
cat > "$harness_dir/Sources/Browser/CLIAuthorization.swift" <<'IMPORTS'
import Foundation
IMPORTS
awk '/^enum CLICapability:/ { include=1 } /^class BrowserCLI/ { exit } include { print }' \
    "$repo_dir/Straight Up Browser/BrowserCLI.swift" >> "$harness_dir/Sources/Browser/CLIAuthorization.swift"
cp "$repo_dir/Straight Up BrowserTests/SettingsAssistantTests.swift" "$harness_dir/Tests/BrowserTests/SettingsAssistantTests.swift"
cat > "$harness_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BrowserV2SettingsVerification",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Browser", targets: ["Browser"])],
    targets: [
        .target(name: "Browser"),
        .testTarget(name: "BrowserTests", dependencies: ["Browser"]),
    ]
)
PACKAGE

swift test --disable-sandbox --jobs 2 --package-path "$harness_dir" \
    -Xswiftc -module-cache-path -Xswiftc "$harness_dir/ModuleCache"
