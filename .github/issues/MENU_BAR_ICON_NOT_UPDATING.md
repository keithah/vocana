# Menu Bar Icon Not Updating

## Issue Description
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

## Priority
High - Core user feedback mechanism

## Testing Notes
Cannot properly test without working audio driver setup. Need to fix audio input first to verify real-time icon updates.