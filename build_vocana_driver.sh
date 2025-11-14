#!/bin/bash

# Build script for Vocana Virtual Audio Device
# Based on BlackHole build process

set -e

echo "=== Building Vocana Virtual Audio Device ==="

# Configuration
PROJECT_NAME="VocanaVirtualDevice"
BUNDLE_NAME="VocanaVirtualDevice.driver"
INSTALL_PATH="/Library/Audio/Plug-Ins/HAL"

# Clean previous builds
echo "Cleaning previous builds..."
rm -rf ".build/release/${PROJECT_NAME}.bundle"
rm -rf "${PROJECT_NAME}.driver"

# Create driver bundle structure
echo "Creating driver bundle..."
mkdir -p "${PROJECT_NAME}.driver/Contents/MacOS"
mkdir -p "${PROJECT_NAME}.driver/Contents/Resources"

# Compile driver as bundle
echo "Compiling driver..."
clang -c \
    -o "${PROJECT_NAME}.o" \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -framework Accelerate \
    -DDEBUG=0 \
    -O3 \
    "Sources/VocanaAudioDriver/VocanaVirtualDevice.c"

# Link driver as bundle
echo "Linking driver..."
clang -bundle \
    -o "${PROJECT_NAME}.driver/Contents/MacOS/${PROJECT_NAME}" \
    "${PROJECT_NAME}.o" \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -framework Accelerate

# Clean up object file
rm "${PROJECT_NAME}.o"

# Copy Info.plist
cp "Sources/VocanaAudioDriver/Info.plist" "${PROJECT_NAME}.driver/Contents/"

# Set proper permissions
chmod 755 "${PROJECT_NAME}.driver/Contents/MacOS/${PROJECT_NAME}"

# Code sign with developer identity (if available) or ad-hoc for development
echo "Code signing..."
if codesign --verify --verbose "${PROJECT_NAME}.driver" 2>/dev/null; then
    echo "✅ Driver already properly signed"
else
    # Try to find a development certificate
    DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | grep -o '"[^"]*"' | head -1 | tr -d '"')
    if [ -n "$DEVELOPER_ID" ]; then
        echo "Using developer certificate: $DEVELOPER_ID"
        codesign --force --sign "$DEVELOPER_ID" "${PROJECT_NAME}.driver"
    else
        echo "⚠️  No developer certificate found, using ad-hoc signing"
        codesign --force --sign - "${PROJECT_NAME}.driver"
    fi
fi

echo "✅ Build complete: ${PROJECT_NAME}.driver"
echo ""
echo "To install:"
echo "sudo cp -r \"${PROJECT_NAME}.driver\" \"${INSTALL_PATH}/\""
echo "sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
echo ""
echo "To uninstall:"
echo "sudo rm -rf \"${INSTALL_PATH}/${BUNDLE_NAME}\""
echo "sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"