#!/bin/bash
# Build script for Click-n-speak macOS application
# This script handles the full build + post-build fixups for native libraries
set -e

APP_NAME="Click-n-speak"
BUNDLE="dist/${APP_NAME}.app"
RESOURCES="${BUNDLE}/Contents/Resources"
LIB_DIR="${RESOURCES}/lib/python3.11"
FRAMEWORKS="${BUNDLE}/Contents/Frameworks"

echo "=== Click-n-speak Build Script ==="

# Step 1: Clean previous build
echo "Step 1: Cleaning previous build..."
# Strip macOS Sequoia's com.apple.provenance xattr that prevents deletion of signed bundles
xattr -r -d com.apple.provenance build dist 2>/dev/null || true
find build dist -name ".DS_Store" -delete 2>/dev/null || true
chmod -R u+w build dist 2>/dev/null || true
rm -rf build dist .eggs 2>/dev/null || true
if [ -d "dist" ]; then
    echo "  ERROR: Could not clean dist/. Run manually:"
    echo "    sudo xattr -r -d com.apple.provenance dist && sudo rm -rf dist"
    exit 1
fi

PYTHON_EXEC="python3"

# Step 2: Run py2app using /tmp to bypass macOS provenance restrictions
echo "Step 2: Running py2app in /tmp..."
rm -rf /tmp/cns_bdist /tmp/cns_dist 2>/dev/null
mkdir -p /tmp/cns_bdist /tmp/cns_dist

"${PYTHON_EXEC}" setup.py py2app --bdist-base /tmp/cns_bdist --dist-dir /tmp/cns_dist

# Move the built app back to our local dist/ folder
mkdir -p dist
mv /tmp/cns_dist/*.app dist/

# Update variables for post-build steps
BUNDLE="dist/${APP_NAME}.app"
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
NUMBA_STUB_SRC="$(cd "$(dirname "$0")" && pwd)/numba_stub/__init__.py"
NUMBA_DEST="${LIB_DIR}/numba"
mkdir -p "${NUMBA_DEST}"
cp "${NUMBA_STUB_SRC}" "${NUMBA_DEST}/__init__.py"
echo "  ✅ numba stub installed"

# Step 4: Re-sign the bundle (copying new files invalidates the signature)
echo "Step 4: Re-signing bundle..."
codesign --force --deep --sign - "${BUNDLE}" 2>/dev/null || echo "  Warning: codesign failed (non-critical for local use)"

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
echo "To test, run:"
echo "  ./${BUNDLE}/Contents/MacOS/${APP_NAME}"
