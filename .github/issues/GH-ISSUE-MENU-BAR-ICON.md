---
name: Menu Bar Icon Not Updating
about: Menu bar icon doesn't change when audio processing state changes
title: "[HIGH] Menu Bar Icon Not Updating with Audio State"
labels: high, bug, ui, menu-bar
assignees: ''
---

## Description
The menu bar icon does not change from white outline to green filled when enabling/disabling audio processing or when audio levels change.

## Expected Behavior
- White outline (`waveform.and.mic`) when idle/disabled
- Green filled (`waveform.and.mic.fill`) when recording (real audio + input level > 0.01)
- Real-time updates as audio levels change

## Current Behavior
- Menu bar icon stays white regardless of audio state
- No visual feedback when enabling/disabling the app

## Technical Details
- AudioEngine state updates are being monitored via Combine subscriptions
- `updateMenuBarIcon()` function exists but may not be triggering properly
- Possible issues with MainActor context or subscription setup

## Files Involved
- `VocanaApp.swift` - AppDelegate menu bar icon management
- `AudioEngine.swift` - Audio state publishing
- `AudioCoordinator.swift` - State coordination
- `VirtualAudioControlsView.swift` - New virtual audio controls (may affect state)

## Testing Notes
Virtual audio driver implementation in progress. Once HAL plugin is complete, can test:
1. Virtual device creation and registration
2. Audio processing state changes
3. Menu bar icon updates with virtual device activity
4. Real-time feedback during conferencing app usage

## Related Issues
- **Virtual Audio Driver**: Need HAL plugin completion for proper device state monitoring
- **Audio State Coordination**: VirtualAudioManager needs to publish state changes to menu bar

## Priority
High - Core user feedback mechanism