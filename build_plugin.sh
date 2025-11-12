#!/bin/bash

# Build script for VocanaAudioServerPlugin bundle

set -e

PROJECT_DIR="/Users/keith/src/vocana"
BUILD_DIR="$PROJECT_DIR/.build/debug"
BUNDLE_DIR="/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

echo "Building VocanaAudioServerPlugin..."

# Build the plugin using clang directly
cd "$PROJECT_DIR"
echo "Building VocanaAudioServerPlugin..."
if ! clang -bundle -o "$BUILD_DIR/VocanaAudioServerPlugin.bundle" \
    Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c \
    -I Sources/VocanaAudioServerPlugin/include \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -framework Accelerate \
    -arch arm64 \
    -arch x86_64 \
    -DDEBUG; then
    echo "ERROR: Plugin compilation failed. Please check:"
    echo "  - Ensure clang is installed"
    echo "  - Verify all source files exist"
    echo "  - Check for compilation errors above"
    exit 1
fi

# Create bundle structure
echo "Creating bundle structure..."
if ! sudo mkdir -p "$BUNDLE_DIR/Contents/MacOS"; then
    echo "ERROR: Failed to create bundle directories"
    exit 1
fi

if ! sudo mkdir -p "$BUNDLE_DIR/Contents/Resources"; then
    echo "ERROR: Failed to create bundle resources directory"
    exit 1
fi

# Copy the bundle
echo "Copying bundle..."
if ! sudo cp "$BUILD_DIR/VocanaAudioServerPlugin.bundle" "$BUNDLE_DIR/Contents/MacOS/VocanaAudioServerPlugin"; then
    echo "ERROR: Failed to copy plugin bundle"
    exit 1
fi

# Copy Info.plist
if ! sudo cp "$PROJECT_DIR/Sources/VocanaAudioServerPlugin/Info.plist" "$BUNDLE_DIR/Contents/"; then
    echo "ERROR: Failed to copy Info.plist"
    exit 1
fi

# Codesign the bundle with entitlements
echo "Codesigning bundle with entitlements..."
if ! sudo codesign --force --sign - --entitlements "$PROJECT_DIR/VocanaAudioServerPlugin.entitlements" "$BUNDLE_DIR"; then
    echo "ERROR: Code signing failed. Please check:"
    echo "  - Ensure you have administrator privileges"
    echo "  - Check that the entitlements file exists: $PROJECT_DIR/VocanaAudioServerPlugin.entitlements"
    echo "  - Verify the bundle was created correctly"
    exit 1
fi

# Set permissions
echo "Setting bundle permissions..."
if ! sudo chown -R root:wheel "$BUNDLE_DIR"; then
    echo "ERROR: Failed to set bundle ownership"
    exit 1
fi

if ! sudo chmod -R 755 "$BUNDLE_DIR"; then
    echo "ERROR: Failed to set bundle permissions"
    exit 1
fi

echo "Bundle created successfully at $BUNDLE_DIR"
echo "Restarting coreaudiod..."

# Restart coreaudiod
if ! sudo killall coreaudiod 2>/dev/null; then
    echo "Warning: Could not restart coreaudiod (may not be running)"
fi

echo "Done. Check Audio MIDI Setup for Vocana device."