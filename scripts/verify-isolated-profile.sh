#!/bin/bash
# Real profile policy tests and process startup probes; never launches Browser.
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
harness="$(mktemp -d "${TMPDIR:-/tmp}/browser-profile-verification.XXXXXX")"
export CLANG_MODULE_CACHE_PATH="$harness/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$harness/modules"
mkdir -p "$harness/Sources/Browser" "$harness/Sources/ProfileProbe" "$harness/Tests/BrowserTests"
for source in BrowserTestProfile BrowserProfileNetwork BrowserProfileWebKit SavedCredentialStore; do
    cp "$repo/Straight Up Browser/$source.swift" "$harness/Sources/Browser/$source.swift"
done
cp "$repo/Straight Up BrowserTests/BrowserTestProfileTests.swift" "$repo/Straight Up BrowserTests/BrowserTestProfileWebKitTests.swift" "$harness/Tests/BrowserTests/"
# The child probe compiles these same sources into its executable module.
cp "$harness/Sources/Browser/"*.swift "$harness/Sources/ProfileProbe/"
cat > "$harness/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BrowserProfileVerification", platforms: [.macOS(.v15)], targets: [
    .target(name: "Browser", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor", "-warnings-as-errors"])]),
    .executableTarget(name: "ProfileProbe", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor", "-warnings-as-errors"])]),
    .testTarget(name: "BrowserTests", dependencies: ["Browser"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
])
SWIFT
cat > "$harness/Sources/ProfileProbe/Probe.swift" <<'SWIFT'
import Foundation
import Security
@main struct Probe {
    static func main() async throws {
        guard BrowserProfile.isIsolated else {
            print("production-selection-only; integrations not invoked")
            return
        }
        let paths = BrowserProfile.paths!
        precondition(BrowserProfile.defaults !== UserDefaults.standard)
        // This disposable helper is not Browser and owns this process-local
        // application domain. Probe one nonce key, never Browser values; remove
        // only that key afterward. This helper is not the shipping app.
        let nonce = "synthetic-profile-defaults-" + UUID().uuidString
        UserDefaults.standard.set("synthetic-sentinel", forKey: nonce)
        defer { UserDefaults.standard.removeObject(forKey: nonce) }
        precondition(UserDefaults.standard.string(forKey: nonce) == "synthetic-sentinel")
        precondition(BrowserProfile.defaults.string(forKey: nonce) == nil)
        precondition(!BrowserProfile.allowsExternalIntegrations)
        precondition(BrowserProfile.allowsFileAccess(paths.downloads.appendingPathComponent("fixture.txt")))
        precondition(!BrowserProfile.allowsFileAccess(paths.root.appendingPathComponent("../outside.txt")))
        precondition(SavedCredentialStore.save(domain: "fixture.invalid", username: "synthetic", password: "synthetic") == errSecInteractionNotAllowed)
        precondition(SavedCredentialStore.password(domain: "fixture.invalid", username: "synthetic") == nil)
        precondition(SavedCredentialStore.usernames(domain: "fixture.invalid").isEmpty)
        precondition(SavedCredentialStore.all().isEmpty)
        SavedCredentialStore.delete(domain: "fixture.invalid", username: "synthetic")
        BrowserProfile.defaults.set("private-value", forKey: "synthetic-profile-probe")
        precondition(!FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("Straight Up Browser/cli.pipe").path))
        let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest)) as! [String: Any]
        precondition(initial["ready"] as? Bool == false)
        // Compile the actual private containment rules without creating a view,
        // window or Browser process. Preparation itself is not UI acceptance.
        try await BrowserProfileWebKit.prepare()
        let configuration = BrowserProfileWebKit.configuration()
        precondition(!configuration.websiteDataStore.isPersistent)
        precondition(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let prepared = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest)) as! [String: Any]
        precondition(prepared["ready"] as? Bool == true)
        BrowserProfile.invalidateManifest()
        print(paths.manifest.path)
        BrowserProfile.defaults.removePersistentDomain(forName: paths.defaultsSuite)
    }
}
SWIFT
xcrun swift test --package-path "$harness" --scratch-path "$harness/build" --cache-path "$harness/cache" --config-path "$harness/config" --security-path "$harness/security" --disable-sandbox --jobs 2
probe="$harness/build/debug/ProfileProbe"
"$probe"
for bad in missing attached traversal duplicate; do
    case "$bad" in
        missing) arguments=(-isolatedTestProfile) ;;
        attached) arguments=(-isolatedTestProfile=unsafe) ;;
        traversal) arguments=(-isolatedTestProfile ../unsafe) ;;
        duplicate) arguments=(-isolatedTestProfile one -isolatedTestProfile two) ;;
    esac
    set +e
    "$probe" "${arguments[@]}" > "$harness/$bad.out" 2> "$harness/$bad.err"
    status=$?
    set -e
    test "$status" -eq 78
    test ! -s "$harness/$bad.out"
done
profile_id="probe-$(uuidgen)"
manifest="$(python3 - "$probe" "$profile_id" <<'PYPROBE'
import subprocess, sys
result = subprocess.run([sys.argv[1], '-isolatedTestProfile', sys.argv[2]],
                        stdout=subprocess.PIPE, text=True, timeout=60)
if result.returncode:
    raise SystemExit(result.returncode)
print(result.stdout, end='')
PYPROBE
)"
python3 - "$manifest" "$profile_id" <<'PY'
import json, pathlib, sys
manifest=pathlib.Path(sys.argv[1]); data=json.loads(manifest.read_text())
assert data['identifier']==sys.argv[2] and data['ready'] is False
assert len(data['executableSHA256'])==64
assert data['externalIntegrations']=='disabled'
assert pathlib.Path(data['storage']['root'])==manifest.parent
assert not pathlib.Path(data['storage']['cliPipe']).exists()
print('Process probes passed: production selection, 4 invalid startups, isolated credential/store/IPC boundaries, real WebKit rule preparation and readiness invalidation.')
PY
printf 'Profile test evidence: %s\n' "$harness"
