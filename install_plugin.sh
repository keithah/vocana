#!/bin/bash

echo "=== Installing Vocana Audio Server Plugin ==="
echo ""
echo "This will install the virtual audio device plugin to:"
echo "/Library/Audio/Plug-Ins/HAL/"
echo ""
echo "You will be prompted for your administrator password."
echo ""

# Check if plugin exists
if [ ! -d "VocanaAudioServerPlugin.driver" ]; then
    echo "Error: Plugin bundle not found!"
    echo "Please build the plugin first."
    exit 1
fi

# Install plugin
echo "Installing plugin..."
sudo cp -R VocanaAudioServerPlugin.driver /Library/Audio/Plug-Ins/HAL/

if [ $? -eq 0 ]; then
    echo "Plugin installed successfully!"
    echo ""
    echo "Restarting Core Audio..."
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
    
    echo ""
    echo "Installation complete!"
    echo "You should now see 'Vocana Virtual Microphone' and 'Vocana Virtual Speaker' in:"
    echo "- Audio MIDI Setup"
    echo "- System Settings → Sound"
    echo ""
    echo "To test the plugin, run:"
    echo "afrecord -l"
    echo "afplay -l"
else
    echo "Error: Installation failed!"
    exit 1
fi