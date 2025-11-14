---
name: Swift App Integration with HAL Plugin
about: Connect the Swift application to the working HAL plugin for complete virtual audio device functionality
title: "[CRITICAL] Complete Swift App Integration with HAL Plugin"
labels: critical, enhancement, core-audio, integration
assignees: ''
---

## Description
The Core Audio HAL plugin is fully implemented and working. Virtual audio devices appear in System Preferences. Now connect the Swift application to discover and control these HAL devices.

## Current Status
- ✅ HAL Plugin: AudioServerPluginDriverInterface FULLY IMPLEMENTED AND WORKING
- ✅ Device Registration: "Vocana Microphone" and "Vocana Speaker" appear in system
- ✅ Build & Install: Plugin built, signed, and installed in /Library/Audio/Plug-Ins/HAL/
- ✅ System Integration: Devices visible in system_profiler and System Preferences
- ✅ XPC Framework: Inter-process communication bridge established
- ❌ Swift App Integration: VirtualAudioManager doesn't discover/connect to HAL devices
- ❌ Device Discovery: No Core Audio device enumeration in Swift app
- ❌ UI Enablement: Virtual audio controls remain disabled

## Requirements
1. ✅ **HAL Plugin Complete**: AudioServerPluginDriverInterface fully implemented
2. ✅ **Device Registration**: Virtual devices registered and visible in macOS
3. ✅ **System Integration**: Devices appear in System Preferences and system_profiler
4. 🔄 **Device Discovery**: Implement Core Audio device enumeration in Swift app
5. 🔄 **Swift-HAL Connection**: Connect VirtualAudioManager to HAL devices
6. 🔄 **XPC Bridge Completion**: Finish HAL ↔ Swift ML processing pipeline
7. 🔄 **UI Enablement**: Activate virtual audio controls in app interface

## Technical Challenges
- ✅ HAL Plugin: All entitlements, code signing, and real-time constraints handled
- 🔄 Swift Integration: Core Audio device enumeration and connection
- 🔄 XPC Bridge: Completing the Swift ↔ HAL audio processing pipeline
- 🔄 UI Integration: Connecting device discovery to app controls

## Files Modified/Needed
- ✅ VocanaAudioServerPlugin.c - HAL plugin FULLY IMPLEMENTED
- ✅ VocanaAudioServerPlugin.h - Interface declarations complete
- ✅ Info.plist - Bundle configuration working
- ✅ entitlements.plist - Audio driver entitlements applied
- 🔄 VirtualAudioManager.swift - Needs device discovery implementation
- 🔄 AudioProcessingXPCService.swift - Needs pipeline completion
- 🔄 VirtualAudioControlsView.swift - Needs UI enablement

## Acceptance Criteria
- ✅ "Vocana Microphone" appears in System Preferences → Sound → Input
- ✅ "Vocana Speaker" appears in System Preferences → Sound → Output
- ✅ Devices are selectable in macOS audio settings
- ✅ Swift app discovers and connects to HAL devices automatically
- 🔄 Applications can select Vocana devices for audio I/O (XPC processing needs completion)
- 🔄 Real-time noise cancellation works during video calls (XPC bridge needs completion)
- 🔄 Menu bar shows device activity and app usage (UI needs enablement)
- 🔄 Virtual audio controls enabled in Vocana app UI (needs activation)

## Status Tracking
- **HAL Plugin**: ✅ COMPLETE (Devices appear in macOS system)
- **Device Discovery**: ✅ COMPLETE (Core Audio enumeration implemented)
- **Swift-HAL Connection**: ✅ COMPLETE (VocanaAudioDevice connected to HAL devices)
- **XPC Bridge**: 🔄 IN PROGRESS (Audio processing pipeline needs completion)
- **UI Enablement**: 🔄 PENDING (Virtual audio controls need activation)
- **Timeline**: 1 week to v1.0 release
- **Blocker**: None - final integration steps remaining

## Priority
Critical - Final step for system-wide noise cancellation v1.0

## Implementation Plan

### Phase 1: Device Discovery (2-3 days)
**Primary File**: `Sources/Vocana/Models/VirtualAudioManager.swift`

```swift
// Add Core Audio framework import
import CoreAudio

// Implement device discovery
func discoverVocanaDevices() {
    // 1. Get all audio devices using AudioObjectGetPropertyData
    // 2. Filter for devices with UID containing "com.vocana.audio"
    // 3. Create VocanaAudioDevice instances with actual device IDs
    // 4. Set inputDevice and outputDevice properties
    // 5. Register for device change notifications
}
```

**Acceptance**: VirtualAudioManager.areDevicesAvailable returns true

### Phase 2: HAL Device Connection (2-3 days)
**Primary File**: `Sources/Vocana/Models/VirtualAudioManager.swift`

```swift
// Connect to actual HAL devices
func connectToHALDevice(deviceID: AudioObjectID) -> VocanaAudioDevice? {
    // 1. Get device properties (name, UID, channels, sample rate)
    // 2. Create VocanaAudioDevice with real HAL device ID
    // 3. Set up device state monitoring
    // 4. Enable noise cancellation controls
}
```

**Acceptance**: Device controls in UI become functional

### Phase 3: XPC Bridge Completion (1-2 days)
**Primary File**: `Sources/Vocana/Models/AudioProcessingXPCService.swift`

```swift
// Complete audio processing pipeline
func processAudioBuffer(_ buffer: Data, ...) {
    // 1. Ensure MLAudioProcessor is properly initialized
    // 2. Convert Data to float arrays for ML processing
    // 3. Apply DeepFilterNet noise cancellation
    // 4. Convert back to Data for HAL plugin
    // 5. Add comprehensive error handling
}
```

**Acceptance**: Audio processing works through XPC during device usage

### Phase 4: UI Integration & Testing (1-2 days)
**Primary File**: `Sources/Vocana/Components/VirtualAudioControlsView.swift`

```swift
// Enable real controls
struct VirtualAudioControlsView: View {
    @StateObject var virtualAudioManager = VirtualAudioManager.shared

    var body: some View {
        // Remove stub checks - use real device availability
        if virtualAudioManager.areDevicesAvailable {
            // Show real device controls
        }
    }
}
```

**Acceptance**: Virtual audio controls work in Vocana app UI

### Acceptance Criteria (Updated)
- ✅ "Vocana Microphone" appears in System Preferences → Sound → Input
- ✅ "Vocana Speaker" appears in System Preferences → Sound → Output
- 🔄 Applications can select Vocana devices for audio I/O (HAL provides processed audio)
- 🔄 Real-time noise cancellation works during video calls (XPC bridge complete)
- 🔄 Menu bar shows device activity and app usage (Swift app connected to HAL devices)