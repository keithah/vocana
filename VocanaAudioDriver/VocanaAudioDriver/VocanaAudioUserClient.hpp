//
//  VocanaAudioUserClient.hpp
//  VocanaAudioDriver
//
//  Created by Vocana Team.
//  Copyright © 2025 Vocana. All rights reserved.
//

#ifndef VocanaAudioUserClient_hpp
#define VocanaAudioUserClient_hpp

#include <os/log.h>
#include <DriverKit/IOUserClient.h>

class VocanaAudioDriver;

class VocanaAudioUserClient : public IOUserClient
{
    OSDeclareDefaultStructors(VocanaAudioUserClient);
    
public:
    // IOUserClient overrides
    virtual bool initWithTask(task_t owningTask, void* securityToken, UInt32 type, OSDictionary* properties) override;
    virtual IOReturn clientClose() override;
    virtual IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments* arguments,
                                   IOExternalMethodDispatch* dispatch, OSObject* target, void* reference) override;
    
private:
    VocanaAudioDriver* mDriver;
    os_log_t mLogHandle;
};

#endif /* VocanaAudioUserClient_hpp */