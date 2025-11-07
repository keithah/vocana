#!/bin/bash

# This script helps create the Xcode project structure
# We'll need to do some steps manually in Xcode

echo "Creating Xcode App Bundle structure..."

# Create the app structure
mkdir -p VocanaApp/VocanaApp
mkdir -p VocanaApp/VocanaApp/Resources
mkdir -p VocanaApp/VocanaAppTests

echo "Directory structure created at VocanaApp/"
echo ""
echo "Next steps:"
echo "1. Open Xcode"
echo "2. Create New Project -> macOS -> App"
echo "3. Product Name: Vocana"
echo "4. Organization Identifier: com.vocana"
echo "5. Interface: SwiftUI"
echo "6. Language: Swift"
echo "7. Include Tests: Yes"
echo "8. Save to: /Users/keith/src/vocana/VocanaApp"
echo ""
echo "After creating, we'll migrate the code from Vocana/ to VocanaApp/"
