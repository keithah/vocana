//
//  VocanaAudioServerPlugin.h
//  VocanaAudioServerPlugin
//
//  Core Audio HAL Plugin for Virtual Audio Devices
//

#ifndef VocanaAudioServerPlugin_h
#define VocanaAudioServerPlugin_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// MARK: - Object IDs
// ============================================================================

enum {
    kObjectID_PlugIn                    = kAudioObjectPlugInObject,
    kObjectID_Box                       = 2,
    kObjectID_Device                    = 3,
    kObjectID_Stream_Input              = 4,
    kObjectID_Stream_Output             = 5,
    kObjectID_Volume_Input_Master       = 6,
    kObjectID_Mute_Input_Master         = 7,
    kObjectID_Volume_Output_Master      = 8,
    kObjectID_Mute_Output_Master        = 9,
    kObjectID_Pitch_Adjust              = 10,
    kObjectID_ClockSource               = 11,
    kObjectID_Device2                   = 12,
};

// ============================================================================
// MARK: - Audio Format Constants
// ============================================================================

#define kDriver_Name                     "Vocana"
#define kPlugIn_BundleID                 "com.vocana.VocanaAudioServerPlugin"
#define kBox_UID                         kDriver_Name "_UID"
#define kDevice_UID                      kDriver_Name "_UID"
#define kDevice_ModelUID                 kDriver_Name "_ModelUID"
#define kDevice_Name                     kDriver_Name
#define kManufacturer_Name               "Vocana Inc."

#define kNumber_Of_Channels              2
#define kDevice_HasInput                 true
#define kDevice_HasOutput                true
#define kCanBeDefaultDevice              true
#define kCanBeDefaultSystemDevice        true

#define kSampleRates                     44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0

#define kBits_Per_Channel                32
#define kBytes_Per_Channel               (kBits_Per_Channel / 8)
#define kBytes_Per_Frame                 (kNumber_Of_Channels * kBytes_Per_Channel)

// ============================================================================
// MARK: - Plugin Interface
// ============================================================================

// Factory function
void* VocanaAudioServerPlugin_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

#ifdef __cplusplus
}
#endif

#endif /* VocanaAudioServerPlugin_h */