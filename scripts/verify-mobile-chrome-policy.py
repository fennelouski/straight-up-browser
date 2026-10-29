#!/usr/bin/env python3
"""Small offline policy suite. No app build, simulator, signing or stores.

Copies the actual two pure production sources and iOS tests into a temporary
single-job Swift package. HistoryVisit is extracted verbatim from its source.
This does not substitute for the iOS target compile or native UI acceptance.
"""
from pathlib import Path
import argparse
import os
import json
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--filter", help="Run only matching Swift tests, for a focused follow-up")
args = parser.parse_args()

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="browser-mobile-policy-") as folder:
    package = Path(folder)
    source = package / "Sources" / "MobileChromePolicy"
    tests = package / "Tests" / "MobileChromePolicyTests"
    source.mkdir(parents=True)
    tests.mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MobileChromePolicy", targets: [
    .target(name: "MobileChromePolicy", swiftSettings: [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "MobileChromePolicyTests", dependencies: ["MobileChromePolicy"])
])
''')
    for name in ["MobileChromePolicy_iOS.swift", "MobileSuggestions_iOS.swift"]:
        (source / name).write_bytes((root / "Browser iOS" / name).read_bytes())
    history = (root / "Straight Up Browser" / "BrowsingHistoryStore.swift").read_text()
    declaration = history[history.index("nonisolated struct HistoryVisit:"):history.index("/// Local, durable browsing history.")]
    (source / "HistoryVisit.swift").write_text("import Foundation\n" + declaration)
    chrome = (root / "Browser iOS" / "MobilePageChrome_iOS.swift").read_text()
    script = chrome.split('static let fixedEdgeScript = """', 1)[1].split('"""', 1)[0]
    (source / "PageEdgeScript.swift").write_text("nonisolated enum MobilePageEdgeScriptFixture { static let source = " + json.dumps(script) + " }")
    for name in ["MobileChromePolicyTests.swift", "MobilePageEdgeTests.swift"]:
        test = (root / "Browser iOSTests" / name).read_text()
        test = test.replace("@testable import Browser", "@testable import MobileChromePolicy")
        test = test.replace("MobilePageChrome.fixedEdgeScript", "MobilePageEdgeScriptFixture.source")
        (tests / name).write_text(test)
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(package / "module-cache")
    command = ["/usr/bin/xcrun", "swift", "test", "--package-path", str(package), "--jobs", "1", "--disable-sandbox"]
    if args.filter:
        command += ["--filter", args.filter]
    subprocess.run(command, env=env, check=True)
