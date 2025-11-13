/*
    VocanaAudioServerPlugin.c
    CoreAudio HAL Plugin for Vocana Virtual Audio Devices

    Copyright (C) 2025 Vocana Inc.

    This file implements a CoreAudio HAL (Hardware Abstraction Layer) plugin
    that provides virtual audio devices for noise cancellation processing.
    The plugin creates "Vocana Microphone" and "Vocana Speaker" devices that
    appear as standard audio devices in macOS.

    Based on Apple's CoreAudio HAL Plugin documentation and examples.
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
#include "VocanaAudioServerPlugin.h"

//==================================================================================================
// MARK: - Macros and Constants
//==================================================================================================

#if TARGET_RT_BIG_ENDIAN
#define FourCCToCString(the4CC) { ((char*)&the4CC)[0], ((char*)&the4CC)[1], ((char*)&the4CC)[2], ((char*)&the4CC)[3], 0 }
#else
#define FourCCToCString(the4CC) { ((char*)&the4CC)[3], ((char*)&the4CC)[2], ((char*)&the4CC)[1], ((char*)&the4CC)[0], 0 }
#endif

#ifndef __MAC_12_0
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

// Logging macros
#define DebugMsg(inFormat, ...) syslog(LOG_NOTICE, inFormat, ## __VA_ARGS__)
#define ErrorMsg(inFormat, ...) syslog(LOG_ERR, "VocanaAudioServerPlugin ERROR: " inFormat, ## __VA_ARGS__)

// Safe memory allocation with null checks
#define SafeAlloc(type, count) ({ \
    type *ptr = (type *)malloc(sizeof(type) * (count)); \
    if (!ptr) { \
        ErrorMsg("Failed to allocate memory for " #type " x %lu", (unsigned long)(count)); \
        return kAudioHardwareUnspecifiedError; \
    } \
    ptr; \
})

//==================================================================================================
// MARK: - Plugin State Structure
//==================================================================================================

typedef struct VocanaAudioServerPlugin {
    AudioServerPlugInDriverRef pluginRef;
    AudioServerPlugInHostRef hostRef;

    // Thread safety
    pthread_mutex_t mutex;

    // Device state
    Boolean deviceCreated;
    AudioObjectID deviceObjectID;

    // IO state
    Boolean ioStarted;
    UInt32 clientCount;

    // Audio format
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;

    // Buffer management
    void *inputBuffer;
    void *outputBuffer;
    UInt32 bufferSize;

    // Timing
    Float64 sampleRate;
    UInt64 anchorHostTime;

} VocanaAudioServerPlugin;

// Global plugin instance
static VocanaAudioServerPlugin *gPlugin = NULL;

//==================================================================================================
// MARK: - Utility Functions
//==================================================================================================

static OSStatus VocanaAudioServerPlugin_CreatePlugin(AudioServerPlugInDriverRef *outDriver) {
    if (!outDriver) {
        return kAudioHardwareIllegalOperationError;
    }

    // Allocate plugin structure
    VocanaAudioServerPlugin *plugin = SafeAlloc(VocanaAudioServerPlugin, 1);
    memset(plugin, 0, sizeof(VocanaAudioServerPlugin));

    // Initialize mutex
    if (pthread_mutex_init(&plugin->mutex, NULL) != 0) {
        free(plugin);
        ErrorMsg("Failed to initialize mutex");
        return kAudioHardwareUnspecifiedError;
    }

    // Initialize audio formats
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

    // Initialize state
    plugin->deviceCreated = false;
    plugin->ioStarted = false;
    plugin->clientCount = 0;
    plugin->bufferSize = 1024; // Default buffer size

    gPlugin = plugin;
    *outDriver = plugin;

    DebugMsg("VocanaAudioServerPlugin created successfully");
    return kAudioHardwareNoError;
}

static void VocanaAudioServerPlugin_DestroyPlugin(VocanaAudioServerPlugin *plugin) {
    if (!plugin) return;

    // Clean up resources
    if (plugin->inputBuffer) {
        free(plugin->inputBuffer);
        plugin->inputBuffer = NULL;
    }

    if (plugin->outputBuffer) {
        free(plugin->outputBuffer);
        plugin->outputBuffer = NULL;
    }

    pthread_mutex_destroy(&plugin->mutex);
    free(plugin);
    gPlugin = NULL;

    DebugMsg("VocanaAudioServerPlugin destroyed");
}

//==================================================================================================
// MARK: - IUnknown Interface Implementation
//==================================================================================================

static HRESULT VocanaAudioServerPlugin_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || !outInterface) {
        return kAudioHardwareIllegalOperationError;
    }

    CFUUIDRef requestedUUID = NULL;
    HRESULT result = kAudioHardwareUnsupportedOperationError;

    requestedUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (!requestedUUID) {
        return kAudioHardwareIllegalOperationError;
    }

    if (CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID) ||
        CFEqual(requestedUUID, IUnknownUUID)) {
        pthread_mutex_lock(&plugin->mutex);
        plugin->pluginRef = (AudioServerPlugInDriverRef)plugin;
        *outInterface = plugin;
        pthread_mutex_unlock(&plugin->mutex);
        result = kAudioHardwareNoError;
    }

    CFRelease(requestedUUID);
    return result;
}

static ULONG VocanaAudioServerPlugin_AddRef(void* inDriver) {
    // Simple refcount - we only have one instance
    return 1;
}

static ULONG VocanaAudioServerPlugin_Release(void* inDriver) {
    // Simple refcount - we only have one instance
    return 1;
}

//==================================================================================================
// MARK: - AudioServerPlugInDriverInterface Implementation
//==================================================================================================

static OSStatus VocanaAudioServerPlugin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || !inHost) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);
    plugin->hostRef = inHost;
    plugin->anchorHostTime = mach_absolute_time();
    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("VocanaAudioServerPlugin initialized with host");
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || !outDeviceObjectID) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);

    if (plugin->deviceCreated) {
        pthread_mutex_unlock(&plugin->mutex);
        return kAudioHardwareBadObjectError; // Device already exists
    }

    plugin->deviceObjectID = kObjectID_Device;
    plugin->deviceCreated = true;
    *outDeviceObjectID = plugin->deviceObjectID;

    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("Vocana virtual audio device created");
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);

    if (!plugin->deviceCreated || plugin->clientCount > 0) {
        pthread_mutex_unlock(&plugin->mutex);
        return kAudioHardwareBadObjectError;
    }

    plugin->deviceCreated = false;
    plugin->deviceObjectID = 0;

    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("Vocana virtual audio device destroyed");
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);
    plugin->clientCount++;
    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("Client added to Vocana device, total clients: %u", plugin->clientCount);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);
    if (plugin->clientCount > 0) {
        plugin->clientCount--;
    }
    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("Client removed from Vocana device, total clients: %u", plugin->clientCount);
    return kAudioHardwareNoError;
}

//==================================================================================================
// MARK: - Property Management - Forward Declarations
//==================================================================================================

static Boolean VocanaAudioServerPlugin_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static Boolean VocanaAudioServerPlugin_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static Boolean VocanaAudioServerPlugin_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static Boolean VocanaAudioServerPlugin_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static Boolean VocanaAudioServerPlugin_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);

static OSStatus VocanaAudioServerPlugin_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus VocanaAudioServerPlugin_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus VocanaAudioServerPlugin_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus VocanaAudioServerPlugin_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus VocanaAudioServerPlugin_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus VocanaAudioServerPlugin_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus VocanaAudioServerPlugin_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus VocanaAudioServerPlugin_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus VocanaAudioServerPlugin_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus VocanaAudioServerPlugin_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);

//==================================================================================================
// MARK: - Property Management
//==================================================================================================

static Boolean VocanaAudioServerPlugin_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || !inAddress) {
        return false;
    }

    Boolean hasProperty = false;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            hasProperty = VocanaAudioServerPlugin_HasPlugInProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Box:
            hasProperty = VocanaAudioServerPlugin_HasBoxProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Device:
            hasProperty = VocanaAudioServerPlugin_HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            hasProperty = VocanaAudioServerPlugin_HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        case kObjectID_Volume_Input_Master:
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Input_Master:
        case kObjectID_Mute_Output_Master:
            hasProperty = VocanaAudioServerPlugin_HasControlProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
        default:
            hasProperty = false;
            break;
    }

    return hasProperty;
}

static Boolean VocanaAudioServerPlugin_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    if (inObjectID != kObjectID_PlugIn) {
        return false;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyName:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return true;
        default:
            return false;
    }
}

static Boolean VocanaAudioServerPlugin_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    if (inObjectID != kObjectID_Box) {
        return false;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyDeviceList:
            return true;
        default:
            return false;
    }
}

static Boolean VocanaAudioServerPlugin_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inObjectID != kObjectID_Device) {
        return false;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        default:
            return false;
    }
}

static Boolean VocanaAudioServerPlugin_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin) {
        return false;
    }

    Boolean isInputStream = (inObjectID == kObjectID_Stream_Input);
    Boolean isOutputStream = (inObjectID == kObjectID_Stream_Output);

    if (!isInputStream && !isOutputStream) {
        return false;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean VocanaAudioServerPlugin_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin) {
        return false;
    }

    Boolean isVolumeControl = (inObjectID == kObjectID_Volume_Input_Master || inObjectID == kObjectID_Volume_Output_Master);
    Boolean isMuteControl = (inObjectID == kObjectID_Mute_Input_Master || inObjectID == kObjectID_Mute_Output_Master);

    if (!isVolumeControl && !isMuteControl) {
        return false;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioBooleanControlPropertyValue:
            return true;
        default:
            return false;
    }
}

//==================================================================================================
// MARK: - Property Data Access (Stubs for now)
//==================================================================================================

static OSStatus VocanaAudioServerPlugin_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    // For now, most properties are read-only
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    OSStatus result = kAudioHardwareUnknownPropertyError;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            result = VocanaAudioServerPlugin_GetPlugInPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Box:
            result = VocanaAudioServerPlugin_GetBoxPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Device:
            result = VocanaAudioServerPlugin_GetDevicePropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            result = VocanaAudioServerPlugin_GetStreamPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Volume_Input_Master:
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Input_Master:
        case kObjectID_Mute_Output_Master:
            result = VocanaAudioServerPlugin_GetControlPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
    }

    return result;
}

static OSStatus VocanaAudioServerPlugin_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    OSStatus result = kAudioHardwareUnknownPropertyError;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            result = VocanaAudioServerPlugin_GetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Box:
            result = VocanaAudioServerPlugin_GetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Device:
            result = VocanaAudioServerPlugin_GetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            result = VocanaAudioServerPlugin_GetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Volume_Input_Master:
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Input_Master:
        case kObjectID_Mute_Output_Master:
            result = VocanaAudioServerPlugin_GetControlPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
    }

    return result;
}

// Stub implementations for property data access - need to be implemented properly
static OSStatus VocanaAudioServerPlugin_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VocanaAudioServerPlugin_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    return kAudioHardwareUnknownPropertyError;
}

//==================================================================================================
// MARK: - IO Operations (Stubs for now)
//==================================================================================================

static OSStatus VocanaAudioServerPlugin_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);
    plugin->ioStarted = true;
    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("Vocana IO started for device %u", inDeviceObjectID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&plugin->mutex);
    plugin->ioStarted = false;
    pthread_mutex_unlock(&plugin->mutex);

    DebugMsg("Vocana IO stopped for device %u", inDeviceObjectID);
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device || !outSampleTime || !outHostTime || !outSeed) {
        return kAudioHardwareBadObjectError;
    }

    *outSampleTime = 0.0;
    *outHostTime = plugin->anchorHostTime;
    *outSeed = 1;

    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device || !outWillDo || !outWillDoInPlace) {
        return kAudioHardwareBadObjectError;
    }

    // For now, handle read/write operations
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            *outWillDo = true;
            *outWillDoInPlace = false;
            break;
        default:
            *outWillDo = false;
            *outWillDoInPlace = false;
            break;
    }

    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    // Allocate buffers if needed
    pthread_mutex_lock(&plugin->mutex);
    if (plugin->bufferSize != inIOBufferFrameSize * kBytes_Per_Frame) {
        plugin->bufferSize = inIOBufferFrameSize * kBytes_Per_Frame;

        if (plugin->inputBuffer) free(plugin->inputBuffer);
        if (plugin->outputBuffer) free(plugin->outputBuffer);

        plugin->inputBuffer = SafeAlloc(uint8_t, plugin->bufferSize);
        plugin->outputBuffer = SafeAlloc(uint8_t, plugin->bufferSize);
    }
    pthread_mutex_unlock(&plugin->mutex);

    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    VocanaAudioServerPlugin *plugin = (VocanaAudioServerPlugin *)inDriver;

    if (!plugin || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    // Validate buffer parameters
    if (inIOBufferFrameSize == 0 || inIOBufferFrameSize > 4096) {
        ErrorMsg("Invalid IO buffer frame size: %u", inIOBufferFrameSize);
        return kAudioHardwareBadObjectError;
    }

    // Ensure we have valid buffers allocated
    pthread_mutex_lock(&plugin->mutex);
    Boolean hasValidBuffers = (plugin->inputBuffer != NULL && plugin->outputBuffer != NULL);
    pthread_mutex_unlock(&plugin->mutex);

    if (!hasValidBuffers) {
        ErrorMsg("IO operation attempted without valid buffers");
        return kAudioHardwareBadObjectError;
    }

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            // For input stream, provide silence or loopback data
            if (inStreamObjectID == kObjectID_Stream_Input && ioMainBuffer) {
                // Validate buffer size doesn't overflow
                size_t bufferSize = inIOBufferFrameSize * kBytes_Per_Frame;
                if (bufferSize > plugin->bufferSize) {
                    ErrorMsg("Input buffer size overflow: %zu > %u", bufferSize, plugin->bufferSize);
                    return kAudioHardwareBadObjectError;
                }
                memset(ioMainBuffer, 0, bufferSize);
            }
            break;

        case kAudioServerPlugInIOOperationWriteMix:
            // For output stream, consume the data (could send to Swift processing)
            if (inStreamObjectID == kObjectID_Stream_Output && ioMainBuffer) {
                // Validate buffer size
                size_t bufferSize = inIOBufferFrameSize * kBytes_Per_Frame;
                if (bufferSize > plugin->bufferSize) {
                    ErrorMsg("Output buffer size overflow: %zu > %u", bufferSize, plugin->bufferSize);
                    return kAudioHardwareBadObjectError;
                }
                // Data is available for processing - in a real implementation,
                // this would be sent to the Swift audio processing pipeline
                DebugMsg("Received %u frames of output audio data", inIOBufferFrameSize);
            }
            break;

        default:
            return kAudioHardwareUnsupportedOperationError;
    }

    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    // Cleanup if needed
    return kAudioHardwareNoError;
}

// Stub implementations for remaining operations
static OSStatus VocanaAudioServerPlugin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VocanaAudioServerPlugin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VocanaAudioServerPlugin_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    return kAudioHardwareUnsupportedOperationError;
}

//==================================================================================================
// MARK: - Plugin Interface Table
//==================================================================================================

static AudioServerPlugInDriverInterface gVocanaAudioServerPluginInterface = {
    NULL,   // _reserved
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
// MARK: - Factory Function
//==================================================================================================

void* VocanaAudioServerPlugin_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    AudioServerPlugInDriverRef driver = NULL;
    if (VocanaAudioServerPlugin_CreatePlugin(&driver) != kAudioHardwareNoError) {
        return NULL;
    }

    return driver;
}