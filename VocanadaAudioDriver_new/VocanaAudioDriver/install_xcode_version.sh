#!/bin/bash

echo "=== Installing Vocana DriverKit Extension (Xcode Built) ==="
echo ""
echo "This version includes your provisioning profile."
echo ""

# Copy the Xcode-built extension (with provisioning profile) to system directory
echo "Copying extension to /Library/DriverExtensions/..."
sudo cp -R "/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/VocanaAudioDriver_Xcode.dext" "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext"

# Set proper ownership and permissions
echo "Setting permissions..."
sudo chown -R root:wheel "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext"
sudo chmod -R 755 "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext"

# Trigger system to recognize the extension
echo "Triggering system extension scan..."
sudo touch /Library/DriverExtensions

echo ""
echo "Installation complete!"
echo ""
echo "Checking extension status..."
systemextensionsctl list | grep -E "(vocana|Vocana)" || echo "Extension not yet visible in system extensions list"

echo ""
echo "To monitor driver logs, run:"
echo "log stream --predicate 'subsystem == \"com.apple.iokit\"' --info"
echo ""
echo "Look for: 'VocanaAudioDriver: Starting audio driver'"