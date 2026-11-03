#!/bin/bash
# Require continuous input inactivity immediately before desktop UI automation.
set -euo pipefail

minimum_seconds="${1:-480}"
case "$minimum_seconds" in
    ''|*[!0-9]*) echo "Idle requirement must be positive whole seconds." >&2; exit 64 ;;
esac
if [ "$minimum_seconds" -lt 1 ]; then
    echo "Idle requirement must be greater than zero." >&2
    exit 64
fi
if [ "$(uname -s)" != Darwin ]; then
    echo "The desktop idle gate requires macOS IOHIDSystem." >&2
    exit 1
fi

echo "Waiting for ${minimum_seconds}s of continuous computer inactivity before UI automation..."
while :; do
    idle_nanoseconds="$(/usr/sbin/ioreg -r -c IOHIDSystem | awk '/"HIDIdleTime" = / && !found { print $NF; found = 1 }')"
    case "$idle_nanoseconds" in
        ''|*[!0-9]*)
            echo "Unable to read a valid HID idle time; refusing to start UI automation." >&2
            exit 1
            ;;
    esac
    idle_seconds=$((idle_nanoseconds / 1000000000))
    if [ "$idle_seconds" -ge "$minimum_seconds" ]; then
        echo "Idle gate passed: ${idle_seconds}s of input inactivity."
        exit 0
    fi
    sleep 30
done
