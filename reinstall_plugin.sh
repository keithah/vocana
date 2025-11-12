#!/bin/bash

echo "=== Reinstalling Vocana Audio Server Plugin ==="
echo ""

# Remove old plugin
echo "Removing old plugin..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver

# Install new plugin
echo "Installing new plugin..."
sudo cp -R VocanaAudioServerPlugin.driver /Library/Audio/Plug-Ins/HAL/

# Set proper permissions
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver
sudo chmod -R 755 /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver

echo "Plugin reinstalled successfully!"
echo ""
echo "To load the plugin, you need to restart your Mac or restart the audio subsystem."
echo "After restart, check for 'Vocana Virtual Microphone' and 'Vocana Virtual Speaker' in:"
echo "- Audio MIDI Setup"
echo "- System Settings → Sound"