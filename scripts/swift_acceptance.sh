#!/usr/bin/env bash
# Run the non-destructive Swift parity acceptance orchestrator inside the project venv.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$REPO_ROOT/venv/bin/python"

if [ ! -x "$PYTHON" ]; then
    echo "Project venv is required: $PYTHON" >&2
    exit 2
fi

exec "$PYTHON" "$REPO_ROOT/scripts/swift_acceptance.py" "$@"
