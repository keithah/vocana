---
name: Tooltips Not Working
about: Tooltips not appearing on status indicators and virtual audio controls
title: "[MEDIUM] Tooltips Not Working on Status Indicators"
labels: medium, bug, ui, accessibility
assignees: ''
---

## Description
Tooltips are not appearing when hovering over status indicators in the popover, particularly the orange ML dot and new virtual audio controls.

## Expected Behavior
- Hover over mic icon: "Microphone active" / "Using simulated audio"
- Hover over orange dot: "ML noise reduction active" / "ML noise reduction unavailable"
- Hover over warning triangle: Shows specific performance issues
- **NEW**: Virtual audio controls should show device status and app usage

## Current Behavior
- No tooltips appear on hover
- Users cannot get information about status indicators

## Technical Details
- SwiftUI `.help()` modifier may not work properly on small shapes like Circle
- Group wrapper was attempted but may not be sufficient
- Possible issues with view hierarchy or hit testing
- **NEW**: VirtualAudioControlsView may have tooltip conflicts with existing StatusIndicatorView

## Files Involved
- `StatusIndicatorView.swift` - Status indicator UI and tooltips
- `VirtualAudioControlsView.swift` - New virtual audio controls with activity indicators

## Testing Notes
Virtual audio driver implementation adds new tooltip requirements:
1. Device activity indicators should show "Active" / "Inactive"
2. App usage indicators should show which apps are using virtual devices
3. Device selection dropdowns need proper accessibility labels

## Related Issues
- **Virtual Audio Integration**: New controls may interfere with existing tooltip system
- **Accessibility**: Need to ensure all new UI elements have proper help text

## Priority
Medium - Affects user understanding but not core functionality