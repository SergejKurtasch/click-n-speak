#!/usr/bin/env bash
# Run the non-destructive Swift acceptance orchestrator with the available Python runtime.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"

if [ ! -x "$PYTHON" ]; then
    echo "Python runtime is required: $PYTHON" >&2
    exit 2
fi

exec "$PYTHON" "$REPO_ROOT/scripts/swift_acceptance.py" "$@"
