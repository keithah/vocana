#include <DriverKit/IOLib.h>
#include "VocanaAudioDriver.h"

bool
VocanaAudioDriver::init()
{
    IOLog("VocanaAudioDriver: Initialized\n");
    return true;
}

void
VocanaAudioDriver::free()
{
    IOLog("VocanaAudioDriver: Freed\n");
}

kern_return_t
VocanaAudioDriver::Start_Impl(IOService * provider)
{
    IOLog("VocanaAudioDriver: Started successfully\n");
    return kIOReturnSuccess;
}

kern_return_t
VocanaAudioDriver::Stop_Impl(IOService * provider)
{
    IOLog("VocanaAudioDriver: Stopped\n");
    return kIOReturnSuccess;
}