#!/usr/bin/env swift

import Foundation

// This script enables noise cancellation and tests audio level updates
print("🧪 Testing audio level updates with noise cancellation enabled...")

// Check current settings
let defaults = UserDefaults.standard
let currentEnabled = defaults.bool(forKey: "isEnabled")
let currentSensitivity = defaults.double(forKey: "sensitivity")

print("📊 Current settings:")
print("   Enabled: \(currentEnabled)")
print("   Sensitivity: \(currentSensitivity)")

// Enable noise cancellation for testing
defaults.set(true, forKey: "isEnabled")
defaults.set(0.5, forKey: "sensitivity")

print("✅ Updated settings:")
print("   Enabled: true")
print("   Sensitivity: 0.5")

print("🧪 Now run the app with: swift run")
print("🧪 The app should start with noise cancellation enabled and show real audio levels")