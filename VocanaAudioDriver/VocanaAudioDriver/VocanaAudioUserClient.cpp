//
//  VocanaAudioUserClient.cpp
//  VocanaAudioDriver
//
//  Created by Vocana Team.
//  Copyright © 2025 Vocana. All rights reserved.
//

#include "VocanaAudioUserClient.hpp"
#include "VocanaAudioDriver.hpp"

#define Log(fmt, ...) os_log(mLogHandle, fmt, ##__VA_ARGS__)

OSDefineMetaClassAndStructors(VocanaAudioUserClient, IOUserClient);

bool VocanaAudioUserClient::initWithTask(task_t owningTask, void* securityToken, UInt32 type, OSDictionary* properties)
{
    if (!IOUserClient::initWithTask(owningTask, securityToken, type, properties)) {
        return false;
    }
    
    mLogHandle = os_log_create("com.vocana.audio.driver", "VocanaAudioUserClient");
    mDriver = nullptr;
    
    Log("VocanaAudioUserClient::initWithTask called");
    return true;
}

IOReturn VocanaAudioUserClient::clientClose()
{
    Log("VocanaAudioUserClient::clientClose called");
    
    if (mDriver) {
        mDriver->release();
        mDriver = nullptr;
    }
    
    return IOUserClient::clientClose();
}

IOReturn VocanaAudioUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments* arguments,
                                              IOExternalMethodDispatch* dispatch, OSObject* target, void* reference)
{
    Log("VocanaAudioUserClient::externalMethod called with selector: %u", selector);
    
    // TODO: Implement method dispatch for communication with main app
    // This would handle requests like:
    // - Enable/disable noise cancellation
    // - Get audio device status
    // - Configure processing parameters
    
    return kIOReturnUnsupported;
}