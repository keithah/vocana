#!/bin/bash

set -e

echo "🚀 Vocana HAL Plugin - Complete Installation Script"
echo "=================================================="

# Check if running from correct directory
if [ ! -f "Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c" ]; then
    echo "❌ Error: Must run from vocana project root directory"
    exit 1
fi

echo "📦 Step 1: Building Vocana application..."
swift build --configuration release

echo "🔧 Step 2: Building HAL plugin..."
clang -bundle -o ".build/release/VocanaAudioServerPlugin.bundle" \
    Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c \
    -I Sources/VocanaAudioServerPlugin/include \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -framework Accelerate \
    -arch arm64 \
    -arch x86_64 \
    -DRELEASE

if [ $? -ne 0 ]; then
    echo "❌ Plugin build failed!"
    exit 1
fi

echo "📁 Step 3: Installing HAL plugin..."

# Remove any existing installation
if [ -d "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver" ]; then
    echo "Removing existing plugin..."
    sudo rm -rf "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
fi

# Create directory structure
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS"
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/Resources"

# Copy plugin files
sudo cp ".build/release/VocanaAudioServerPlugin.bundle" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS/VocanaAudioServerPlugin"
sudo cp "Sources/VocanaAudioServerPlugin/Info.plist" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/"

# Set proper ownership and permissions
sudo chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
sudo chmod -R 755 "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

# Code sign the bundle
if [ -f "VocanaAudioServerPlugin.entitlements" ]; then
    sudo codesign --force --sign - --entitlements "VocanaAudioServerPlugin.entitlements" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
else
    echo "⚠️  No entitlements file found, signing without entitlements"
    sudo codesign --force --sign - "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
fi

echo "🔄 Step 4: Restarting audio system..."

# Restart coreaudiod to load the plugin
sudo killall coreaudiod 2>/dev/null || echo "coreaudiod not running"

# Wait for restart
sleep 3

echo "🔍 Step 5: Verifying installation..."

# Check if plugin loaded successfully
echo "Checking coreaudiod logs for Vocana..."
if log show --predicate 'process == "coreaudiod"' --last 2m | grep -q "VocanaHAL"; then
    echo "✅ Plugin loaded successfully!"
    log show --predicate 'process == "coreaudiod"' --last 2m | grep "VocanaHAL"
else
    echo "⚠️  Plugin may not have loaded - checking for errors..."
    log show --predicate 'process == "coreaudiod"' --last 2m | grep -i vocana || echo "No Vocana entries found in logs"
fi

# Check for devices in system profile
echo ""
echo "🎵 Checking for Vocana audio devices..."
if system_profiler SPAudioDataType | grep -q "Vocana"; then
    echo "✅ Vocana devices found!"
    system_profiler SPAudioDataType | grep Vocana
else
    echo "❌ Vocana devices not found in system profile"
fi

echo ""
echo "🧪 Step 6: Testing Vocana application..."

# Test if Vocana app can detect devices
echo "Starting Vocana application to test device detection..."
timeout 10s .build/release/Vocana || echo "Vocana app test completed"

echo ""
echo "🎯 Step 7: Manual verification instructions"
echo "=========================================="
echo ""
echo "1. Open Audio MIDI Setup (Applications > Utilities > Audio MIDI Setup)"
echo "2. Look for 'Vocana Virtual Audio Device' in the device list"
echo "3. If you see it, the HAL plugin is working correctly!"
echo ""
echo "4. Test in applications:"
echo "   - Open System Settings > Sound"
echo "   - Check if 'Vocana Virtual Audio Device' appears as input/output option"
echo "   - Test in Zoom, Teams, or other audio apps"
echo ""
echo "5. Run Vocana app for full functionality:"
echo "   swift run Vocana"
echo ""
echo "🔧 Troubleshooting:"
echo "If devices don't appear:"
echo "  - Check logs: log show --predicate 'process == \"coreaudiod\"' --last 5m | grep -i vocana"
echo "  - Verify permissions: ls -la /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/"
echo "  - Force restart: sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
echo "  - Reinstall: sudo rm -rf /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver && ./install_vocana_plugin.sh"

echo ""
echo "🎉 Installation complete!"
echo "Your Vocana HAL plugin should now be providing native virtual audio devices!"