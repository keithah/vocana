//
//  VocanaAudioDriver.cpp
//  VocanaAudioDriver
//
//  Created by Keith on 11/10/25.
//

#include <os/log.h>

#include <DriverKit/IOUserServer.h>
#include <DriverKit/IOLib.h>

#include "VocanaAudioDriver.h"

kern_return_t
IMPL(VocanaAudioDriver, Start)
{
    kern_return_t ret;
    ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "Hello World");
    return ret;
}
