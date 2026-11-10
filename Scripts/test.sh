#!/usr/bin/env bash
# Adapted from AppClean/Scripts/test.sh: retry only the known Command Line Tools macro failure.
set -uo pipefail
cd "$(dirname "$0")/.."
for attempt in 1 2 3 4 5 6 7 8; do
    output="$(swift test "$@" 2>&1)"
    status=$?
    if grep -q "plugin for module 'TestingMacros' not found" <<<"$output"; then continue; fi
    printf '%s\n' "$output"
    exit "$status"
done
printf '%s\n' "$output"
exit 1
