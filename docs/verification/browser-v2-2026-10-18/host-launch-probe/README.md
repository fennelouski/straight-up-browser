# Hosted XCTest launcher isolation

This disposable diagnostic uses its own bundle identifier, no windows, no
network, no preferences, and no Browser code or dependencies. Its one assertion
only establishes that XCTest connected; it does not test Browser behavior.

The 18 October 2026 run on Xcode 27.0 (27A266a) compiled, then reproduced the
same `IDELaunchServicesLauncher` `childPID > 0` assertion as the baseline Browser
test invocation. Exit status was 134; no test completed. The temporary background
host was terminated only after checking its exact task-owned executable path.
Its app product was unregistered and removed. The installed Browser stayed open.

The scheme also requests the supported PosixSpawn launcher instead of LLDB;
Xcode still took its failing LaunchServices path. No OS/security setting or
system service was changed. This narrows the failure to the host environment or
Xcode launcher; the precise underlying cause remains unproven.

See `../deployment-preflight.json` for the exact bounded command and
`../host-launch-probe.log` for the assertion. Build only outside the repository,
with two jobs and a new result bundle path. Do not treat this failure as an
excuse to waive Browser's release verification gates.
