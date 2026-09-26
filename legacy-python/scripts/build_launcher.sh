#!/bin/bash
# Build Click-n-speak as a launcher .app: standalone Python + app code inside .app,
# launcher script runs Python as child process so the app shows as "Click-n-speak" in the system.
set -e

APP_NAME="Click-n-speak"
BUNDLE="dist/${APP_NAME}.app"
RESOURCES="${BUNDLE}/Contents/Resources"
MACOS="${BUNDLE}/Contents/MacOS"
APP_DIR="${RESOURCES}/app"
PYTHON_DIR="${RESOURCES}/python"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIREMENTS="${PROJECT_ROOT}/requirements.txt"

# Python-build-standalone: use astral-sh (successor of indygreg)
PBS_REPO="astral-sh/python-build-standalone"
PBS_PATTERN="cpython-3.11.*-aarch64-apple-darwin-install_only.tar.gz"

echo "=== Click-n-speak Launcher Build ==="

# Step 1: Clean and create .app structure
echo "Step 1: Preparing bundle..."
rm -rf "${BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}" "${APP_DIR}" "${PYTHON_DIR}"

# Step 2: Download python-build-standalone (macOS arm64, Python 3.11)
echo "Step 2: Downloading standalone Python (arm64, 3.11)..."
PBS_JSON=$(curl -sL "https://api.github.com/repos/${PBS_REPO}/releases/latest")
PBS_URL=$(echo "$PBS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    n = a.get('name', '')
    if '3.11' in n and 'aarch64-apple-darwin' in n and 'install_only' in n and n.endswith('.tar.gz') and 'stripped' not in n:
        print(a['browser_download_url'])
        break
")
if [ -z "$PBS_URL" ]; then
    echo "ERROR: Could not find Python 3.11 aarch64-apple-darwin install_only asset."
    exit 1
fi
echo "  Downloading: $PBS_URL"
curl -sL -o /tmp/pbs-python.tar.gz "$PBS_URL"

# Extract: tarball has top-level dir like cpython-3.11.x+.../ with python/ inside
echo "  Extracting..."
TMP_PY=$(mktemp -d)
tar -xzf /tmp/pbs-python.tar.gz -C "$TMP_PY"
# Find the single top-level directory and move its python/ to Resources/python
TOP=$(find "$TMP_PY" -maxdepth 1 -type d ! -path "$TMP_PY" | head -1)
if [ -d "$TOP/python" ]; then
    cp -R "$TOP/python/"* "$PYTHON_DIR/"
else
    # Some layouts put bin/python3 at top level
    cp -R "$TOP/"* "$PYTHON_DIR/"
fi
rm -rf "$TMP_PY" /tmp/pbs-python.tar.gz
echo "  Python installed to ${PYTHON_DIR}"

# Step 3: Copy app code (exclude cache, venv, etc.)
echo "Step 3: Copying application code..."
rsync -a --exclude='__pycache__' --exclude='*.pyc' --exclude='venv' --exclude='.git' \
    --exclude='.env' --exclude='dist' --exclude='build' --exclude='.eggs' \
    "${PROJECT_ROOT}/main.py" "${PROJECT_ROOT}/src" "${PROJECT_ROOT}/config.json" \
    "${APP_DIR}/"
echo "  App code in ${APP_DIR}"

# Step 4: Install dependencies into standalone Python
echo "Step 4: Installing dependencies..."
PYTHON_BIN="${PYTHON_DIR}/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    # Some builds use bin/python3.11
    PYTHON_BIN=$(find "${PYTHON_DIR}/bin" -name 'python*' -type f | head -1)
fi
if [ ! -x "$PYTHON_BIN" ]; then
    echo "ERROR: Could not find python binary in ${PYTHON_DIR}/bin"
    exit 1
fi
# Use requirements_app.txt if available (excludes mlx-lm, py2app, pytest).
# Falls back to requirements.txt with py2app stripped.
APP_REQUIREMENTS="${PROJECT_ROOT}/scripts/requirements_app.txt"
if [ -f "${APP_REQUIREMENTS}" ]; then
    echo "  Using ${APP_REQUIREMENTS}"
    "$PYTHON_BIN" -m pip install --quiet --no-warn-script-location -r "${APP_REQUIREMENTS}"
else
    echo "  Falling back to requirements.txt (stripping py2app)"
    grep -v '^py2app' "$REQUIREMENTS" > /tmp/requirements_launcher.txt
    "$PYTHON_BIN" -m pip install --quiet --no-warn-script-location -r /tmp/requirements_launcher.txt
    rm -f /tmp/requirements_launcher.txt
fi
echo "  Dependencies installed"

# Step 4b: Patch mlx_whisper to remove torch/scipy/numba dependencies.
# torch_whisper.py is never imported — delete it.
# timing.py uses scipy+numba only for word-timestamps (we never enable word_timestamps) — replace with stub.
# Then uninstall the now-unused heavy packages to shrink the bundle.
echo "Step 4b: Patching mlx_whisper and removing unused heavy packages..."
MLX_WHISPER_DIR="${PYTHON_DIR}/lib/python3.11/site-packages/mlx_whisper"

# Remove unused torch_whisper.py (never imported anywhere in mlx_whisper)
rm -f "${MLX_WHISPER_DIR}/torch_whisper.py" "${MLX_WHISPER_DIR}/__pycache__/torch_whisper"*.pyc 2>/dev/null || true

# Replace timing.py with a stub — add_word_timestamps is only called when word_timestamps=True,
# which we never enable; scipy+numba pulled in at module load time would waste 130MB.
cat > "${MLX_WHISPER_DIR}/timing.py" << 'TIMING_STUB'
# Stub: word_timestamps feature disabled — avoids scipy+numba dependencies.
import numpy as np

def add_word_timestamps(*, segments, model, tokenizer, mel, num_frames, **kwargs):
    return segments
TIMING_STUB
rm -f "${MLX_WHISPER_DIR}/__pycache__/timing"*.pyc 2>/dev/null || true

# Uninstall packages that were only needed by torch_whisper.py / timing.py
UNINSTALL_PKGS="torch torchvision torchaudio scipy sympy networkx llvmlite numba mpmath triton"
for pkg in $UNINSTALL_PKGS; do
    "$PYTHON_BIN" -m pip uninstall --quiet -y "$pkg" 2>/dev/null || true
done

# Remove pip and setuptools — not needed at runtime, save ~20MB
"$PYTHON_BIN" -m pip uninstall --quiet -y pip setuptools 2>/dev/null || true

# Clean up .pyc caches and __pycache__ dirs to further reduce size
find "${PYTHON_DIR}/lib/python3.11/site-packages" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "${PYTHON_DIR}/lib/python3.11/site-packages" -name "*.pyc" -delete 2>/dev/null || true

# Patch webrtcvad.py — it uses pkg_resources only for __version__ (setuptools was removed)
WEBRTCVAD_PY="${PYTHON_DIR}/lib/python3.11/site-packages/webrtcvad.py"
if [ -f "$WEBRTCVAD_PY" ]; then
    sed -i '' 's/import pkg_resources//' "$WEBRTCVAD_PY"
    sed -i '' "s/__version__ = pkg_resources.get_distribution('webrtcvad').version/__version__ = '2.0.10'/" "$WEBRTCVAD_PY"
    echo "  Patched webrtcvad.py (removed pkg_resources dependency)"
fi

SIZE_AFTER=$(du -sh "${PYTHON_DIR}/lib/python3.11/site-packages" 2>/dev/null | cut -f1)
echo "  site-packages size after cleanup: ${SIZE_AFTER}"

# Step 5: Compile native C launcher so macOS TCC shows "Click-n-speak" in permission dialogs.
# A bash-script launcher causes TCC to attribute requests to python3, not the app bundle.
# With a compiled binary that execv's into Python, the responsible-process association
# (set by LaunchServices when the .app is opened) is preserved through execv.
echo "Step 5: Compiling native launcher..."
LAUNCHER="${MACOS}/${APP_NAME}"
LAUNCHER_SRC="$(cd "$(dirname "$0")" && pwd)/launcher.c"
cc -arch arm64 -O2 -o "$LAUNCHER" "$LAUNCHER_SRC"
chmod +x "$LAUNCHER"
echo "  Compiled native launcher: $LAUNCHER"

# Step 5b: App icon from assets/CnS.png (falls back to assets/icon_base.png)
ICON_SOURCE=""
if [ -f "${PROJECT_ROOT}/assets/CnS.png" ]; then
    ICON_SOURCE="${PROJECT_ROOT}/assets/CnS.png"
elif [ -f "${PROJECT_ROOT}/assets/icon_base.png" ]; then
    ICON_SOURCE="${PROJECT_ROOT}/assets/icon_base.png"
fi

if [ -n "$ICON_SOURCE" ]; then
    echo "Step 5b: Building app icon..."
    (cd "${PROJECT_ROOT}" && bash "${PROJECT_ROOT}/scripts/make_icons.sh" "$ICON_SOURCE" >/dev/null 2>&1)
    if [ -f "${PROJECT_ROOT}/assets/icon.icns" ]; then
        cp "${PROJECT_ROOT}/assets/icon.icns" "${RESOURCES}/"
        echo "  App icon copied to bundle"
    fi
fi

# Also ship the PNG icon for use in the menu bar (if present).
if [ -f "${PROJECT_ROOT}/assets/CnS.png" ]; then
    cp "${PROJECT_ROOT}/assets/CnS.png" "${RESOURCES}/CnS.png"
fi

# Step 6: Info.plist (version from pyproject.toml)
echo "Step 6: Writing Info.plist..."
VERSION=$(grep -E '^version\s*=' "${PROJECT_ROOT}/pyproject.toml" | sed -E 's/.*["'\'']([^"'\'']+)["'\''].*/\1/' | tr -d ' ')
if [ -z "$VERSION" ]; then
    VERSION="0.1.0"
fi
cat > "${BUNDLE}/Contents/Info.plist" << PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>com.sergej.clicknspeak</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleIconFile</key><string>icon</string>
	<key>LSUIElement</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Click-n-speak records audio from your microphone to transcribe speech into text.</string>
	<key>NSAppleEventsUsageDescription</key><string>Click-n-speak sends keyboard events to type transcribed text into the active application.</string>
	<key>NSAccessibilityUsageDescription</key><string>Click-n-speak uses accessibility to detect global hotkeys and to type transcribed text into any application.</string>
</dict>
</plist>
PLIST_END

# Step 7: Ad-hoc codesign the bundle so macOS Gatekeeper accepts it locally.
# Without signing, the kernel may not preserve the responsible-process association through execv.
echo "Step 7: Signing bundle (ad-hoc)..."
codesign --force --deep --sign - "${BUNDLE}" 2>/dev/null && echo "  Bundle signed" || echo "  Warning: codesign failed (non-critical for local use)"

echo ""
echo "=== Build complete ==="
echo "Bundle: ${BUNDLE}"
echo "Size: $(du -sh "${BUNDLE}" | cut -f1)"
echo ""
echo "To run: open ${BUNDLE}"
echo "To create DMG: bash scripts/make_dmg.sh (after adjusting for launcher .app if needed)"
