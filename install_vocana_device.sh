#!/bin/bash

# Vocana Virtual Audio Device Installation Script
# This script installs the VocanaVirtualDevice.driver to the system

echo "🎵 Vocana Virtual Audio Device Installation"
echo "=========================================="

# Check if running with sudo
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script requires sudo privileges to install system audio drivers"
    echo "💡 Please run with: sudo ./install_vocana_device.sh"
    exit 1
fi

# Check if driver exists
if [ ! -d "VocanaVirtualDevice.driver" ]; then
    echo "❌ VocanaVirtualDevice.driver not found in current directory"
    exit 1
fi

# Validate driver bundle structure
if [ ! -f "VocanaVirtualDevice.driver/Contents/MacOS/VocanaVirtualDevice" ]; then
    echo "❌ Driver executable not found"
    exit 1
fi

if [ ! -f "VocanaVirtualDevice.driver/Contents/Info.plist" ]; then
    echo "❌ Driver Info.plist not found"
    exit 1
fi

# Check code signature before installation
echo "🔐 Checking code signature..."
codesign -v VocanaVirtualDevice.driver
if [ $? -ne 0 ]; then
    echo "❌ Driver code signature is invalid"
    exit 1
fi

echo "📦 Installing VocanaVirtualDevice.driver..."

# Copy driver to system HAL plugins directory
cp -r VocanaVirtualDevice.driver /Library/Audio/Plug-Ins/HAL/

if [ $? -eq 0 ]; then
    echo "✅ Driver copied successfully"
else
    echo "❌ Failed to copy driver"
    exit 1
fi

# Set secure permissions (755 for system directory, 644 for files)
chmod 755 /Library/Audio/Plug-Ins/HAL/VocanaVirtualDevice.driver
chmod 644 /Library/Audio/Plug-Ins/HAL/VocanaVirtualDevice.driver/Contents/Info.plist
chmod 755 /Library/Audio/Plug-Ins/HAL/VocanaVirtualDevice.driver/Contents/MacOS
chmod 755 /Library/Audio/Plug-Ins/HAL/VocanaVirtualDevice.driver/Contents/MacOS/VocanaVirtualDevice
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VocanaVirtualDevice.driver

# Verify code signature
echo "🔐 Verifying code signature..."
codesign -dv /Library/Audio/Plug-Ins/HAL/VocanaVirtualDevice.driver
if [ $? -ne 0 ]; then
    echo "❌ Code signature verification failed"
    exit 1
fi

echo "🔧 Restarting Core Audio daemon..."

# Restart Core Audio daemon to load the new driver
launchctl kickstart -k system/com.apple.audio.coreaudiod

if [ $? -eq 0 ]; then
    echo "✅ Core Audio daemon restarted"
else
    echo "⚠️  Core Audio daemon restart may have failed, trying alternative method..."
    # Alternative method
    killall coreaudiod 2>/dev/null || true
    sleep 2
fi

echo "⏳ Waiting for system to recognize the new device..."
sleep 3

# Verify Core Audio daemon is running
if ! pgrep -x coreaudiod > /dev/null; then
    echo "⚠️  Core Audio daemon not running, attempting to start..."
    launchctl start system/com.apple.audio.coreaudiod
    sleep 2
    if ! pgrep -x coreaudiod > /dev/null; then
        echo "❌ Failed to start Core Audio daemon"
        exit 1
    fi
    echo "✅ Core Audio daemon started successfully"
fi

# Test if the device is available
echo "🔍 Checking for VocanaVirtualDevice..."

# Run our test script to verify installation
if [ -f "test_virtual_device.swift" ]; then
    swift test_virtual_device.swift
else
    echo "⚠️  Test script not found, but installation should be complete"
fi

echo ""
echo "🎉 Installation complete!"
echo "💡 You should now see 'VocanaVirtualDevice' in your audio device list"
echo "📱 Check System Settings > Sound to see and select the device"