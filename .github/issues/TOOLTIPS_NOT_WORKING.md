# Tooltips Not Working on Status Indicators

## Issue Description
Tooltips are not appearing when hovering over status indicators in the popover, particularly the orange ML dot.

## Expected Behavior
- Hover over mic icon: "Microphone active" / "Using simulated audio"
- Hover over orange dot: "ML noise reduction active" / "ML noise reduction unavailable"
- Hover over warning triangle: Shows specific performance issues

## Current Behavior
- No tooltips appear on hover
- Users cannot get information about status indicators

## Technical Details
- SwiftUI `.help()` modifier may not work properly on small shapes like Circle
- Group wrapper was attempted but may not be sufficient
- Possible issues with view hierarchy or hit testing

## Files Involved
- `StatusIndicatorView.swift` - Status indicator UI and tooltips

## Priority
Medium - Affects user understanding but not core functionality

## Testing Notes
Cannot properly test tooltip behavior without working audio driver to trigger different states.