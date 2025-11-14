#!/bin/bash

# Installation commands for VocanaAudioServerPlugin
# Run these commands with sudo privileges

echo "Installing VocanaAudioServerPlugin..."

# Create bundle directory
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS"
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/Resources"

# Copy the plugin bundle
sudo cp ".build/debug/VocanaAudioServerPlugin.bundle" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS/VocanaAudioServerPlugin"

# Copy Info.plist
sudo cp "Sources/VocanaAudioServerPlugin/Info.plist" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/"

# Set proper ownership and permissions
sudo chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
sudo chmod -R 755 "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

# Code sign the bundle
sudo codesign --force --sign - --entitlements "VocanaAudioServerPlugin.entitlements" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

echo "Restarting coreaudiod..."
sudo killall coreaudiod 2>/dev/null || echo "coreaudiod not running, will start automatically"

echo "Installation complete!"
echo "Check Audio MIDI Setup for Vocana devices."