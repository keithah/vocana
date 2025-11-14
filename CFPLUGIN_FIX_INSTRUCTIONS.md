# HAL Plugin CFPlugin Fix - Manual Installation

The issue was that the HAL plugin wasn't implementing the CFPlugin interface properly. I've fixed this by:

1. **Added CFPlugin factory functions** - Proper entry points for CoreAudio
2. **Updated Info.plist** - Correct factory function name
3. **Added constructor/destructor** - Plugin load/unload handling

## Manual Installation Commands:

```bash
# Copy the updated plugin bundle
sudo cp ".build/debug/VocanaAudioServerPlugin.bundle" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS/VocanaAudioServerPlugin"

# Copy updated Info.plist  
sudo cp "Sources/VocanaAudioServerPlugin/Info.plist" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/"

# Set proper ownership and permissions
sudo chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
sudo chmod -R 755 "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

# Code sign the bundle
sudo codesign --force --sign - --entitlements "VocanaAudioServerPlugin.entitlements" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

# Restart coreaudiod to reload the plugin
sudo killall coreaudiod

# Check for Vocana devices
system_profiler SPAudioDataType | grep -i vocana
```

## What Was Fixed:

**Previous Error:** "Couldn't communicate with a helper application"
**Root Cause:** Missing CFPlugin interface implementation
**Solution:** Added proper CFPlugin factory functions and entry points

## Expected Results:

After running these commands, you should see:
- ✅ No more "communication error" in coreaudiod logs
- ✅ "Vocana Microphone" and "Vocana Speaker" devices appear
- ✅ Devices selectable in Zoom/other apps
- ✅ Vocana app detects native HAL devices

## Troubleshooting:

If devices still don't appear:
```bash
# Check coreaudiod logs for errors
log show --predicate 'process == "coreaudiod"' --last 5m | grep -i vocana

# Verify plugin permissions
ls -la /Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/

# Force restart audio system
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

The HAL plugin should now load properly and create the virtual audio devices!