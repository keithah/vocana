#!/bin/bash

echo "🔧 Testing Vocana Menu Bar Icon Fix"
echo "===================================="

# Kill any existing Vocana processes
pkill -f Vocana 2>/dev/null
sleep 1

echo "✅ Cleaned up any existing processes"

# Navigate to correct directory
cd /Users/keith/src/vocana/Vocana

echo "🚀 Starting Vocana app..."
echo ""
echo "📋 Test Instructions:"
echo "1. Look for the menu bar icon (should appear as waveform.and.mic - gray)"
echo "2. Click the icon to open the popover"
echo "3. Toggle the 'Enable Noise Cancellation' switch"
echo "4. Icon should change to mic.fill (green) when enabled + real audio"
echo "5. Icon should change back to waveform.and.mic (gray) when disabled"
echo ""
echo "🔍 Expected behavior:"
echo "   - Disabled: waveform.and.mic icon (gray)"
echo "   - Enabled: mic.fill icon (green when receiving audio)"
echo ""
echo "Press Ctrl+C to stop the app when done testing"
echo ""

# Start the app
swift run