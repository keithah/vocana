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
clang -bundle -o "$BUILD_DIR/VocanaAudioServerPlugin.bundle" \
    Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c \
    -I Sources/VocanaAudioServerPlugin/include \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -framework Accelerate \
    -arch arm64 \
    -arch x86_64 \
    -DDEBUG

# Create bundle structure
echo "Creating bundle structure..."
sudo mkdir -p "$BUNDLE_DIR/Contents/MacOS"
sudo mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Copy the bundle
echo "Copying bundle..."
sudo cp "$BUILD_DIR/VocanaAudioServerPlugin.bundle" "$BUNDLE_DIR/Contents/MacOS/VocanaAudioServerPlugin"

# Copy Info.plist
sudo cp "$PROJECT_DIR/Sources/VocanaAudioServerPlugin/Info.plist" "$BUNDLE_DIR/Contents/"

# Codesign the bundle with entitlements
echo "Codesigning bundle with entitlements..."
sudo codesign --force --sign - --entitlements "$PROJECT_DIR/VocanaAudioServerPlugin.entitlements" "$BUNDLE_DIR"

# Set permissions
sudo chown -R root:wheel "$BUNDLE_DIR"
sudo chmod -R 755 "$BUNDLE_DIR"

echo "Bundle created at $BUNDLE_DIR"
echo "Restarting coreaudiod..."

# Restart coreaudiod
sudo killall coreaudiod 2>/dev/null || true

echo "Done. Check Audio MIDI Setup for Vocana device."