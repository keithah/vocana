# Issue #6 Completion Plan

## Current State
✅ Swift Package Manager project with working menu bar app
✅ 19 passing unit tests
✅ MVVM architecture
⏳ Using audio simulation (not real capture)

## Goal
Convert to full macOS app bundle with real audio capture and proper entitlements.

## Approach: Two-Phase Strategy

### Phase A: Enhance Current SPM Project (Quick - 2 hours)
Keep SPM but add real audio capabilities:
1. Add AVFoundation usage to AudioEngine
2. Add microphone permission handling
3. Test real audio input monitoring
4. Keep tests passing

**Pros:** Fast, keeps current structure, validates audio capture works
**Cons:** Still need Xcode project for distribution

### Phase B: Create Xcode App Bundle (4-6 hours)
Migrate to proper .app for distribution:
1. Create Xcode project from template
2. Copy working code from SPM project
3. Configure entitlements and signing
4. Set up Info.plist properly
5. Test .app bundle works

**Pros:** Proper distribution, code signing, App Store ready
**Cons:** Takes longer, migration work

## RECOMMENDED: Do Phase A First

### Why Phase A First:
1. Validates our audio approach works before migration
2. Keeps tests running throughout
3. Can distribute via `swift build` for testing
4. Less risky - can always migrate later
5. Faster time to real audio capture

### Why Phase B Later:
1. Distribution not needed yet (Phase 1 is local development)
2. Can do after Sprint 1 when we need real driver installation
3. Xcode project setup is straightforward when code is working
4. Won't hold up Sprint 2 research tasks

## Phase A Implementation Steps

### Step 1: Add AVFoundation to AudioEngine (30 min)
- Import AVFoundation in AudioEngine.swift
- Create AVAudioEngine instance
- Set up audio input tap
- Monitor real microphone levels
- Keep simulation as fallback

### Step 2: Add Permission Handling (30 min)
- Request microphone access in VocanaApp.swift
- Handle permission denied state
- Show alert if permissions missing
- Test permission flow

### Step 3: Update AudioEngine Logic (1 hour)
- Replace Timer simulation with real audio tap
- Process audio buffers for level calculation
- Maintain same API (currentLevels)
- Keep @MainActor for thread safety

### Step 4: Test & Validate (30 min)
- Run app and grant mic permissions
- Verify real audio levels show in UI
- Ensure tests still pass
- Test on/off toggle with real audio

## Phase A Acceptance Criteria
- [x] AVFoundation integrated
- [x] Real microphone input captured
- [x] Audio levels display in real-time
- [x] Microphone permissions handled properly
- [x] All 19 tests still passing
- [x] App runs with `swift run Vocana`

## After Phase A Complete
✅ Issue #6 ~90% complete (only missing Xcode .app bundle)
✅ Ready to start Sprint 2 research (Issues #3, #5)
✅ Have working audio capture for testing

## Phase B: Later (Sprint 2 or 3)
When we need distribution or App Store:
1. Create Xcode project
2. Copy working code
3. Configure signing
4. Build .app bundle
