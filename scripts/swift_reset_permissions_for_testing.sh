#!/usr/bin/env bash
# Reset the two TCC grants used by the Swift app. Developers may opt into this
# after signing when an ad-hoc build's new code requirement invalidates grants.
# Production builds must never call this script.
set -euo pipefail

BUNDLE_ID="com.sergej.clicknspeak"
TCCUTIL_BIN="${CNS_TCCUTIL_BIN:-/usr/bin/tccutil}"

if [ "${1:-}" != "--confirm-reset" ]; then
    echo "Usage: $0 --confirm-reset" >&2
    echo "This removes Microphone and Accessibility grants for $BUNDLE_ID." >&2
    exit 2
fi
if [ ! -x "$TCCUTIL_BIN" ]; then
    echo "tccutil is not executable: $TCCUTIL_BIN" >&2
    exit 1
fi

echo "Resetting Microphone and Accessibility for $BUNDLE_ID"
"$TCCUTIL_BIN" reset Accessibility "$BUNDLE_ID"
"$TCCUTIL_BIN" reset Microphone "$BUNDLE_ID"
echo "Permission reset complete"
