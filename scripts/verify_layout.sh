#!/usr/bin/env bash
set -euo pipefail

SWIFT_APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_paths=(
  "ClickNSpeak/Package.swift"
  "Packages/CNSCore/Package.swift"
  "assets"
  "locales"
  "scripts/swift_verify.sh"
)

for path in "${required_paths[@]}"; do
  if [[ ! -e "${SWIFT_APP_ROOT}/${path}" ]]; then
    echo "Missing Swift application path: ${SWIFT_APP_ROOT}/${path}" >&2
    exit 1
  fi
done

native_scan_paths=(
  "${SWIFT_APP_ROOT}/ClickNSpeak"
  "${SWIFT_APP_ROOT}/Packages"
)

for forbidden in "legacy-python" "swift-app" "venv/bin/python" "root pyproject.toml"; do
  if rg -n --hidden --glob '!/.build/**' --glob '!/.git/**' --glob '!verify_layout.sh' --glob '!test_swift_only_layout.py' "${forbidden}" "${native_scan_paths[@]}"; then
    echo "Forbidden Swift application reference: ${forbidden}" >&2
    exit 1
  fi
done

echo "Swift application layout is self-contained: ${SWIFT_APP_ROOT}"
