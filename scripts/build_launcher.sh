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
# Install requirements excluding py2app (not needed in launcher bundle)
grep -v '^py2app' "$REQUIREMENTS" > /tmp/requirements_launcher.txt
"$PYTHON_BIN" -m pip install --quiet --no-warn-script-location -r /tmp/requirements_launcher.txt
rm -f /tmp/requirements_launcher.txt
echo "  Dependencies installed"

# Step 5: Write launcher script (no exec: run Python as child so process name stays Click-n-speak)
echo "Step 5: Writing launcher script..."
LAUNCHER="${MACOS}/${APP_NAME}"
cat > "$LAUNCHER" << 'LAUNCHER_END'
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOURCES="$APP_PATH/Contents/Resources"
ROOT="$RESOURCES/app"
PYTHON="$RESOURCES/python/bin/python3"
if [ ! -x "$PYTHON" ]; then
    PYTHON=$(find "$RESOURCES/python/bin" -name 'python*' -type f 2>/dev/null | head -1)
fi
export CLICK_N_SPEAK_APP="$APP_PATH"
cd "$ROOT"
"$PYTHON" main.py
LAUNCHER_END
chmod +x "$LAUNCHER"

# Step 5b: App icon from CnS.png (falls back to icon_base.png)
ICON_SOURCE=""
if [ -f "${PROJECT_ROOT}/CnS.png" ]; then
    ICON_SOURCE="${PROJECT_ROOT}/CnS.png"
elif [ -f "${PROJECT_ROOT}/icon_base.png" ]; then
    ICON_SOURCE="${PROJECT_ROOT}/icon_base.png"
fi

if [ -n "$ICON_SOURCE" ]; then
    echo "Step 5b: Building app icon..."
    (cd "${PROJECT_ROOT}" && bash "${PROJECT_ROOT}/scripts/make_icons.sh" "$ICON_SOURCE" >/dev/null 2>&1)
    if [ -f "${PROJECT_ROOT}/icon.icns" ]; then
        cp "${PROJECT_ROOT}/icon.icns" "${RESOURCES}/"
        echo "  App icon copied to bundle"
    fi
fi

# Also ship the PNG icon for use in the menu bar (if present).
if [ -f "${PROJECT_ROOT}/CnS.png" ]; then
    cp "${PROJECT_ROOT}/CnS.png" "${RESOURCES}/CnS.png"
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
	<key>NSMicrophoneUsageDescription</key><string>This app needs access to your microphone to transcribe speech.</string>
	<key>NSAppleEventsUsageDescription</key><string>This app needs to control other apps to inject transcribed text.</string>
</dict>
</plist>
PLIST_END

echo ""
echo "=== Build complete ==="
echo "Bundle: ${BUNDLE}"
echo "Size: $(du -sh "${BUNDLE}" | cut -f1)"
echo ""
echo "To run: open ${BUNDLE}"
echo "To create DMG: bash scripts/make_dmg.sh (after adjusting for launcher .app if needed)"
