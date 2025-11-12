#!/bin/bash

echo "Installing Vocana DriverKit Extension..."
echo "You will be prompted for your administrator password."

# Copy the extension to system directory
sudo cp -R "/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/com.vocana.VocanaAudioDriver.dext" "/Library/DriverExtensions/"

# Set proper permissions
sudo chown -R root:wheel "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext"
sudo chmod -R 755 "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext"

# Trigger system extension scan
sudo touch /Library/DriverExtensions

echo "Installation complete. Checking extension status..."
systemextensionsctl list | grep vocana

echo ""
echo "To see driver logs, run:"
echo "log stream --predicate 'subsystem == \"com.apple.iokit\"' --info"
echo ""
echo "To check if the driver loaded, look for:"
echo "'VocanaAudioDriver: Starting audio driver'"