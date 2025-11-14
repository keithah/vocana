#!/bin/bash

echo "🎯 Setting up Vocana Audio Correctly..."
echo ""

echo "📋 CURRENT ISSUE ANALYSIS:"
echo "❌ You set: AirPods → BlackHole (output to input = silence)"
echo "✅ Need: Microphone → Vocana → BlackHole → Zoom"
echo ""

echo "🔧 STEP 1: Configure System Audio"
echo "Open System Settings → Sound →"
echo "  • Input:  MacBook Pro Microphone (NOT AirPods)"
echo "  • Output: BlackHole 2ch"
echo ""

echo "🔧 STEP 2: Test BlackHole Gets Audio"
echo "1. Open QuickTime Player → New Audio Recording"
echo "2. Set Microphone: BlackHole 2ch"
echo "3. Speak - you should see levels move"
echo "4. If silent, system output isn't reaching BlackHole"
echo ""

echo "🔧 STEP 3: Configure Zoom"
echo "1. Open Zoom → Settings → Audio"
echo "2. Set Microphone: BlackHole 2ch"
echo "3. Set Speaker: BlackHole 2ch"
echo ""

echo "🔊 CORRECT AUDIO FLOW:"
echo "Microphone → Vocana AI → System Output → BlackHole → Zoom"
echo ""

echo "💡 WHY THIS WORKS:"
echo "• Your microphone provides input"
echo "• Vocana processes it for noise cancellation"
echo "• System sends processed audio to BlackHole"
echo "• Zoom receives clean audio from BlackHole"
echo ""

echo "🧪 TEST IT:"
echo "1. Configure System Settings as above"
echo "2. Start Vocana app (already running)"
echo "3. Test in Zoom - you should hear clean audio!"
echo ""

echo "❓ If still silent:"
echo "• Play some music/sound - does BlackHole pick it up?"
echo "• Check System Settings → Output is really BlackHole"
echo "• Restart Vocana app"