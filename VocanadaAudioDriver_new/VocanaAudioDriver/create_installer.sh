#!/bin/bash

echo "Creating Vocana DriverKit installer package..."

# Create package directory structure
mkdir -p "/tmp/vocana_installer/Library/DriverExtensions"

# Copy extension to package structure
cp -R "/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/com.vocana.VocanaAudioDriver.dext" "/tmp/vocana_installer/Library/DriverExtensions/"

# Create package
pkgbuild \
    --root "/tmp/vocana_installer" \
    --identifier "com.vocana.VocanaAudioDriver.installer" \
    --version "1.0" \
    --install-location "/" \
    --ownership preserve \
    --scripts "/tmp/vocana_scripts" \
    "/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/VocanaAudioDriver.pkg"

echo "Package created: VocanaAudioDriver.pkg"
echo "Double-click this package to install the driver."

# Cleanup
rm -rf "/tmp/vocana_installer"