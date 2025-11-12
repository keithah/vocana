//
//  VocanaAudioServerPlugin.c
//  VocanaAudioServerPlugin
//
//  Core Audio HAL Plugin for Virtual Audio Devices
//

#include "VocanaAudioServerPlugin.h"
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/syslog.h>
#include <Accelerate/Accelerate.h>

// ============================================================================
// MARK: - Macros
// ============================================================================

#if TARGET_RT_BIG_ENDIAN
#define    FourCCToCString(the4CC)    { ((char*)&the4CC)[0], ((char*)&the4CC)[1], ((char*)&the4CC)[2], ((char*)&the4CC)[3], 0 }
#else
#define    FourCCToCString(the4CC)    { ((char*)&the4CC)[3], ((char*)&the4CC)[2], ((char*)&the4CC)[1], ((char*)&the4CC)[0], 0 }
#endif

#ifndef __MAC_12_0
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

// Fix for deprecated constants
#ifndef kAudioDevicePropertyAvailableSampleRates
#define kAudioDevicePropertyAvailableSampleRates 'asrt'
#endif

#if DEBUG
    #define    DebugMsg(inFormat, ...)    syslog(LOG_NOTICE, inFormat, ## __VA_ARGS__)
    #define    FailIf(inCondition, inHandler, inMessage)                           \
    if(inCondition)                                                                \
    {                                                                              \
        DebugMsg(inMessage);                                                       \
        goto inHandler;                                                            \
    }
    #define    FailWithAction(inCondition, inAction, inHandler, inMessage)         \
    if(inCondition)                                                                \
    {                                                                              \
        DebugMsg(inMessage);                                                       \
        { inAction; }                                                              \
        goto inHandler;                                                                \
    }
#else
    #define    DebugMsg(inFormat, ...)
    #define    FailIf(inCondition, inHandler, inMessage)                           \
    if(inCondition)                                                                \
    {                                                                              \
    goto inHandler;                                                                \
    }
    #define    FailWithAction(inCondition, inAction, inHandler, inMessage)         \
    if(inCondition)                                                                \
    {                                                                              \
    { inAction; }                                                                  \
    goto inHandler;                                                                \
    }
#endif

// ============================================================================
// MARK: - Global State
// ============================================================================

static pthread_mutex_t              gPlugIn_StateMutex                  = PTHREAD_MUTEX_INITIALIZER;
static UInt32                       gPlugIn_RefCount                    = 0;
static AudioServerPlugInHostRef     gPlugIn_Host                        = NULL;

static CFStringRef                  gBox_Name                           = NULL;
static Boolean                      gBox_Acquired                       = true;

static pthread_mutex_t              gDevice_IOMutex                     = PTHREAD_MUTEX_INITIALIZER;
static Float64                      gDevice_SampleRate                  = 48000.0;
static Float64                      gDevice_RequestedSampleRate         = 0.0;
static UInt64                       gDevice_IOIsRunning                 = 0;
static const UInt32                 kDevice_RingBufferSize              = 16384;
static Float64                      gDevice_HostTicksPerFrame           = 0.0;
static Float64                      gDevice_AdjustedTicksPerFrame       = 0.0;
static Float64                      gDevice_PreviousTicks               = 0.0;
static UInt64                       gDevice_NumberTimeStamps            = 0;
static Float64                      gDevice_AnchorSampleTime            = 0.0;
static UInt64                       gDevice_AnchorHostTime              = 0;

static bool                         gStream_Input_IsActive              = true;
static bool                         gStream_Output_IsActive             = true;

static const Float32                kVolume_MinDB                       = -64.0;
static const Float32                kVolume_MaxDB                       = 0.0;
static Float32                      gVolume_Master_Value                = 1.0;
static bool                         gMute_Master_Value                  = false;

static Float64                      kDevice_SampleRates[]               = { kSampleRates };
static const UInt32                 kDevice_SampleRatesSize             = sizeof(kDevice_SampleRates) / sizeof(Float64);

// ============================================================================
// MARK: - AudioServerPlugInDriverInterface Implementation
// ============================================================================

#pragma mark Prototypes

// Entry points for the COM methods
void*                VocanaAudioServerPlugin_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
static HRESULT        Vocana_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        Vocana_AddRef(void* inDriver);
static ULONG        Vocana_Release(void* inDriver);
static OSStatus        Vocana_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus        Vocana_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus        Vocana_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus        Vocana_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus        Vocana_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus        Vocana_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus        Vocana_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean        Vocana_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        Vocana_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        Vocana_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        Vocana_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        Vocana_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus        Vocana_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus        Vocana_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus        Vocana_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus        Vocana_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus        Vocana_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus        Vocana_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus        Vocana_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

// Implementation
static Boolean        Vocana_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        Vocana_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        Vocana_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        Vocana_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        Vocana_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        Vocana_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        Vocana_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        Vocana_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        Vocana_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        Vocana_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        Vocana_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        Vocana_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        Vocana_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        Vocana_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        Vocana_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean        Vocana_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus        Vocana_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus        Vocana_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus        Vocana_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus        Vocana_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

#pragma mark The Interface

static AudioServerPlugInDriverInterface    gVocanaAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverInterface*    gVocanaAudioServerPlugInDriverInterfacePtr    = &gVocanaAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef            gVocanaAudioServerPlugInDriverRef                = &gVocanaAudioServerPlugInDriverInterfacePtr;

// ============================================================================
// MARK: - Utility Functions
// ============================================================================

static bool is_valid_sample_rate(Float64 sample_rate)
{
    for(UInt32 i = 0; i < kDevice_SampleRatesSize; i++)
    {
        if (sample_rate == kDevice_SampleRates[i])
        {
            return true;
        }
    }
    return false;
}

// ============================================================================
// MARK: - Factory
// ============================================================================

void* VocanaAudioServerPlugin_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        theAnswer = gVocanaAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

// ============================================================================
// MARK: - Inheritance
// ============================================================================

static HRESULT Vocana_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    // declare the local variables
    HRESULT theAnswer = 0;
    CFUUIDRef theRequestedUUID = NULL;

    // validate the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_QueryInterface: bad driver reference");
    FailWithAction(outInterface == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_QueryInterface: no place to store the returned interface");

    // make a CFUUIDRef from inUUID
    theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    FailWithAction(theRequestedUUID == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_QueryInterface: failed to create the CFUUIDRef");

    // AudioServerPlugIns only support two interfaces, IUnknown (which has to be supported by all
    // CFPlugIns and AudioServerPlugInDriverInterface (which is the actual interface the HAL will
    // use).
    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gVocanaAudioServerPlugInDriverRef;
    }
    else
    {
        theAnswer = E_NOINTERFACE;
    }

    // make sure to release the UUID we created
    CFRelease(theRequestedUUID);

Done:
    return theAnswer;
}

static ULONG Vocana_AddRef(void* inDriver)
{
    // This call returns the resulting reference count after the increment.

    // declare the local variables
    ULONG theAnswer = 0;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_AddRef: bad driver reference");

    // increment the refcount
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount < UINT32_MAX)
    {
        ++gPlugIn_RefCount;
    }
    theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

static ULONG Vocana_Release(void* inDriver)
{
    // This call returns the resulting reference count after the decrement.

    // declare the local variables
    ULONG theAnswer = 0;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_Release: bad driver reference");

    // decrement the refcount
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount > 0)
    {
        --gPlugIn_RefCount;
        // Note that we don't do anything special if the refcount goes to zero as the HAL
        // will never fully release a plug-in it opens. We keep managing the refcount so that
        // the API semantics are correct though.
    }
    theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - Basic Operations
// ============================================================================

static OSStatus Vocana_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    // The job of this method is, as the name implies, to get the driver initialized. One specific
    // thing that needs to be done is to store the AudioServerPlugInHostRef so that it can be used
    // later. Note that when this call returns, the HAL will scan the various lists the driver
    // maintains (such as the device list) to get the initial set of objects the driver is
    // publishing. So, there is no need to notify the HAL about any objects created as part of the
    // execution of this method.

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_Initialize: bad driver reference");

    // store the AudioServerPlugInHostRef
    gPlugIn_Host = inHost;

    // initialize the box name directly as a last resort
    if(gBox_Name == NULL)
    {
        gBox_Name = CFSTR("Vocana Box");
    }

    // calculate the host ticks per frame
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
    theHostClockFrequency *= 1000000000.0;
    gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
    gDevice_AdjustedTicksPerFrame = gDevice_HostTicksPerFrame;

    DebugMsg("Vocana theTimeBaseInfo.numer: %u \t theTimeBaseInfo.denom: %u", theTimeBaseInfo.numer, theTimeBaseInfo.denom);

Done:
    return theAnswer;
}

static OSStatus Vocana_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    // This method is used to tell a driver that implements the Transport Manager semantics to
    // create an AudioEndpointDevice from a set of AudioEndpoints. Since this driver is not a
    // Transport Manager, we just check the arguments and return
    // kAudioHardwareUnsupportedOperationError.

    #pragma unused(inDescription, inClientInfo, outDeviceObjectID)

    // declare the local variables
    OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_CreateDevice: bad driver reference");

Done:
    return theAnswer;
}

static OSStatus Vocana_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    // This method is used to tell a driver that implements the Transport Manager semantics to
    // destroy an AudioEndpointDevice. Since this driver is not a Transport Manager, we just check
    // the arguments and return kAudioHardwareUnsupportedOperationError.

    #pragma unused(inDeviceObjectID)

    // declare the local variables
    OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_DestroyDevice: bad driver reference");

Done:
    return theAnswer;
}

static OSStatus Vocana_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    // This method is used to inform the driver about a new client that is using the given device.
    // This allows the device to act differently depending on who the client is. This driver does
    // not need to track the clients using the device, so we just check the arguments and return
    // successfully.

    #pragma unused(inClientInfo)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_AddDeviceClient: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_AddDeviceClient: bad device ID");

Done:
    return theAnswer;
}

static OSStatus Vocana_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    // This method is used to inform the driver about a client that is no longer using the given
    // device. This driver does not track clients, so we just check the arguments and return
    // successfully.

    #pragma unused(inClientInfo)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_RemoveDeviceClient: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_RemoveDeviceClient: bad device ID");

Done:
    return theAnswer;
}

static OSStatus Vocana_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    // This method is called to tell the device that it can perform the configuration change that it
    // had requested via a call to the host method, RequestDeviceConfigurationChange(). The
    // arguments, inChangeAction and inChangeInfo are the same as what was passed to
    // RequestDeviceConfigurationChange().
    //
    // The HAL guarantees that IO will be stopped while this method is in progress. The HAL will
    // also handle figuring out exactly what changed for the non-control related properties. This
    // means that the only notifications that would need to be sent here would be for either
    // custom properties the HAL doesn't know about or for controls.
    //
    // For the device implemented by this driver, sample rate changes and enabling/disabling
    // the pitch adjust go through this process.
    // These are the only states that can be changed for the device that aren't controls.
    // Which change is requested is passed in the inChangeAction argument.

    #pragma unused(inChangeInfo)

    // declare the local variables
    OSStatus theAnswer = 0;
    Float64 newSampleRate = 0.0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_PerformDeviceConfigurationChange: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_PerformDeviceConfigurationChange: bad device ID");

    // For now, we don't support any configuration changes
    theAnswer = kAudioHardwareUnsupportedOperationError;

Done:
    return theAnswer;
}

static OSStatus Vocana_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    // This method is called to tell the driver that a request for a config change has been denied.
    // This provides the driver an opportunity to clean up any state associated with the request.
    // For this driver, an aborted config change requires no action. So we just check the arguments
    // and return

    #pragma unused(inChangeAction, inChangeInfo)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_PerformDeviceConfigurationChange: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_PerformDeviceConfigurationChange: bad device ID");

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - Property Operations
// ============================================================================

static Boolean Vocana_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    // This method returns whether or not the given object has the given property.

    // declare the local variables
    Boolean theAnswer = false;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_HasProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "Vocana_HasProperty: no address");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPropertyData() method.
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = Vocana_HasPlugInProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Box:
            theAnswer = Vocana_HasBoxProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Device:
            theAnswer = Vocana_HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            theAnswer = Vocana_HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    // This method returns whether or not the given property on the object can have its value
    // changed.

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsPropertySettable: no place to put the return value");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPropertyData() method.
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = Vocana_IsPlugInPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Box:
            theAnswer = Vocana_IsBoxPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Device:
            theAnswer = Vocana_IsDevicePropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            theAnswer = Vocana_IsStreamPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    // This method returns the byte size of the property's data.

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPropertyDataSize: no place to put the return value");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPropertyData() method.
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = Vocana_GetPlugInPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Box:
            theAnswer = Vocana_GetBoxPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Device:
            theAnswer = Vocana_GetDevicePropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            theAnswer = Vocana_GetStreamPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPropertyData: no place to put the return value");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required.
    //
    // Also, since most of the data that will get returned is static, there are few instances where
    // it is necessary to lock the state mutex.
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = Vocana_GetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;

        case kObjectID_Box:
            theAnswer = Vocana_GetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;

        case kObjectID_Device:
            theAnswer = Vocana_GetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            theAnswer = Vocana_GetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    // declare the local variables
    OSStatus theAnswer = 0;
    UInt32 theNumberPropertiesChanged = 0;
    AudioObjectPropertyAddress theChangedAddresses[2];

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetPropertyData: no address");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPropertyData() method.
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = Vocana_SetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;

        case kObjectID_Box:
            theAnswer = Vocana_SetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;

        case kObjectID_Device:
            theAnswer = Vocana_SetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            theAnswer = Vocana_SetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

    // send any notifications
    if(theNumberPropertiesChanged > 0)
    {
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberPropertiesChanged, theChangedAddresses);
    }

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - IO Operations (Stub implementations for Phase 1)
// ============================================================================

static OSStatus Vocana_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_StartIO: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_StartIO: bad device ID");
Done:
    return theAnswer;
}

static OSStatus Vocana_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_StopIO: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_StopIO: bad device ID");
Done:
    return theAnswer;
}

static OSStatus Vocana_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetZeroTimeStamp: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetZeroTimeStamp: bad device ID");
    FailWithAction(outSampleTime == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetZeroTimeStamp: no place to put the sample time");
    FailWithAction(outHostTime == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetZeroTimeStamp: no place to put the host time");
    FailWithAction(outSeed == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetZeroTimeStamp: no place to put the seed");

    *outSampleTime = 0.0;
    *outHostTime = mach_absolute_time();
    *outSeed = 1;

Done:
    return theAnswer;
}

static OSStatus Vocana_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_WillDoIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_WillDoIOOperation: bad device ID");
    FailWithAction(outWillDo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_WillDoIOOperation: no place to put the will do");
    FailWithAction(outWillDoInPlace == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_WillDoIOOperation: no place to put the will do in place");

    *outWillDo = true;
    *outWillDoInPlace = true;

Done:
    return theAnswer;
}

static OSStatus Vocana_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_BeginIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_BeginIOOperation: bad device ID");
Done:
    return theAnswer;
}

static OSStatus Vocana_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo, ioMainBuffer, ioSecondaryBuffer)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_DoIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_DoIOOperation: bad device ID");
    FailWithAction((inStreamObjectID != kObjectID_Stream_Input) && (inStreamObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_DoIOOperation: bad stream ID");
Done:
    return theAnswer;
}

static OSStatus Vocana_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    OSStatus theAnswer = 0;
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_EndIOOperation: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_EndIOOperation: bad device ID");
Done:
    return theAnswer;
}

// ============================================================================
// MARK: - PlugIn Property Operations
// ============================================================================

static Boolean Vocana_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    Boolean theAnswer = false;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_HasPlugInProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "Vocana_HasPlugInProperty: no address");
    FailIf(inObjectID != kObjectID_PlugIn, Done, "Vocana_HasPlugInProperty: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPlugInPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsPlugInPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsPlugInPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsPlugInPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsPlugInPropertySettable: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPlugInPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            *outIsSettable = false;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetPlugInPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPlugInPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPlugInPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetPlugInPropertyDataSize: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPlugInPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 2 * sizeof(AudioClassID);
            break;

        case kAudioPlugInPropertyBoxList:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioPlugInPropertyTranslateUIDToBox:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetPlugInPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPlugInPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPlugInPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetPlugInPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetPlugInPropertyData: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required.
    //
    // Also, since most of the data that will get returned is static, there are few instances where
    // it is necessary to lock the state mutex.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            // The base class for kAudioPlugInClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the plug-in");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            // The class is always kAudioPlugInClassID for regular drivers
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the plug-in");
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            // The plug-in doesn't have an owning object
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the plug-in");
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyManufacturer:
            // This is the human readable name of the maker of the plug-in.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the plug-in");
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            // Calculate the number of items that have been requested. Note that this
            // number is allowed to be smaller than the actual size of the list. In such
            // case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            // Clamp that to the number of boxes this driver implements (which is just 1)
            if(theNumberItemsToFetch > 2)
            {
                theNumberItemsToFetch = 2;
            }

            // Write the objects' object IDs into the return value
            if(theNumberItemsToFetch > 1)
            {
                ((AudioObjectID*)outData)[0] = kObjectID_Box;
                ((AudioObjectID*)outData)[1] = kObjectID_Device;
            }
            else if(theNumberItemsToFetch > 0)
            {
                ((AudioObjectID*)outData)[0] = kObjectID_Box;
            }

            // Return how many bytes we wrote to
            *outDataSize = theNumberItemsToFetch * sizeof(AudioClassID);
            break;

        case kAudioPlugInPropertyBoxList:
            // Calculate the number of items that have been requested. Note that this
            // number is allowed to be smaller than the actual size of the list. In such
            // case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            // Clamp that to the number of boxes this driver implements (which is just 1)
            if(theNumberItemsToFetch > 1)
            {
                theNumberItemsToFetch = 1;
            }

            // Write the boxes' object IDs into the return value
            if(theNumberItemsToFetch > 0)
            {
                ((AudioObjectID*)outData)[0] = kObjectID_Box;
            }

            // Return how many bytes we wrote to
            *outDataSize = theNumberItemsToFetch * sizeof(AudioClassID);
            break;

        case kAudioPlugInPropertyTranslateUIDToBox:
            // This property takes the CFString passed in the qualifier and converts that
            // to the object ID of the box it corresponds to. For this driver, there is
            // just the one box. Note that it is not an error if the string in the
            // qualifier doesn't match any boxes. In such case, kAudioObjectUnknown is
            // the object ID to return.
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyTranslateUIDToBox");
            FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToBox");
            FailWithAction(inQualifierData == NULL, theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToBox");

            if(CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kBox_UID), 0) == kCFCompareEqualTo)
            {
                *((AudioObjectID*)outData) = kObjectID_Box;
            }
            else
            {
                *((AudioObjectID*)outData) = kAudioObjectUnknown;
            }
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyDeviceList:
            // Calculate the number of items that have been requested. Note that this
            // number is allowed to be smaller than the actual size of the list. In such
            // case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            // Clamp that to the number of devices this driver implements (which is just 1)
            if(theNumberItemsToFetch > 1)
            {
                theNumberItemsToFetch = 1;
            }

            // Write the devices' object IDs into the return value
            if(theNumberItemsToFetch > 0)
            {
                ((AudioObjectID*)outData)[0] = kObjectID_Device;
            }

            // Return how many bytes we wrote to
            *outDataSize = theNumberItemsToFetch * sizeof(AudioClassID);
            break;

        case kAudioPlugInPropertyTranslateUIDToDevice:
            // This property takes the CFString passed in the qualifier and converts that
            // to the object ID of the device it corresponds to. For this driver, there is
            // just the one device. Note that it is not an error if the string in the
            // qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
            // the object ID to return.
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyTranslateUIDToDevice");
            FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToDevice");
            FailWithAction(inQualifierData == NULL, theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToDevice");

            if(CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
            {
                *((AudioObjectID*)outData) = kObjectID_Device;
            }
            else
            {
                *((AudioObjectID*)outData) = kAudioObjectUnknown;
            }
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyResourceBundle:
            // The resource bundle is a path relative to the path of the plug-in's bundle.
            // To specify that the plug-in bundle itself should be used, we just return the
            // empty string.
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyResourceBundle");
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetPlugInPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetPlugInPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetPlugInPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetPlugInPropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetPlugInPropertyData: not the plug-in object");

    // initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetPlugInPropertyData() method.
    switch(inAddress->mSelector)
    {
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - Box Property Operations
// ============================================================================

static Boolean Vocana_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    Boolean theAnswer = false;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_HasBoxProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "Vocana_HasBoxProperty: no address");
    FailIf(inObjectID != kObjectID_Box, Done, "Vocana_HasBoxProperty: not the box object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetBoxPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsBoxPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsBoxPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsBoxPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsBoxPropertySettable: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetBoxPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            *outIsSettable = false;
            break;

        case kAudioObjectPropertyName:
        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyAcquired:
            *outIsSettable = true;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetBoxPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetBoxPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetBoxPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetBoxPropertyDataSize: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetBoxPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyModelName:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            break;

        case kAudioObjectPropertyIdentify:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioObjectPropertySerialNumber:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyFirmwareVersion:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioBoxPropertyBoxUID:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioBoxPropertyTransportType:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasAudio:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasVideo:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasMIDI:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyIsProtected:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyAcquired:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyAcquisitionFailed:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetBoxPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetBoxPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetBoxPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetBoxPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetBoxPropertyData: not the plug-in object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required.
    //
    // Also, since most of the data that will get returned is static, there are few instances where
    // it is necessary to lock the state mutex.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            // The base class for kAudioBoxClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the box");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            // The class is always kAudioBoxClassID for regular drivers
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the box");
            *((AudioClassID*)outData) = kAudioBoxClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            // The owner is the plug-in object
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the box");
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            // This is the human readable name of the box.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((CFStringRef*)outData) = gBox_Name;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            if(*((CFStringRef*)outData) != NULL)
            {
                CFRetain(*((CFStringRef*)outData));
            }
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyModelName:
            // This is the human readable name of the box.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
            *((CFStringRef*)outData) = CFSTR(kDriver_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            // This is the human readable name of the maker of the box.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            // This returns the objects directly owned by the object. Boxes don't own anything.
            *outDataSize = 0;
            break;

        case kAudioObjectPropertyIdentify:
            // This is used to highling the device in the UI, but it's value has no meaning
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyIdentify for the box");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioObjectPropertySerialNumber:
            // This is the human readable serial number of the box.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertySerialNumber for the box");
            *((CFStringRef*)outData) = CFSTR("vocana-001");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyFirmwareVersion:
            // This is the human readable firmware version of the box.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyFirmwareVersion for the box");
            *((CFStringRef*)outData) = CFSTR("1.0.0");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioBoxPropertyBoxUID:
            // Boxes have UIDs the same as devices
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
            *((CFStringRef*)outData) = CFSTR(kBox_UID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioBoxPropertyTransportType:
            // This value represents how the device is attached to the system. This can be
            // any 32 bit integer, but common values for this property are defined in
            // <CoreAudio/AudioHardwareBase.h>
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the box");
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasAudio:
            // Indicates whether or not the box has audio capabilities
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasAudio for the box");
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasVideo:
            // Indicates whether or not the box has video capabilities
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasVideo for the box");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasMIDI:
            // Indicates whether or not the box has MIDI capabilities
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasMIDI for the box");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyIsProtected:
            // Indicates whether or not the box has requires authentication to use
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyIsProtected for the box");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyAcquired:
            // When set to a non-zero value, the device is acquired for use by the local machine
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyAcquired for the box");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = gBox_Acquired ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyAcquisitionFailed:
            // Indicates whether or not the box failed to be acquired
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyAcquisitionFailed for the box");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyDeviceList:
            // Calculate the number of items that have been requested. Note that this
            // number is allowed to be smaller than the actual size of the list. In such
            // case, only that number of items will be returned
            {
                UInt32 theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

                // Clamp that to the number of devices this box implements (which is just 1)
                if(theNumberItemsToFetch > 1)
                {
                    theNumberItemsToFetch = 1;
                }

                // Write the devices' object IDs into the return value
                if(theNumberItemsToFetch > 0)
                {
                    ((AudioObjectID*)outData)[0] = kObjectID_Device;
                }

                // Return how many bytes we wrote to
                *outDataSize = theNumberItemsToFetch * sizeof(AudioClassID);
            }
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetBoxPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetBoxPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetBoxPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetBoxPropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetBoxPropertyData: not the plug-in object");

    // initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetBoxPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyName:
            // Setting the name of the box
            FailWithAction(inDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyName");
            FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetBoxPropertyData: no data to set for kAudioObjectPropertyName");

            pthread_mutex_lock(&gPlugIn_StateMutex);
            if(gBox_Name != NULL)
            {
                CFRelease(gBox_Name);
            }
            gBox_Name = *((CFStringRef*)inData);
            if(gBox_Name != NULL)
            {
                CFRetain(gBox_Name);
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            *outNumberPropertiesChanged = 1;
            outChangedAddresses[0].mSelector = kAudioObjectPropertyName;
            outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
            outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
            break;

        case kAudioObjectPropertyIdentify:
            // Setting the identify property has no meaning for this driver
            FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyIdentify");
            FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetBoxPropertyData: no data to set for kAudioObjectPropertyIdentify");

            // We don't do anything with this, but we need to indicate success
            *outNumberPropertiesChanged = 1;
            outChangedAddresses[0].mSelector = kAudioObjectPropertyIdentify;
            outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
            outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
            break;

        case kAudioBoxPropertyAcquired:
            // Setting the acquired property
            FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_SetBoxPropertyData: wrong size for the data for kAudioBoxPropertyAcquired");
            FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetBoxPropertyData: no data to set for kAudioBoxPropertyAcquired");

            pthread_mutex_lock(&gPlugIn_StateMutex);
            gBox_Acquired = (*((UInt32*)inData) != 0);
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            *outNumberPropertiesChanged = 1;
            outChangedAddresses[0].mSelector = kAudioBoxPropertyAcquired;
            outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
            outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - Device Property Operations
// ============================================================================

static Boolean Vocana_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    Boolean theAnswer = false;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_HasDeviceProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "Vocana_HasDeviceProperty: no address");
    FailIf(inObjectID != kObjectID_Device, Done, "Vocana_HasDeviceProperty: not the device object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetDevicePropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
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
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyConfigurationApplication:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsDevicePropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsDevicePropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsDevicePropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsDevicePropertySettable: not the device object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetDevicePropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
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
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyConfigurationApplication:
            *outIsSettable = false;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetDevicePropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetDevicePropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetDevicePropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetDevicePropertyDataSize: not the device object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetDevicePropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyModelName:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 2 * sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyIdentify:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioObjectPropertySerialNumber:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyFirmwareVersion:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyDeviceUID:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyTransportType:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = 0;
            break;

        case kAudioDevicePropertyClockDomain:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsAlive:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyDeviceIsRunning:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyLatency:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyStreams:
            *outDataSize = 2 * sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            break;

        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyAvailableSampleRates:
            *outDataSize = kDevice_SampleRatesSize * sizeof(AudioValueRange);
            break;

        case kAudioDevicePropertyIsHidden:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyIcon:
            *outDataSize = sizeof(CFURLRef);
            break;

        case kAudioDevicePropertyConfigurationApplication:
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetDevicePropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetDevicePropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetDevicePropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetDevicePropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetDevicePropertyData: not the device object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required.
    //
    // Also, since most of the data that will get returned is static, there are few instances where
    // it is necessary to lock the state mutex.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            // The base class for kAudioDeviceClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the device");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            // The class is always kAudioDeviceClassID for regular drivers
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyClass for the device");
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            // The owner is the box object
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the device");
            *((AudioObjectID*)outData) = kObjectID_Box;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            // This is the human readable name of the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyName for the device");
            *((CFStringRef*)outData) = CFSTR(kDevice_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyModelName:
            // This is the human readable name of the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyModelName for the device");
            *((CFStringRef*)outData) = CFSTR(kDriver_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            // This is the human readable name of the maker of the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the device");
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            // Calculate the number of items that have been requested. Note that this
            // number is allowed to be smaller than the actual size of the list. In such
            // case, only that number of items will be returned
            {
                UInt32 theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

                // Clamp that to the number of streams this driver implements (which is 2)
                if(theNumberItemsToFetch > 2)
                {
                    theNumberItemsToFetch = 2;
                }

                // Write the streams' object IDs into the return value
                if(theNumberItemsToFetch > 1)
                {
                    ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
                    ((AudioObjectID*)outData)[1] = kObjectID_Stream_Output;
                }
                else if(theNumberItemsToFetch > 0)
                {
                    ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
                }

                // Return how many bytes we wrote to
                *outDataSize = theNumberItemsToFetch * sizeof(AudioClassID);
            }
            break;

        case kAudioObjectPropertyIdentify:
            // This is used to highling the device in the UI, but it's value has no meaning
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyIdentify for the device");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioObjectPropertySerialNumber:
            // This is the human readable serial number of the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertySerialNumber for the device");
            *((CFStringRef*)outData) = CFSTR("vocana-device-001");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyFirmwareVersion:
            // This is the human readable firmware version of the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyFirmwareVersion for the device");
            *((CFStringRef*)outData) = CFSTR("1.0.0");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyDeviceUID:
            // This is a CFString that contains a persistent identifier for the device. The
            // content of this property must not change across boots, and must not change when
            // the device is unplugged and replugged. The content of this property is stored
            // in the user preferences and used to track the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceUID for the device");
            *((CFStringRef*)outData) = CFSTR(kDevice_UID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyModelUID:
            // This is a CFString that contains a persistent identifier for the model of the device.
            // The content of this property must not change across boots, and must not change when
            // the device is unplugged and replugged. The content of this property is stored
            // in the user preferences and used to track the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyModelUID for the device");
            *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyTransportType:
            // This value represents how the device is attached to the system. This can be
            // any 32 bit integer, but common values for this property are defined in
            // <CoreAudio/AudioHardwareBase.h>
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the device");
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyRelatedDevices:
            // The related devices property returns an array of device IDs that are related to
            // the given device. For this driver, there are no related devices, so we return an
            // empty array.
            *outDataSize = 0;
            break;

        case kAudioDevicePropertyClockDomain:
            // This property returns the clock domain that the device belongs to. Note that
            // devices that don't know about clock domains can return 0. This driver doesn't
            // know about clock domains, so it returns 0.
            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyClockDomain for the device");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsAlive:
            // This property returns whether or not the device is alive. For this driver, the
            // device is always alive.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceIsAlive for the device");
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsRunning:
            // This property returns whether or not the device is running. For this driver, the
            // device is running if there are any IO operations running.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceIsRunning for the device");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = (gDevice_IOIsRunning > 0) ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // This property returns whether or not the device can be the default device.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceCanBeDefaultDevice for the device");
            *((UInt32*)outData) = kCanBeDefaultDevice ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            // This property returns whether or not the device can be the default system device.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceCanBeDefaultSystemDevice for the device");
            *((UInt32*)outData) = kCanBeDefaultSystemDevice ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyLatency:
            // This property returns the latency of the device.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyLatency for the device");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyStreams:
            // Calculate the number of items that have been requested. Note that this
            // number is allowed to be smaller than the actual size of the list. In such
            // case, only that number of items will be returned
            {
                UInt32 theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

                // Clamp that to the number of streams this driver implements (which is 2)
                if(theNumberItemsToFetch > 2)
                {
                    theNumberItemsToFetch = 2;
                }

                // Write the streams' object IDs into the return value
                if(theNumberItemsToFetch > 1)
                {
                    ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
                    ((AudioObjectID*)outData)[1] = kObjectID_Stream_Output;
                }
                else if(theNumberItemsToFetch > 0)
                {
                    ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
                }

                // Return how many bytes we wrote to
                *outDataSize = theNumberItemsToFetch * sizeof(AudioClassID);
            }
            break;

        case kAudioObjectPropertyControlList:
            // This property returns an array of control IDs that are owned by the device.
            // For this driver, there are no controls, so we return an empty array.
            *outDataSize = 0;
            break;

        case kAudioDevicePropertyNominalSampleRate:
            // This property returns the nominal sample rate of the device.
            FailWithAction(inDataSize < sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyNominalSampleRate for the device");
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((Float64*)outData) = gDevice_SampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyAvailableSampleRates:
            // This property returns the sample rates that the device supports.
            FailWithAction(inDataSize < kDevice_SampleRatesSize * sizeof(AudioValueRange), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyAvailableSampleRates for the device");

            for(UInt32 i = 0; i < kDevice_SampleRatesSize; i++)
            {
                ((AudioValueRange*)outData)[i].mMinimum = kDevice_SampleRates[i];
                ((AudioValueRange*)outData)[i].mMaximum = kDevice_SampleRates[i];
            }
            *outDataSize = kDevice_SampleRatesSize * sizeof(AudioValueRange);
            break;

        case kAudioDevicePropertyIsHidden:
            // This property returns whether or not the device is hidden.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyIsHidden for the device");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            // This property returns the zero time stamp period of the device.
            FailWithAction(inDataSize < sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyZeroTimeStampPeriod for the device");
            *((Float64*)outData) = 1.0 / gDevice_SampleRate;
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyIcon:
            // This property returns the icon of the device.
            FailWithAction(inDataSize < sizeof(CFURLRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyIcon for the device");
            *((CFURLRef*)outData) = NULL;
            *outDataSize = sizeof(CFURLRef);
            break;



        case kAudioDevicePropertyConfigurationApplication:
            // This property returns the configuration application for the device.
            FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyConfigurationApplication for the device");
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetDevicePropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetDevicePropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetDevicePropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetDevicePropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetDevicePropertyData: not the device object");

    // initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetDevicePropertyData() method.
    switch(inAddress->mSelector)
    {
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - Stream Property Operations
// ============================================================================

static Boolean Vocana_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    Boolean theAnswer = false;

    // check the arguments
    FailIf(inDriver != gVocanaAudioServerPlugInDriverRef, Done, "Vocana_HasStreamProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "Vocana_HasStreamProperty: no address");
    FailIf((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), Done, "Vocana_HasStreamProperty: not a stream object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetStreamPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsStreamPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsStreamPropertySettable: no address");
    FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_IsStreamPropertySettable: no place to put the return value");
    FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_IsStreamPropertySettable: not a stream object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetStreamPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outIsSettable = false;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetStreamPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetStreamPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetStreamPropertyDataSize: no place to put the return value");
    FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetStreamPropertyDataSize: not a stream object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetStreamPropertyData() method.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            break;

        case kAudioStreamPropertyIsActive:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioStreamPropertyDirection:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioStreamPropertyTerminalType:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioStreamPropertyStartingChannel:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioStreamPropertyVirtualFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;

        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;

        case kAudioStreamPropertyAvailableVirtualFormats:
            *outDataSize = kDevice_SampleRatesSize * sizeof(AudioStreamRangedDescription);
            break;

        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = kDevice_SampleRatesSize * sizeof(AudioStreamRangedDescription);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetStreamPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetStreamPropertyData: no address");
    FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetStreamPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_GetStreamPropertyData: no place to put the return value");
    FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_GetStreamPropertyData: not a stream object");

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required.
    //
    // Also, since most of the data that will get returned is static, there are few instances where
    // it is necessary to lock the state mutex.
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            // The base class for kAudioStreamClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the stream");
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            // The class is always kAudioStreamClassID for regular drivers
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the stream");
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            // The owner is the device object
            FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the stream");
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyOwnedObjects:
            // Streams don't own anything
            *outDataSize = 0;
            break;

        case kAudioStreamPropertyIsActive:
            // This property returns whether or not the stream is active.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyIsActive for the stream");
            if(inObjectID == kObjectID_Stream_Input)
            {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *((UInt32*)outData) = gStream_Input_IsActive ? 1 : 0;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
            }
            else
            {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *((UInt32*)outData) = gStream_Output_IsActive ? 1 : 0;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
            }
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyDirection:
            // This property returns the direction of the stream.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyDirection for the stream");
            *((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyTerminalType:
            // This property returns the terminal type of the stream.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyTerminalType for the stream");
            *((UInt32*)outData) = kAudioStreamTerminalTypeLine;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyStartingChannel:
            // This property returns the starting channel of the stream.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyStartingChannel for the stream");
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyLatency:
            // This property returns the latency of the stream.
            FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyLatency for the stream");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            // This property returns the format of the stream.
            FailWithAction(inDataSize < sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyVirtualFormat for the stream");

            ((AudioStreamBasicDescription*)outData)->mSampleRate = gDevice_SampleRate;
            ((AudioStreamBasicDescription*)outData)->mFormatID = kAudioFormatLinearPCM;
            ((AudioStreamBasicDescription*)outData)->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            ((AudioStreamBasicDescription*)outData)->mBytesPerPacket = kBytes_Per_Frame;
            ((AudioStreamBasicDescription*)outData)->mFramesPerPacket = 1;
            ((AudioStreamBasicDescription*)outData)->mBytesPerFrame = kBytes_Per_Frame;
            ((AudioStreamBasicDescription*)outData)->mChannelsPerFrame = kNumber_Of_Channels;
            ((AudioStreamBasicDescription*)outData)->mBitsPerChannel = kBits_Per_Channel;
            ((AudioStreamBasicDescription*)outData)->mReserved = 0;

            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            // This property returns the available formats of the stream.
            FailWithAction(inDataSize < kDevice_SampleRatesSize * sizeof(AudioStreamRangedDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Vocana_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyAvailableVirtualFormats for the stream");

            for(UInt32 i = 0; i < kDevice_SampleRatesSize; i++)
            {
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mSampleRate = kDevice_SampleRates[i];
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFormatID = kAudioFormatLinearPCM;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBytesPerPacket = kBytes_Per_Frame;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mFramesPerPacket = 1;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBytesPerFrame = kBytes_Per_Frame;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mChannelsPerFrame = kNumber_Of_Channels;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mBitsPerChannel = kBits_Per_Channel;
                ((AudioStreamRangedDescription*)outData)[i].mFormat.mReserved = 0;

                ((AudioStreamRangedDescription*)outData)[i].mSampleRateRange.mMinimum = kDevice_SampleRates[i];
                ((AudioStreamRangedDescription*)outData)[i].mSampleRateRange.mMaximum = kDevice_SampleRates[i];
            }
            *outDataSize = kDevice_SampleRatesSize * sizeof(AudioStreamRangedDescription);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

static OSStatus Vocana_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    // declare the local variables
    OSStatus theAnswer = 0;

    // check the arguments
    FailWithAction(inDriver != gVocanaAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetStreamPropertyData: bad driver reference");
    FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetStreamPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetStreamPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "Vocana_SetStreamPropertyData: no place to return the properties that changed");
    FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "Vocana_SetStreamPropertyData: not a stream object");

    // initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    // Note that for each object, this driver implements all the required properties plus a few
    // extras that are useful but not required. There is more detailed commentary about each
    // property in the Vocana_GetStreamPropertyData() method.
    switch(inAddress->mSelector)
    {
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

// ============================================================================
// MARK: - Interface Initialization
// ============================================================================

__attribute__((constructor))
static void VocanaAudioServerPlugin_InitializeInterface(void) {
    gVocanaAudioServerPlugInDriverInterface = (AudioServerPlugInDriverInterface){
        NULL,
        Vocana_QueryInterface,
        Vocana_AddRef,
        Vocana_Release,
        Vocana_Initialize,
        Vocana_CreateDevice,
        Vocana_DestroyDevice,
        Vocana_AddDeviceClient,
        Vocana_RemoveDeviceClient,
        Vocana_PerformDeviceConfigurationChange,
        Vocana_AbortDeviceConfigurationChange,
        Vocana_HasProperty,
        Vocana_IsPropertySettable,
        Vocana_GetPropertyDataSize,
        Vocana_GetPropertyData,
        Vocana_SetPropertyData,
        Vocana_StartIO,
        Vocana_StopIO,
        Vocana_GetZeroTimeStamp,
        Vocana_WillDoIOOperation,
        Vocana_BeginIOOperation,
        Vocana_DoIOOperation,
        Vocana_EndIOOperation
    };
}

// Dummy main function for executable target
int main(int argc, char* argv[]) {
    // CFPlugins don't use main() - they use factory functions
    // This is just to satisfy the executable target requirement
    return 0;
}