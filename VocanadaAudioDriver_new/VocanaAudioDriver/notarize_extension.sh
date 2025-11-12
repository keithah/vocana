#!/bin/bash

set -e

echo "=== DriverKit Extension Notarization Script ==="
echo ""

# Configuration
EXTENSION_PATH="/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/com.vocana.VocanaAudioDriver.dext"
BUNDLE_ID="com.vocana.VocanaAudioDriver"
TEAM_ID="6R7S5GA944"
APPLE_ID="keith@vocana.app"  # Replace with your Apple ID
PASSWORD="@keychain:AC_PASSWORD"  # Or use app-specific password

# Create temporary directory
TEMP_DIR=$(mktemp -d)
echo "Working in: $TEMP_DIR"

# Step 1: Create ZIP archive for notarization
echo "Step 1: Creating ZIP archive..."
ZIP_PATH="$TEMP_DIR/VocanaAudioDriver.zip"
cd "$(dirname "$EXTENSION_PATH")"
ditto -c -k --keepParent "$(basename "$EXTENSION_PATH")" "$ZIP_PATH"

# Step 2: Upload for notarization
echo "Step 2: Uploading for notarization..."
echo "Note: You may be prompted for your Apple ID password"

xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$PASSWORD" \
    --wait \
    --output-format json

# Step 3: Staple the notarization ticket
echo "Step 3: Stapling notarization ticket..."
xcrun stapler staple "$EXTENSION_PATH"

# Step 4: Verify notarization
echo "Step 4: Verifying notarization..."
spctl -a -v "$EXTENSION_PATH"

# Step 5: Copy to user directory
echo "Step 5: Installing to user directory..."
mkdir -p ~/Library/DriverExtensions
cp -R "$EXTENSION_PATH" ~/Library/DriverExtensions/

echo ""
echo "=== Notarization Complete ==="
echo "Extension has been notarized and copied to ~/Library/DriverExtensions/"
echo "Please restart your Mac and check System Settings → Extensions"
echo ""
echo "Run this command to verify installation:"
echo "systemextensionsctl list | grep -i vocana"

# Cleanup
rm -rf "$TEMP_DIR"