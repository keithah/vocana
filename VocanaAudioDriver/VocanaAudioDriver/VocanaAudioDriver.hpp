//
//  VocanaAudioDriver.hpp
//  VocanaAudioDriver
//
//  Created by Vocana Team.
//  Copyright © 2025 Vocana. All rights reserved.
//

#ifndef VocanaAudioDriver_hpp
#define VocanaAudioDriver_hpp

#include <os/log.h>
#include <DriverKit/IOUserService.h>
#include <AudioDriverKit/AudioDriverKit.h>

class VocanaAudioDriver : public IOUserService
{
    OSDeclareDefaultStructors(VocanaAudioDriver);
    
public:
    // IOService overrides
    virtual bool init(OSDictionary* properties) override;
    virtual void free() override;
    virtual bool start(IOService* provider) override;
    virtual void stop(IOService* provider) override;
    
    // IOUserService overrides
    virtual kern_return_t Start(IOService* provider) override;
    virtual kern_return_t Stop() override;
    
private:
    // Audio device management
    kern_return_t CreateVirtualDevices();
    kern_return_t DestroyVirtualDevices();
    
    // Audio processing
    kern_return_t ProcessAudioInput(const void* inputData, size_t inputSize, void* outputData, size_t* outputSize);
    kern_return_t ProcessAudioOutput(const void* inputData, size_t inputSize, void* outputData, size_t* outputSize);
    
    // Logging
    os_log_t mLogHandle;
};

#endif /* VocanaAudioDriver_hpp */