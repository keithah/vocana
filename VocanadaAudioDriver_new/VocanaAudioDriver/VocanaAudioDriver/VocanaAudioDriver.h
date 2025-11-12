//
//  VocanaAudioDriver.h
//  VocanaAudioDriver
//
//  Created by Keith on 11/10/25.
//

#ifndef VocanaAudioDriver_h
#define VocanaAudioDriver_h

#include <DriverKit/IOService.h>
#include <AudioDriverKit/AudioDriverKit.h>

// IVars structure for member variable access
struct VocanaAudioDriver_IVars {
    IOUserAudioDevice * virtualInputDevice;
    IOUserAudioDevice * virtualOutputDevice;
    IOUserAudioStream * inputStream;
    IOUserAudioStream * outputStream;
};

#endif /* VocanaAudioDriver_h */