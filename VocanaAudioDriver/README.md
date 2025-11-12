# Vocana Audio Driver (DriverKit Extension)

This DriverKit dext creates virtual audio devices for Vocana's noise cancellation system.

## 📁 Project Structure

```text
VocanaAudioDriver/
├── VocanaAudioDriver/
│   ├── VocanaAudioDriver.hpp/.cpp     # Main dext service
│   ├── VocanaAudioUserClient.hpp/.cpp # User space communication
│   ├── Info.plist                     # DriverKit configuration
│   └── VocanaAudioDriver.entitlements # DriverKit entitlements
└── README.md                          # This file
```

## 🛠️ Xcode Project Setup

### Step 1: Create DriverKit Project
1. Open Xcode
2. **File → New → Project**
3. Select **DriverKit** template (not IOKit!)
4. Choose **DriverKit Driver** template (creates a .dext)
5. Name: `VocanaAudioDriver`
6. Bundle ID: `com.vocana.audio.driver`

**⚠️ Important:** Make sure you select **DriverKit** template, not **IOKit**. DriverKit creates modern system extensions (.dext) while IOKit creates legacy kernel extensions (.kext).

### Step 2: Configure Target Settings
1. Select the dext target
2. **Build Settings** tab:
   - **Architectures**: `x86_64` and `arm64`
   - **DriverKit Deployment Target**: `macOS 11.0+`
   - **Code Signing Identity**: `Sign to Run Locally` (for development)

### Step 3: Add Required Frameworks
1. **Build Phases** tab
2. **Link Binary With Libraries**:
   - Add `AudioDriverKit.framework`
   - Add `DriverKit.framework`

### Step 4: Configure Entitlements
1. Select the dext target
2. **Signing & Capabilities** tab
3. Add entitlements:
   - `com.apple.developer.driverkit`
   - `com.apple.developer.driverkit.family.audio`
   - `com.apple.developer.driverkit.transport.usb` (if needed)

### Step 5: Embed Dext in Main App
1. In your **Vocana** project (not the dext project), select the main app target
2. Go to **General** tab → **Frameworks, Libraries, and Embedded Content**
3. Click **+** button
4. Select **VocanaAudioDriver.dext** from the dext project
5. Set **Embed** to **Embed & Sign**

### Step 6: Replace Template Files
Replace the template files with the files from this directory:
- `VocanaAudioDriver.hpp/.cpp`
- `VocanaAudioUserClient.hpp/.cpp`
- `Info.plist`
- `VocanaAudioDriver.entitlements`

## 🔧 Build & Test

### Development Testing
```bash
# Build the dext
xcodebuild -project VocanaAudioDriver.xcodeproj -scheme VocanaAudioDriver

# Install for local testing (requires SIP disabled)
sudo xcodebuild -project VocanaAudioDriver.xcodeproj -scheme VocanaAudioDriver install
```

### System Installation
```bash
# Create installer package
productbuild --component VocanaAudioDriver.dext /tmp/VocanaAudioDriver.pkg

# Install system-wide
sudo installer -pkg VocanaAudioDriver.pkg -target /
```

## 🎛️ Virtual Audio Devices

The dext creates two virtual audio devices:

### Vocana Microphone
- **Input Device**: Processes microphone audio with noise cancellation
- **Sample Rate**: 48kHz
- **Channels**: 1 (mono)
- **Format**: 32-bit float

### Vocana Speaker
- **Output Device**: Processes application audio with noise cancellation
- **Sample Rate**: 48kHz
- **Channels**: 2 (stereo)
- **Format**: 32-bit float

## 🔌 Communication with Main App

The dext communicates with the main Vocana app via `VocanaAudioUserClient`:

- **Enable/Disable Processing**: Control noise cancellation on/off
- **Device Status**: Report virtual device state
- **Audio Configuration**: Adjust processing parameters

## 🐛 Debugging

### Enable DriverKit Logging
```bash
sudo log stream --predicate 'subsystem == "com.vocana.audio.driver"'
```

### Check dext Status
```bash
systemextensionsctl list
```

### Manual Loading
```bash
sudo systemextensionsctl load com.vocana.audio.driver
```

## 📋 Requirements

- **macOS**: 11.0+
- **Xcode**: 12.2+
- **DriverKit Entitlements**: Required for development
- **SIP**: Must be disabled for local development testing

## 🔄 Integration with Main App

The main Vocana app connects to the dext via IOKit:

```swift
import IOKit

// Connect to dext
let service = IOServiceGetMatchingService(kIOMasterPortDefault,
    IOServiceMatching("VocanaAudioDriver"))

// Create user client connection
// Send commands to enable/disable processing
```

## 📚 References

- [Building an Audio Server Plug-in and Driver Extension](https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension)
- [DriverKit Programming Guide](https://developer.apple.com/documentation/driverkit)
- [AudioDriverKit Framework](https://developer.apple.com/documentation/audiodriverkit)