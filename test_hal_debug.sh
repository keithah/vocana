#!/bin/bash

echo "=== HAL Plugin Debugging ==="

echo "1. Current installed plugins:"
ls -la "/Library/Audio/Plug-Ins/HAL/"

echo ""
echo "2. Testing plugin load manually:"
# Try to load with CFPlugin
/usr/bin/pluginkit -m -p "/tmp/VocanaAudioServerPlugin.driver" 2>&1 || echo "pluginkit failed"

echo ""
echo "3. Check system log for any plugin activity:"
log show --predicate 'subsystem == "com.apple.audio"' --last 5m | grep -E "(Vocana|plugin|HAL)" | tail -5

echo ""
echo "4. Compare with working BlackHole plugin:"
codesign -dv "/Library/Audio/Plug-Ins/HAL/OriginalBlackHole.driver" 2>/dev/null || echo "BlackHole not accessible"

echo ""
echo "5. Our plugin signature:"
codesign -dv "/tmp/VocanaAudioServerPlugin.driver" 2>/dev/null || echo "Our plugin not accessible"

echo ""
echo "=== HAL Plugin Complexity ==="
echo "HAL plugins require:"
echo "- Perfect CFPlugin interface implementation"
echo "- Correct UUID matching in Info.plist"  
echo "- Proper code signing with trusted certificates"
echo "- CoreAudio server restart to load"
echo "- Complex device object management"
echo ""
echo "Alternative approaches may be more practical:"