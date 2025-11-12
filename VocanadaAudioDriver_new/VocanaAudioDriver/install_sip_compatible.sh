#!/bin/bash

echo "=== Manual DriverKit Extension Installation (SIP Compatible) ==="
echo ""
echo "Since SIP is enabled, we need to use System Settings GUI method."
echo ""

echo "Step 1: Open System Settings"
echo "1. Open System Settings (or System Preferences)"
echo "2. Go to 'General' → 'Login Items & Extensions'"
echo "3. Look for 'DriverKit Extensions' section"
echo ""

echo "Step 2: Alternative Method - Copy to User Directory"
echo "1. Copy extension to user directory first:"
echo "   mkdir -p ~/Library/DriverExtensions"
echo "   cp -R '/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/VocanaAudioDriver_Xcode.dext' ~/Library/DriverExtensions/"
echo ""
echo "2. Then restart your Mac"
echo "3. After restart, go to System Settings → Privacy & Security"
echo "4. Look for extension approval prompt"
echo ""

echo "Step 3: Check if Extension is Recognized"
echo "Run this command to see if system detects the extension:"
echo "systemextensionsctl list | grep -i vocana"
echo ""

echo "Step 4: Monitor Logs"
echo "log stream --predicate 'subsystem == \"com.apple.iokit\"' --info"
echo ""

echo "Current extension files available:"
ls -la "/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver/"*.dext

echo ""
echo "=== Ready for manual installation ==="