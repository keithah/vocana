#!/bin/bash

echo "=== Vocana DriverKit Testing Suite ==="
echo ""

echo "1. Checking Extension Status..."
systemextensionsctl list | grep -i vocana || echo "❌ Extension not found in system list"

echo ""
echo "2. Checking Extension Files..."
if [ -d "/Users/keith/Library/DriverExtensions/VocanaAudioDriver_Xcode.dext" ]; then
    echo "✅ Extension found in user directory"
    ls -la "/Users/keith/Library/DriverExtensions/VocanaAudioDriver_Xcode.dext/"
else
    echo "❌ Extension not found in user directory"
fi

if [ -d "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext" ]; then
    echo "✅ Extension found in system directory"
    ls -la "/Library/DriverExtensions/com.vocana.VocanaAudioDriver.dext/"
else
    echo "❌ Extension not found in system directory"
fi

echo ""
echo "3. Recent Driver Logs (last 10 minutes)..."
log show --last 10m --predicate 'subsystem == "com.apple.iokit"' --info | grep -i vocana || echo "No Vocana logs found"

echo ""
echo "4. Starting Live Log Monitoring..."
echo "Press Ctrl+C to stop monitoring"
echo "Looking for: 'VocanaAudioDriver: Starting audio driver'"
echo ""

log stream --predicate 'subsystem == "com.apple.iokit"' --info