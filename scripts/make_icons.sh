#!/bin/bash
# Script to create a macOS .icns file from a base PNG image

BASE_IMAGE="icon_base.png"
ICONSET="icon.iconset"

if [ ! -f "$BASE_IMAGE" ]; then
    echo "Error: $BASE_IMAGE not found."
    exit 1
fi

mkdir -p "$ICONSET"

# Create different sizes for the iconset
sips -z 16 16     "$BASE_IMAGE" --out "${ICONSET}/icon_16x16.png"
sips -z 32 32     "$BASE_IMAGE" --out "${ICONSET}/icon_16x16@2x.png"
sips -z 32 32     "$BASE_IMAGE" --out "${ICONSET}/icon_32x32.png"
sips -z 64 64     "$BASE_IMAGE" --out "${ICONSET}/icon_32x32@2x.png"
sips -z 128 128   "$BASE_IMAGE" --out "${ICONSET}/icon_128x128.png"
sips -z 256 256   "$BASE_IMAGE" --out "${ICONSET}/icon_128x128@2x.png"
sips -z 256 256   "$BASE_IMAGE" --out "${ICONSET}/icon_256x256.png"
sips -z 512 512   "$BASE_IMAGE" --out "${ICONSET}/icon_256x256@2x.png"
sips -z 512 512   "$BASE_IMAGE" --out "${ICONSET}/icon_512x512.png"
sips -z 1024 1024 "$BASE_IMAGE" --out "${ICONSET}/icon_512x512@2x.png"

# Convert iconset to icns
iconutil -c icns "$ICONSET"

# Cleanup
rm -rf "$ICONSET"

echo "icon.icns created successfully."
