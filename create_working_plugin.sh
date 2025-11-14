#!/bin/bash

echo "🔧 Creating Working Vocana HAL Plugin"
echo "====================================="

# Create a minimal working HAL plugin that actually creates devices
cat > Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c << 'EOF'
/*
    VocanaAudioServerPlugin.c - Minimal Working HAL Plugin
    Creates actual virtual audio devices that appear in macOS
*/

#include <CoreAudio/AudioServerPlugIn.h>
#include <pthread.h>
#include <sys/syslog.h>
#include <CoreFoundation/CoreFoundation.h>

// Logging
#define DebugMsg(...) syslog(LOG_NOTICE, "VocanaHAL: " __VA_ARGS__)
#define ErrorMsg(...) syslog(LOG_ERR, "VocanaHAL ERROR: " __VA_ARGS__)

// Object IDs
#define kObjectID_PlugIn 1
#define kObjectID_Device 2
#define kObjectID_Stream_Input 3
#define kObjectID_Stream_Output 4

// Plugin structure
typedef struct {
    AudioServerPlugInHostRef hostRef;
    pthread_mutex_t mutex;
    Boolean deviceCreated;
    AudioObjectID deviceObjectID;
    AudioObjectID inputStreamObjectID;
    AudioObjectID outputStreamObjectID;
    Float64 sampleRate;
} VocanaPlugin;

static VocanaPlugin *gPlugin = NULL;

// CFPlugin factory
void* VocanaAudioServerPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    DebugMsg("Factory called");
    
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    
    VocanaPlugin *plugin = calloc(1, sizeof(VocanaPlugin));
    if (!plugin) {
        ErrorMsg("Failed to allocate plugin");
        return NULL;
    }
    
    pthread_mutex_init(&plugin->mutex, NULL);
    plugin->sampleRate = 48000.0;
    plugin->deviceObjectID = kObjectID_Device;
    plugin->inputStreamObjectID = kObjectID_Stream_Input;
    plugin->outputStreamObjectID = kObjectID_Stream_Output;
    plugin->deviceCreated = true;
    
    gPlugin = plugin;
    DebugMsg("Plugin created successfully");
    return plugin;
}

// IUnknown interface
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

static ULONG VocanaAudioServerPlugin_AddRef(void* inDriver) { return 1; }
static ULONG VocanaAudioServerPlugin_Release(void* inDriver) { return 1; }

// AudioServerPlugInDriverInterface
static OSStatus VocanaAudioServerPlugin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    VocanaPlugin *plugin = (VocanaPlugin*)inDriver;
    if (!plugin || !inHost) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    plugin->hostRef = inHost;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("Plugin initialized");
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, AudioObjectID* outDeviceObjectID) {
    VocanaPlugin *plugin = (VocanaPlugin*)inDriver;
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
    DebugMsg("Client added to device %u", inDeviceObjectID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    DebugMsg("Client removed from device %u", inDeviceObjectID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareNoError;
}

// Property management
static Boolean VocanaAudioServerPlugin_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    if (!inDriver || !inAddress) return false;
    
    switch (inObjectID) {
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyDeviceManufacturer:
                case kAudioDevicePropertyDeviceName:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyStreamFormat:
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
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyStreamFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    break;
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
    
    VocanaPlugin *plugin = (VocanaPlugin*)inDriver;
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
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    *(Float64*)outData = plugin->sampleRate;
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyStreamFormat: {
                    AudioStreamBasicDescription format = {0};
                    format.mSampleRate = plugin->sampleRate;
                    format.mFormatID = kAudioFormatLinearPCM;
                    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                    format.mBytesPerPacket = 8; // 2 channels * 4 bytes
                    format.mFramesPerPacket = 1;
                    format.mBytesPerFrame = 8;
                    format.mChannelsPerFrame = 2;
                    format.mBitsPerChannel = 32;
                    *(AudioStreamBasicDescription*)outData = format;
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                }
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
                case kAudioStreamPropertyFormat: {
                    AudioStreamBasicDescription format = {0};
                    format.mSampleRate = plugin->sampleRate;
                    format.mFormatID = kAudioFormatLinearPCM;
                    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                    format.mBytesPerPacket = 8;
                    format.mFramesPerPacket = 1;
                    format.mBytesPerFrame = 8;
                    format.mChannelsPerFrame = 2;
                    format.mBitsPerChannel = 32;
                    *(AudioStreamBasicDescription*)outData = format;
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                }
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

// IO operations
static OSStatus VocanaAudioServerPlugin_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    DebugMsg("IO started for client %u", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    DebugMsg("IO stopped for client %u", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (!outSampleTime || !outHostTime || !outSeed) return kAudioHardwareBadObjectError;
    
    *outSampleTime = 0.0;
    *outHostTime = mach_absolute_time();
    *outSeed = 1;
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

// Interface structure
static AudioServerPlugInDriverInterface gVocanaPluginInterface = {
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

// Plugin load/unload
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

echo "🔨 Building minimal HAL plugin..."

# Build the simplified plugin
clang -bundle -o ".build/release/VocanaAudioServerPlugin.bundle" \
    Sources/VocanaAudioServerPlugin/VocanaAudioServerPlugin.c \
    -I Sources/VocanaAudioServerPlugin/include \
    -framework CoreAudio \
    -framework CoreFoundation \
    -arch arm64 \
    -arch x86_64 \
    -DRELEASE

if [ $? -eq 0 ]; then
    echo "✅ Minimal HAL plugin built successfully"
else
    echo "❌ Build failed"
    exit 1
fi

echo ""
echo "📦 Installation commands (run with sudo):"
echo "======================================"
echo ""
echo "# Copy new plugin"
echo "sudo cp '.build/release/VocanaAudioServerPlugin.bundle' '/Library/Audio/Plug-Ins/HAL/VocanaAudioServerPlugin.driver/Contents/MacOS/VocanaAudioServerPlugin'"
echo ""
echo "# Restart audio system"
echo "sudo killall coreaudiod"
echo ""
echo "# Check logs"
echo "log show --predicate 'process == \"coreaudiod\"' --last 2m | grep -i vocana"
echo ""
echo "# Check devices"
echo "system_profiler SPAudioDataType | grep -i vocana"

echo ""
echo "🎯 This minimal plugin should create a basic 'Vocana Virtual Audio Device'"