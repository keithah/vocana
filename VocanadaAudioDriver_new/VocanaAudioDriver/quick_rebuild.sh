#!/bin/bash

echo "=== Quick Vocana DriverKit Rebuild ==="
echo ""

# Clean and rebuild with Xcode
echo "Building with Xcode (includes provisioning profile)..."
cd "/Users/keith/src/vocana/VocanadaAudioDriver_new/VocanaAudioDriver"

xcodebuild \
    -project VocanaAudioDriver.xcodeproj \
    -scheme VocanaAudioDriver \
    -configuration Debug \
    -sdk driverkit25.0 \
    clean build

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    
    # Copy to user directory for easy testing
    echo "Copying to user DriverExtensions directory..."
    cp -R "/Users/keith/Library/Developer/Xcode/DerivedData/VocanaAudioDriver-*/Build/Products/Debug-driverkit/com.vocana.VocanaAudioDriver.dext" "/Users/keith/Library/DriverExtensions/"
    
    echo "✅ Extension ready for testing!"
    echo ""
    echo "Run test script: ./test_driver.sh"
else
    echo "❌ Build failed!"
fi