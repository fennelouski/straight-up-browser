#!/bin/bash
#
# Run a command in its own process group and fail if it outlives the supplied
# wall-clock deadline. This protects release verification from an Xcode/XCTest
# launch that never reaches an individual test's timeout.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <positive-seconds> <command> [args...]" >&2
    exit 64
fi

LIMIT_SECONDS="$1"
shift
case "$LIMIT_SECONDS" in
    ''|*[!0-9]*)
        echo "Time limit must be a positive whole number of seconds." >&2
        exit 64
        ;;
esac
if [ "$LIMIT_SECONDS" -lt 1 ]; then
    echo "Time limit must be greater than zero." >&2
    exit 64
fi

# macOS does not ship GNU timeout. A separate session lets the watchdog stop
# xcodebuild and the test processes it owns without signalling this verifier.
exec /usr/bin/perl -e '
    use strict;
    use warnings;
    use POSIX qw(setsid);

    my $limit = shift @ARGV;
    my $program = $ARGV[0];
    my $child = fork();
    die "Unable to start timed command: $!\n" unless defined $child;

    if ($child == 0) {
        setsid() != -1 or die "Unable to create timed command session: $!\n";
        exec { $program } @ARGV;
        die "Unable to execute $program: $!\n";
    }

    my $timed_out = 0;
    $SIG{ALRM} = sub {
        if (!$timed_out) {
            $timed_out = 1;
            warn "Timed command exceeded ${limit}s; stopping its test session.\n";
            kill("TERM", -$child);
            alarm 5;
        } else {
            warn "Timed command did not stop cleanly; force-stopping its test session.\n";
            kill("KILL", -$child);
            alarm 5;
        }
    };

    alarm $limit;
    while (waitpid($child, 0) != $child) {
        die "Unable to wait for timed command: $!\n" if $!;
    }
    alarm 0;

    exit 124 if $timed_out;
    my $status = $?;
    exit 127 if $status == -1;
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
' "$LIMIT_SECONDS" "$@"
