#!/bin/bash

set -e

echo "🔧 Vocana HAL Plugin Complete Fix and Installation"
echo "=================================================="

# Check if running from correct directory
if [ ! -f "Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c" ]; then
    echo "❌ Error: Must run from vocana project root directory"
    exit 1
fi

echo "📝 Step 1: Fixing HAL plugin implementation..."

# Backup original file
cp Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c.backup

# Fix the plugin to actually create devices
cat > Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c << 'EOF'
/*
    VocanaAudioServerPlugin.c
    CoreAudio HAL Plugin for Vocana Virtual Audio Devices
    
    Fixed version that actually creates devices
*/

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/syslog.h>
#include <Accelerate/Accelerate.h>
#include <Availability.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioUnit/AudioUnit.h>
#include <xpc/xpc.h>
#include "VocanaAudioServerPlugin.h"

//==================================================================================================
// MARK: - Constants
//==================================================================================================

#define kNumber_Of_Channels 2
#define kBytes_Per_Channel 4
#define kBits_Per_Channel 32

// Object IDs
#define kObjectID_PlugIn 1
#define kObjectID_Box 2
#define kObjectID_Device 3
#define kObjectID_Stream_Input 4
#define kObjectID_Stream_Output 5

// Logging
#define DebugMsg(inFormat, ...) syslog(LOG_NOTICE, "VocanaHAL: " inFormat, ## __VA_ARGS__)
#define ErrorMsg(inFormat, ...) syslog(LOG_ERR, "VocanaHAL ERROR: " inFormat, ## __VA_ARGS__)

//==================================================================================================
// MARK: - Plugin Structure
//==================================================================================================

typedef struct VocanaAudioServerPlugin {
    AudioServerPlugInHostRef hostRef;
    pthread_mutex_t mutex;
    
    // Device state
    Boolean deviceCreated;
    AudioObjectID deviceObjectID;
    
    // Stream IDs
    AudioObjectID inputStreamObjectID;
    AudioObjectID outputStreamObjectID;
    
    // Audio format
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    Float64 sampleRate;
    
    // State
    Boolean ioStarted;
    UInt32 clientCount;
    
} VocanaAudioServerPlugin;

static VocanaAudioServerPlugin *gPlugin = NULL;

//==================================================================================================
// MARK: - Utility Functions
//==================================================================================================

static Boolean IsValidObjectID(AudioObjectID inObjectID) {
    return (inObjectID == kObjectID_PlugIn ||
            inObjectID == kObjectID_Box ||
            inObjectID == kObjectID_Device ||
            inObjectID == kObjectID_Stream_Input ||
            inObjectID == kObjectID_Stream_Output);
}

//==================================================================================================
// MARK: - CFPlugin Factory
//==================================================================================================

void* VocanaAudioServerPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    DebugMsg("Factory called with UUID type");
    
    // Check if this is the right type
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        ErrorMsg("Wrong UUID type requested");
        return NULL;
    }
    
    DebugMsg("Creating Vocana HAL plugin instance");
    
    // Allocate plugin structure
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)calloc(1, sizeof(VocanaAudioServerPlugin));
    if (!plugin) {
        ErrorMsg("Failed to allocate plugin");
        return NULL;
    }
    
    // Initialize mutex
    if (pthread_mutex_init(&plugin->mutex, NULL) != 0) {
        free(plugin);
        ErrorMsg("Failed to initialize mutex");
        return NULL;
    }
    
    // Initialize audio format
    plugin->sampleRate = 48000.0;
    plugin->inputFormat.mSampleRate = plugin->sampleRate;
    plugin->inputFormat.mFormatID = kAudioFormatLinearPCM;
    plugin->inputFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    plugin->inputFormat.mBytesPerPacket = kNumber_Of_Channels * kBytes_Per_Channel;
    plugin->inputFormat.mFramesPerPacket = 1;
    plugin->inputFormat.mBytesPerFrame = kNumber_Of_Channels * kBytes_Per_Channel;
    plugin->inputFormat.mChannelsPerFrame = kNumber_Of_Channels;
    plugin->inputFormat.mBitsPerChannel = kBits_Per_Channel;
    
    plugin->outputFormat = plugin->inputFormat;
    
    // Set object IDs
    plugin->deviceObjectID = kObjectID_Device;
    plugin->inputStreamObjectID = kObjectID_Stream_Input;
    plugin->outputStreamObjectID = kObjectID_Stream_Output;
    
    // Mark device as created
    plugin->deviceCreated = true;
    
    gPlugin = plugin;
    DebugMsg("Vocana HAL plugin created successfully");
    
    return plugin;
}

//==================================================================================================
// MARK: - AudioServerPlugInDriverInterface Implementation
//==================================================================================================

static HRESULT VocanaAudioServerPlugin_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (!inDriver || !outInterface) return E_POINTER;
    
    CFUUIDRef requestedUUID = (CFUUIDRef)inUUID;
    *outInterface = NULL;
    
    if (CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID) ||
        CFEqual(requestedUUID, IUnknownUUID)) {
        *outInterface = inDriver;
        return S_OK;
    }
    
    return E_NOINTERFACE;
}

static ULONG VocanaAudioServerPlugin_AddRef(void* inDriver) {
    return 1;
}

static ULONG VocanaAudioServerPlugin_Release(void* inDriver) {
    return 1;
}

static OSStatus VocanaAudioServerPlugin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    if (!plugin || !inHost) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    plugin->hostRef = inHost;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("Plugin initialized");
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, AudioObjectID* outDeviceObjectID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    if (!plugin || !outDeviceObjectID) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    *outDeviceObjectID = plugin->deviceObjectID;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("Device created with ID: %u", *outDeviceObjectID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    DebugMsg("Destroy device called for ID: %u", inDeviceObjectID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    if (!plugin) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    plugin->clientCount++;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("Client added, total: %u", plugin->clientCount);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    if (!plugin) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    if (plugin->clientCount > 0) plugin->clientCount--;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("Client removed, total: %u", plugin->clientCount);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareNoError;
}

//==================================================================================================
// MARK: - Property Management
//==================================================================================================

static Boolean VocanaAudioServerPlugin_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    if (!inDriver || !inAddress) return false;
    if (!IsValidObjectID(inObjectID)) return false;
    
    switch (inObjectID) {
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyDeviceManufacturer:
                case kAudioDevicePropertyDeviceName:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredStereoLayout:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyStreamFormat:
                case kAudioDevicePropertyStreamFormats:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyOwnedObjects:
                    return true;
                default:
                    return false;
            }
            
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyFormat:
                case kAudioStreamPropertyAvailableFormats:
                    return true;
                default:
                    return false;
            }
            
        default:
            return false;
    }
}

static OSStatus VocanaAudioServerPlugin_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    if (!inDriver || !outIsSettable) return kAudioHardwareBadObjectError;
    if (!VocanaAudioServerPlugin_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    if (!inDriver || !outDataSize) return kAudioHardwareBadObjectError;
    if (!VocanaAudioServerPlugin_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    
    switch (inObjectID) {
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyDeviceManufacturer:
                case kAudioDevicePropertyDeviceName:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredStereoLayout:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    *outDataSize = sizeof(AudioValueRange);
                    break;
                }
                case kAudioDevicePropertyStreamFormat:
                case kAudioDevicePropertyStreamFormats:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                case kAudioDevicePropertyStreams: {
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    break;
                }
                case kAudioObjectPropertyOwnedObjects: {
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    break;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;
            
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyFormat:
                case kAudioStreamPropertyAvailableFormats:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;
            
        default:
            return kAudioHardwareBadObjectError;
    }
    
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (!inDriver || !outDataSize || !outData) return kAudioHardwareBadObjectError;
    if (!VocanaAudioServerPlugin_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    OSStatus result = kAudioHardwareNoError;
    
    pthread_mutex_lock(&plugin->mutex);
    
    switch (inObjectID) {
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyDeviceUID: {
                    CFStringRef uid = CFSTR("com.vocana.VirtualDevice");
                    *(CFStringRef*)outData = uid;
                    *outDataSize = sizeof(CFStringRef);
                    break;
                }
                case kAudioDevicePropertyDeviceManufacturer: {
                    CFStringRef manufacturer = CFSTR("Vocana Inc.");
                    *(CFStringRef*)outData = manufacturer;
                    *outDataSize = sizeof(CFStringRef);
                    break;
                }
                case kAudioDevicePropertyDeviceName: {
                    CFStringRef name = CFSTR("Vocana Virtual Audio Device");
                    *(CFStringRef*)outData = name;
                    *outDataSize = sizeof(CFStringRef);
                    break;
                }
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *(UInt32*)outData = (kAudioChannelLeftMask | kAudioChannelRightMask);
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredStereoLayout:
                    *(UInt32*)outData = kAudioChannelLayoutTag_Stereo;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    *(Float64*)outData = plugin->sampleRate;
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange range = { 44100.0, 96000.0 };
                    *(AudioValueRange*)outData = range;
                    *outDataSize = sizeof(AudioValueRange);
                    break;
                }
                case kAudioDevicePropertyStreamFormat:
                case kAudioDevicePropertyStreamFormats:
                    if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                        *(AudioStreamBasicDescription*)outData = plugin->inputFormat;
                    } else {
                        *(AudioStreamBasicDescription*)outData = plugin->outputFormat;
                    }
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                case kAudioDevicePropertyStreams: {
                    AudioObjectID streams[2] = { plugin->inputStreamObjectID, plugin->outputStreamObjectID };
                    memcpy(outData, streams, 2 * sizeof(AudioObjectID));
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    break;
                }
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID objects[2] = { plugin->inputStreamObjectID, plugin->outputStreamObjectID };
                    memcpy(outData, objects, 2 * sizeof(AudioObjectID));
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    break;
                }
                default:
                    result = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;
            
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyTerminalType:
                    *(UInt32*)outData = (inObjectID == kObjectID_Stream_Input) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyStartingChannel:
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyLatency:
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyFormat:
                case kAudioStreamPropertyAvailableFormats:
                    if (inObjectID == kObjectID_Stream_Input) {
                        *(AudioStreamBasicDescription*)outData = plugin->inputFormat;
                    } else {
                        *(AudioStreamBasicDescription*)outData = plugin->outputFormat;
                    }
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                default:
                    result = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;
            
        default:
            result = kAudioHardwareBadObjectError;
            break;
    }
    
    pthread_mutex_unlock(&plugin->mutex);
    return result;
}

static OSStatus VocanaAudioServerPlugin_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    return kAudioHardwareNoError;
}

//==================================================================================================
// MARK: - IO Operations
//==================================================================================================

static OSStatus VocanaAudioServerPlugin_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    if (!plugin) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    plugin->ioStarted = true;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("IO started for client %u", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    if (!plugin) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    plugin->ioStarted = false;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("IO stopped for client %u", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (!inDriver || !outSampleTime || !outHostTime || !outSeed) return kAudioHardwareBadObjectError;
    
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;
    
    pthread_mutex_lock(&plugin->mutex);
    *outSampleTime = 0.0;
    *outHostTime = mach_absolute_time();
    *outSeed = 1;
    pthread_mutex_unlock(&plugin->mutex);
    
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    if (!outWillDo || !outWillDoInPlace) return kAudioHardwareBadObjectError;
    
    *outWillDo = true;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioBufferList) {
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioBufferList) {
    return kAudioHardwareNoError;
}

//==================================================================================================
// MARK: - Interface Structure
//==================================================================================================

static AudioServerPlugInDriverInterface gVocanaAudioServerPluginInterface = {
    NULL,
    VocanaAudioServerPlugin_QueryInterface,
    VocanaAudioServerPlugin_AddRef,
    VocanaAudioServerPlugin_Release,
    VocanaAudioServerPlugin_Initialize,
    VocanaAudioServerPlugin_CreateDevice,
    VocanaAudioServerPlugin_DestroyDevice,
    VocanaAudioServerPlugin_AddDeviceClient,
    VocanaAudioServerPlugin_RemoveDeviceClient,
    VocanaAudioServerPlugin_PerformDeviceConfigurationChange,
    VocanaAudioServerPlugin_AbortDeviceConfigurationChange,
    VocanaAudioServerPlugin_HasProperty,
    VocanaAudioServerPlugin_IsPropertySettable,
    VocanaAudioServerPlugin_GetPropertyDataSize,
    VocanaAudioServerPlugin_GetPropertyData,
    VocanaAudioServerPlugin_SetPropertyData,
    VocanaAudioServerPlugin_StartIO,
    VocanaAudioServerPlugin_StopIO,
    VocanaAudioServerPlugin_GetZeroTimeStamp,
    VocanaAudioServerPlugin_WillDoIOOperation,
    VocanaAudioServerPlugin_BeginIOOperation,
    VocanaAudioServerPlugin_DoIOOperation,
    VocanaAudioServerPlugin_EndIOOperation
};

//==================================================================================================
// MARK: - Plugin Load/Unload
//==================================================================================================

__attribute__((constructor))
static void VocanaAudioServerPlugin_Load() {
    DebugMsg("VocanaAudioServerPlugin loaded");
}

__attribute__((destructor))
static void VocanaAudioServerPlugin_Unload() {
    if (gPlugin) {
        pthread_mutex_destroy(&gPlugin->mutex);
        free(gPlugin);
        gPlugin = NULL;
    }
    DebugMsg("VocanaAudioServerPlugin unloaded");
}
EOF

echo "🔨 Step 2: Building updated plugin..."

# Build the plugin
clang -bundle -o ".build/debug/VocanaAudioServerPlugin.bundle" \
    Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c \
    -I Sources/VocanaAudioServerPlugin/include \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -framework Accelerate \
    -arch arm64 \
    -arch x86_64 \
    -DDEBUG

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo "📦 Step 3: Installing plugin..."

# Create directories
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS"
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/Resources"

# Copy files
sudo cp ".build/debug/VocanaAudioServerPlugin.bundle" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS/VocanaAudioServerPlugin"
sudo cp "Sources/VocanaAudioServerPlugin/Info.plist" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/"

# Set permissions
sudo chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"
sudo chmod -R 755 "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

# Code sign
sudo codesign --force --sign - --entitlements "VocanaAudioServerPlugin.entitlements" "/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver"

echo "🔄 Step 4: Restarting audio system..."

# Restart coreaudiod
sudo killall coreaudiod 2>/dev/null || echo "coreaudiod not running"

# Wait for restart
sleep 3

echo "🔍 Step 5: Testing plugin..."

# Check if plugin loaded
if log show --predicate 'process == "coreaudiod"' --last 2m | grep -q "VocanaHAL"; then
    echo "✅ Plugin loaded successfully!"
else
    echo "⚠️  Plugin may not have loaded - checking logs..."
    log show --predicate 'process == "coreaudiod"' --last 2m | grep -i vocana || echo "No Vocana entries found"
fi

# Check for devices
echo "🎵 Checking for Vocana audio devices..."
if system_profiler SPAudioDataType | grep -q "Vocana"; then
    echo "✅ Vocana devices found!"
    system_profiler SPAudioDataType | grep Vocana
else
    echo "❌ Vocana devices not found in system profile"
fi

echo ""
echo "🎯 Step 6: Manual verification"
echo "Open Audio MIDI Setup and look for:"
echo "  - 'Vocana Virtual Audio Device'"
echo ""
echo "If you see it, you can:"
echo "  1. Select it as input/output in apps"
echo "  2. Test with: swift run Vocana"
echo ""
echo "If not, check logs with:"
echo "  log show --predicate 'process == \"coreaudiod\"' --last 5m | grep -i vocana"

echo ""
echo "🎉 Installation complete!"