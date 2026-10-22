"""Prepare a process-local workaround for WebKit bug 293831 on iOS 18.5.

Apple guidance: https://developer.apple.com/forums/thread/785964?answerId=841589022
No runtime files, deployment targets, global settings or app binaries are changed.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def simulator_environment(device):
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True))
    matches = [runtime for runtime, entries in devices["devices"].items()
               for entry in entries if entry["udid"] == device]
    if len(matches) != 1:
        raise ValueError("Select one existing Simulator by its exact UDID")
    runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"], text=True))
    runtime = next(item for item in runtimes["runtimes"] if item["identifier"] == matches[0])
    result = {"runtime": runtime["identifier"], "version": runtime["version"], "environment": {}}
    if runtime.get("platform") != "iOS" or runtime["version"] != "18.5":
        return result
    directory = Path(runtime["runtimeRoot"]) / "System/Cryptexes/OS/usr/lib/swift"
    if not (directory / "libswiftWebKit.dylib").is_file():
        raise FileNotFoundError("The selected iOS 18.5 runtime lacks the bundled WebKit compatibility library; no workaround applied")
    result["environment"] = {"DYLD_FALLBACK_LIBRARY_PATH": str(directory)}
    result["reason"] = "Apple WebKit bug 293831: bundled runtime library is outside the default launch search path"
    return result


def apply_to_target(target, environment):
    # Xcode's documented per-host and UI-target-app environment dictionaries.
    for field in ("EnvironmentVariables", "UITargetAppEnvironmentVariables"):
        if not environment:
            continue
        values = target.setdefault(field, {})
        for name, value in environment.items():
            existing = values.get(name, "")
            parts = existing.split(":") if existing else []
            if value not in parts:
                parts.append(value)
            values[name] = ":".join(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--xctestrun", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if bool(args.xctestrun) != bool(args.output):
        parser.error("--xctestrun and --output must be provided together")
    compatibility = simulator_environment(args.device)
    if args.xctestrun:
        if args.output.exists():
            parser.error("Choose a new output path; an existing test plan will not be overwritten")
        plan = plistlib.loads(args.xctestrun.read_bytes())
        for config in plan["TestConfigurations"]:
            for target in config["TestTargets"]:
                apply_to_target(target, compatibility["environment"])
        args.output.write_bytes(plistlib.dumps(plan))
    print(json.dumps(compatibility, indent=2))


if __name__ == "__main__":
    main()
