#!/bin/bash
# Build script for Click-n-speak macOS application
# This script handles the full build + post-build fixups for native libraries
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
if [ "${CNS_ALLOW_LEGACY_CLEAN:-}" != "1" ]; then
    echo "Refusing legacy cleanup without CNS_ALLOW_LEGACY_CLEAN=1." >&2
    exit 2
fi

APP_NAME="Click-n-speak"
BUNDLE="${REPO_ROOT}/dist/${APP_NAME}.app"
RESOURCES="${BUNDLE}/Contents/Resources"
LIB_DIR="${RESOURCES}/lib/python3.11"
FRAMEWORKS="${BUNDLE}/Contents/Frameworks"
BUILD_DIR="${REPO_ROOT}/build"
DIST_DIR="${REPO_ROOT}/dist"
EGGS_DIR="${REPO_ROOT}/.eggs"

echo "=== Click-n-speak Build Script ==="

# Step 1: Clean previous build
echo "Step 1: Cleaning previous build..."
# Strip macOS Sequoia's com.apple.provenance xattr that prevents deletion of signed bundles
xattr -r -d com.apple.provenance "${BUILD_DIR}" "${DIST_DIR}" 2>/dev/null || true
chmod -R u+w "${BUILD_DIR}" "${DIST_DIR}" 2>/dev/null || true
rm -rf "${BUILD_DIR}" "${DIST_DIR}" "${EGGS_DIR}" 2>/dev/null || true

# If it still exists, try to at least clear its contents
if [ -d "${DIST_DIR}" ]; then
    rm -rf "${DIST_DIR}"/* 2>/dev/null || true
fi

# Final check: we only fail if an actual .app is blocking us
if [ -d "${BUNDLE}" ]; then
    echo "  ERROR: Could not clean ${BUNDLE}. Run manually:"
    echo "    sudo xattr -r -d com.apple.provenance ${DIST_DIR} && sudo rm -rf ${DIST_DIR}"
    exit 1
fi

PYTHON_EXEC="${REPO_ROOT}/venv/bin/python"

# Step 2: Run py2app using /tmp to bypass macOS provenance restrictions
echo "Step 2: Running py2app in /tmp..."
rm -rf /tmp/cns_bdist /tmp/cns_dist 2>/dev/null
mkdir -p /tmp/cns_bdist /tmp/cns_dist

"${PYTHON_EXEC}" "${REPO_ROOT}/setup.py" py2app --bdist-base /tmp/cns_bdist --dist-dir /tmp/cns_dist

# Move the built app back to our local dist/ folder
mkdir -p "${DIST_DIR}"
mv /tmp/cns_dist/*.app "${DIST_DIR}/"

# Update variables for post-build steps
BUNDLE="${DIST_DIR}/${APP_NAME}.app"
RESOURCES="${BUNDLE}/Contents/Resources"
LIB_DIR="${RESOURCES}/lib/python3.11"
FRAMEWORKS="${BUNDLE}/Contents/Frameworks"

# Step 3: Post-build fixups — copy entire mlx package
echo "Step 3: Fixing MLX package (py2app doesn't fully copy C-extension packages)..."

# Find the mlx package source in the venv
MLX_SRC=$("${PYTHON_EXEC}" -c "
import importlib.util
spec = importlib.util.find_spec('mlx')
if spec and spec.submodule_search_locations:
    print(list(spec.submodule_search_locations)[0])
")

if [ -n "${MLX_SRC}" ] && [ -d "${MLX_SRC}" ]; then
    echo "  Found mlx source at: ${MLX_SRC}"

    # Remove the incomplete mlx from the zip
    echo "  Removing incomplete mlx from python311.zip..."
    cd "${LIB_DIR}"
    "${PYTHON_EXEC}" -c "
import zipfile, os, tempfile, shutil
zip_path = '../python311.zip'
if os.path.exists(zip_path):
    tmp = tempfile.mktemp(suffix='.zip')
    with zipfile.ZipFile(zip_path, 'r') as zin:
        with zipfile.ZipFile(tmp, 'w') as zout:
            for item in zin.infolist():
                if not item.filename.startswith('mlx/'):
                    data = zin.read(item.filename)
                    zout.writestr(item, data)
    shutil.move(tmp, zip_path)
    print('  Removed mlx/ entries from zip')
"
    cd - > /dev/null

    # Copy the entire mlx package to the lib directory
    echo "  Copying full mlx package..."
    rm -rf "${LIB_DIR}/mlx"
    cp -R "${MLX_SRC}" "${LIB_DIR}/mlx"

    # Also ensure lib-dynload/mlx/lib has the dylib (for @rpath resolution)
    MLX_CORE_DIR="${LIB_DIR}/lib-dynload/mlx"
    if [ -d "${MLX_CORE_DIR}" ]; then
        # core.so looks for @rpath/libmlx.dylib -> mlx/lib/libmlx.dylib
        mkdir -p "${MLX_CORE_DIR}/lib"
        if [ -f "${MLX_SRC}/lib/libmlx.dylib" ]; then
            cp "${MLX_SRC}/lib/libmlx.dylib" "${MLX_CORE_DIR}/lib/"
            echo "  Copied libmlx.dylib to lib-dynload/mlx/lib/"
        fi
    fi

    echo "  ✅ MLX package copied successfully"
else
    echo "  ⚠️  WARNING: Could not find mlx source directory!"
fi

# Step 3b: Copy numba stub (mlx_whisper/timing.py uses @numba.jit but numba is not installed)
echo "Step 3b: Installing numba stub module..."
NUMBA_STUB_SRC="${SCRIPT_DIR}/numba_stub/__init__.py"
NUMBA_DEST="${LIB_DIR}/numba"
mkdir -p "${NUMBA_DEST}"
cp "${NUMBA_STUB_SRC}" "${NUMBA_DEST}/__init__.py"
echo "  ✅ numba stub installed"

# Step 3c: Replace py2app's generic "applet" stub with a custom C launcher.
# The applet binary reports its internal name as "applet" which causes macOS TCC
# to show "applet" in Input Monitoring settings instead of "Click-n-speak".
echo "Step 3c: Compiling and installing custom launcher..."
LAUNCHER_SRC="${SCRIPT_DIR}/launcher_py2app.c"
LAUNCHER_BIN="${BUNDLE}/Contents/MacOS/${APP_NAME}"
if cc -arch arm64 -O2 -o "${LAUNCHER_BIN}" "${LAUNCHER_SRC}" 2>&1; then
    chmod +x "${LAUNCHER_BIN}"
    echo "  ✅ Custom launcher installed (replaces py2app applet)"
else
    echo "  ⚠️  Launcher compile failed — keeping py2app applet (TCC will show 'applet')"
fi

# Step 4: Re-sign the bundle (copying new files invalidates the signature)
# Sign each .so/.dylib individually first — --deep misses some nested binaries on macOS 15+
echo "Step 4: Re-signing bundle..."

repair_liblzma() {
    local target="$1"
    local source

    source=$("${PYTHON_EXEC}" -c '
from pathlib import Path
import PIL

candidate = Path(PIL.__file__).parent / ".dylibs" / "liblzma.5.dylib"
if candidate.is_file():
    print(candidate)
')
    if [ -z "${source}" ] || [ ! -f "${source}" ]; then
        echo "  ERROR: Could not locate a clean Pillow liblzma.5.dylib" >&2
        return 1
    fi

    echo "  Repairing malformed py2app liblzma from ${source}"
    cp "${source}" "${target}"
    xattr -d com.apple.provenance "${target}" 2>/dev/null || true
    codesign --remove-signature "${target}" 2>/dev/null || true
    install_name_tool \
        -id "@executable_path/../Frameworks/$(basename "${target}")" \
        "${target}"
    codesign --force --sign - "${target}"
}

failed=0
while IFS= read -r f; do
    if ! codesign --force --sign - "$f" 2>&1; then
        if [[ "$(basename "$f")" == liblzma*.dylib ]] && repair_liblzma "$f"; then
            echo "  ✅ Repaired and signed $f"
        else
            echo "  ERROR: failed to sign $f" >&2
            failed=$((failed + 1))
        fi
    fi
done < <(find "${BUNDLE}" \( -name "*.so" -o -name "*.dylib" \))
if [ "$failed" -gt 0 ]; then
    echo "  ERROR: ${failed} binary/binaries failed to sign" >&2
    exit 1
fi

# py2app may modify its multiprocessing helper after the linker applies an
# ad-hoc signature. Re-sign every Mach-O launcher/helper before sealing the app.
while IFS= read -r executable; do
    codesign --force --sign - "${executable}"
done < <(find "${BUNDLE}/Contents/MacOS" -type f -perm +111)

codesign --force --sign - "${BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}"
echo "  ✅ Bundle signature verified"

# Step 5: Verify
echo ""
echo "=== Build Complete ==="
echo "Bundle size: $(du -sh "${BUNDLE}" | cut -f1)"
echo ""
echo "Checking critical files:"
# Check mlx package
MLX_FILES=$(find "${LIB_DIR}/mlx" -name "*.py" -o -name "*.pyc" -o -name "*.so" 2>/dev/null | wc -l | tr -d ' ')
echo "  📦 mlx package: ${MLX_FILES} files"
find "${BUNDLE}" -name "libmlx*.dylib" 2>/dev/null | while read f; do echo "  ✅ $(basename $f) -> $f"; done
find "${BUNDLE}" -name "libportaudio*" 2>/dev/null | while read f; do echo "  ✅ $(basename $f) -> $f"; done

echo ""
echo "Resetting TCC permissions (ad-hoc signature changes on every build)..."
BUNDLE_ID="com.sergej.clicknspeak"
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null && echo "  ✅ Accessibility reset" || echo "  ⚠️  Accessibility reset failed (may need sudo)"
tccutil reset ListenEvent "${BUNDLE_ID}" 2>/dev/null && echo "  ✅ Input Monitoring reset" || echo "  ⚠️  Input Monitoring reset failed (may need sudo)"
# Remove stale path-based TCC entries from old launchers (e.g. Launch-ClickNSpeak.app/applet)
TCC_DB="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
if [ -f "${TCC_DB}" ]; then
    sqlite3 "${TCC_DB}" "DELETE FROM access WHERE client LIKE '%applet' AND client NOT LIKE 'com.%';" 2>/dev/null && echo "  ✅ Stale path-based TCC entries removed" || true
fi
echo "  → Re-add the app in System Settings after launching."

echo ""
echo "To test, run:"
echo "  ./${BUNDLE}/Contents/MacOS/${APP_NAME}"
