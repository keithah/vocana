#!/bin/bash

echo "=== Reinstalling Vocana Audio Server Plugin ==="
echo ""

# Check if plugin bundle exists
if [ ! -d "VocanaAudioServerPlugin.driver" ]; then
    echo "Error: Plugin bundle not found!"
    echo "Please build the plugin first."
    exit 1
fi

# Remove old plugin
echo "Removing old plugin..."
if ! sudo rm -rf /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver; then
    echo "Warning: Failed to remove old plugin (may not exist)"
fi

# Install new plugin
echo "Installing new plugin..."
if ! sudo cp -R VocanaAudioServerPlugin.driver /Library/Audio/Plug-Ins/HAL/; then
    echo "Error: Failed to install plugin!"
    exit 1
fi

# Set proper permissions
echo "Setting permissions..."
if ! sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver; then
    echo "Error: Failed to set ownership!"
    exit 1
fi

if ! sudo chmod -R 755 /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver; then
    echo "Error: Failed to set permissions!"
    exit 1
fi

echo "Plugin reinstalled successfully!"
echo ""
echo "To load the plugin, you need to restart your Mac or restart the audio subsystem."
echo "After restart, check for 'Vocana Virtual Microphone' and 'Vocana Virtual Speaker' in:"
echo "- Audio MIDI Setup"
echo "- System Settings → Sound"