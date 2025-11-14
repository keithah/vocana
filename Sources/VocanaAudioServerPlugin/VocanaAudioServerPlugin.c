/*
    Minimal Vocana HAL Plugin - Working Version
*/

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <sys/syslog.h>
#include <mach/mach_time.h>

#define DebugMsg(...) syslog(LOG_NOTICE, "VocanaHAL: " __VA_ARGS__)
#define ErrorMsg(...) syslog(LOG_ERR, "VocanaHAL ERROR: " __VA_ARGS__)

#define kObjectID_PlugIn 1
#define kObjectID_Device 2

typedef struct {
    AudioServerPlugInHostRef hostRef;
    pthread_mutex_t mutex;
    Float64 sampleRate;
} VocanaPlugin;

static VocanaPlugin *gPlugin = NULL;

void* VocanaAudioServerPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    DebugMsg("Factory called");
    
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        DebugMsg("Wrong UUID type");
        return NULL;
    }
    
    VocanaPlugin *plugin = calloc(1, sizeof(VocanaPlugin));
    if (!plugin) {
        ErrorMsg("Failed to allocate plugin");
        return NULL;
    }
    
    pthread_mutex_init(&plugin->mutex, NULL);
    plugin->sampleRate = 48000.0;
    
    gPlugin = plugin;
    DebugMsg("Plugin created successfully");
    return plugin;
}

static HRESULT VocanaAudioServerPlugin_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (!inDriver || !outInterface) return E_POINTER;
    
    CFUUIDRef requestedUUID = (CFUUIDRef)*(const void**)&inUUID;
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

static OSStatus VocanaAudioServerPlugin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    VocanaPlugin *plugin = (VocanaPlugin*)inDriver;
    if (!plugin || !inHost) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    plugin->hostRef = inHost;
    pthread_mutex_unlock(&plugin->mutex);
    
    DebugMsg("Plugin initialized");
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    VocanaPlugin *plugin = (VocanaPlugin*)inDriver;
    if (!plugin || !outDeviceObjectID) return kAudioHardwareBadObjectError;
    
    pthread_mutex_lock(&plugin->mutex);
    *outDeviceObjectID = kObjectID_Device;
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

static Boolean VocanaAudioServerPlugin_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    if (!inDriver || !inAddress) return false;
    
    switch (inObjectID) {
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioObjectPropertyOwnedObjects:
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
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
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
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
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

static OSStatus VocanaAudioServerPlugin_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioBufferList, void* outBufferList) {
    return kAudioHardwareNoError;
}

static OSStatus VocanaAudioServerPlugin_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

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