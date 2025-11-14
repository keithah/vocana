#!/bin/bash

echo "🎯 Vocana HAL Plugin - Final Installation & Test"
echo "=============================================="

# Check if we have the built files
if [ ! -f ".build/release/Vocana" ]; then
    echo "❌ Vocana app not built. Run: swift build --configuration release"
    exit 1
fi

if [ ! -f ".build/release/VocanaAudioServerPlugin.bundle" ]; then
    echo "❌ HAL plugin not built. Building now..."
    clang -bundle -o ".build/release/VocanaAudioServerPlugin.bundle" \
        Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c \
        -I Sources/VocanaAudioServerPlugin/include \
        -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
        -framework Accelerate -arch arm64 -arch x86_64 -DRELEASE
fi

echo "✅ Build files ready"

# Installation commands (user needs to run with sudo)
echo ""
echo "📦 Installation Commands (run with sudo):"
echo "=========================================="
echo ""
echo "# Remove any existing installation"
echo "sudo rm -rf '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver'"
echo ""
echo "# Create plugin directory"
echo "sudo mkdir -p '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS'"
echo ""
echo "# Copy plugin files"
echo "sudo cp '.build/release/VocanaAudioServerPlugin.bundle' '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS/VocanaAudioServerPlugin'"
echo "sudo cp 'Sources/VocanaAudioServerPlugin/Info.plist' '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/'"
echo ""
echo "# Set permissions"
echo "sudo chown -R root:wheel '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver'"
echo "sudo chmod -R 755 '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver'"
echo ""
echo "# Code sign"
echo "sudo codesign --force --sign - --entitlements 'VocanaAudioServerPlugin.entitlements' '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver'"
echo ""
echo "# Restart audio system"
echo "sudo killall coreaudiod"
echo ""
echo "# Verify installation"
echo "system_profiler SPAudioDataType | grep -i vocana"

echo ""
echo "🧪 Quick Test Commands:"
echo "======================="
echo ""
echo "# Test Vocana app"
echo "./.build/release/Vocana"
echo ""
echo "# Check for devices"
echo "system_profiler SPAudioDataType | grep -A2 -B2 Vocana"
echo ""
echo "# Check coreaudiod logs"
echo "log show --predicate 'process == \"coreaudiod\"' --last 5m | grep -i vocana"

echo ""
echo "🎯 Expected Results:"
echo "=================="
echo "✅ 'Vocana Virtual Audio Device' appears in Audio MIDI Setup"
echo "✅ Device selectable in System Settings > Sound"
echo "✅ Device available in Zoom, Teams, etc."
echo "✅ No more BlackHole dependency"
echo "✅ Vocana app shows connected status"

echo ""
echo "🔧 If Issues Occur:"
echo "==================="
echo "# Check plugin loading:"
echo "log show --predicate 'process == \"coreaudiod\"' --last 5m | grep -i vocana"
echo ""
echo "# Force restart audio:"
echo "sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
echo ""
echo "# Verify permissions:"
echo "ls -la '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/'"
echo ""
echo "# Check signature:"
echo "codesign -dv '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver'"

echo ""
echo "🎉 Ready for Installation!"
echo "=========================="
echo "Run the above sudo commands to install the Vocana HAL plugin."
echo "This will give you a 100% native virtual audio solution with AI noise cancellation!"