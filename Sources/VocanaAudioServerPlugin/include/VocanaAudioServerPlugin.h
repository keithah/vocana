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

// Plugin Interface
extern AudioServerPlugInDriverInterface gVocanaAudioServerPlugInDriverInterface;

// Device IDs
typedef enum {
    kVocanaDeviceID_Input = 1,
    kVocanaDeviceID_Output = 2
} VocanaDeviceID;

// Audio Format Constants
#define kVocanaSampleRate 48000.0
#define kVocanaChannels 2
#define kVocanaBitsPerChannel 16
#define kVocanaFramesPerSlice 512

#ifdef __cplusplus
}
#endif

#endif /* VocanaAudioServerPlugin_h */