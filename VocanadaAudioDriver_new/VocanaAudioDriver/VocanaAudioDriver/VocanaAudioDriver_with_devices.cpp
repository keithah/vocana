#include <DriverKit/IOLib.h>
#include <AudioDriverKit/AudioDriverKit.h>
#include "VocanaAudioDriver.h"

struct VocanaAudioDriver_IVars {
    IOUserAudioDevice * virtualInputDevice;
    IOUserAudioDevice * virtualOutputDevice;
    IOUserAudioStream * inputStream;
    IOUserAudioStream * outputStream;
};

kern_return_t
VocanaAudioDriver::Start_Impl(IOService * provider)
{
    kern_return_t ret;
    
    IOLog("VocanaAudioDriver: Starting audio driver\n");
    
    // Initialize member variables
    ivars->virtualInputDevice = nullptr;
    ivars->virtualOutputDevice = nullptr;
    ivars->inputStream = nullptr;
    ivars->outputStream = nullptr;
    
    // Create virtual input device
    ret = CreateIOUserAudioDevice(&ivars->virtualInputDevice);
    if (ret != kIOReturnSuccess) {
        IOLog("VocanaAudioDriver: Failed to create virtual input device: 0x%x\n", ret);
        return ret;
    }
    IOLog("VocanaAudioDriver: Virtual input device created\n");
    
    // Create virtual output device  
    ret = CreateIOUserAudioDevice(&ivars->virtualOutputDevice);
    if (ret != kIOReturnSuccess) {
        IOLog("VocanaAudioDriver: Failed to create virtual output device: 0x%x\n", ret);
        if (ivars->virtualInputDevice) {
            ivars->virtualInputDevice->release();
            ivars->virtualInputDevice = nullptr;
        }
        return ret;
    }
    IOLog("VocanaAudioDriver: Virtual output device created\n");
    
    // Create input stream
    ret = CreateIOUserAudioStream(&ivars->inputStream);
    if (ret != kIOReturnSuccess) {
        IOLog("VocanaAudioDriver: Failed to create input stream: 0x%x\n", ret);
        goto cleanup;
    }
    IOLog("VocanaAudioDriver: Input stream created\n");
    
    // Create output stream
    ret = CreateIOUserAudioStream(&ivars->outputStream);
    if (ret != kIOReturnSuccess) {
        IOLog("VocanaAudioDriver: Failed to create output stream: 0x%x\n", ret);
        goto cleanup;
    }
    IOLog("VocanaAudioDriver: Output stream created\n");
    
    IOLog("VocanaAudioDriver: Audio driver started successfully\n");
    return kIOReturnSuccess;
    
cleanup:
    if (ivars->inputStream) {
        ivars->inputStream->release();
        ivars->inputStream = nullptr;
    }
    if (ivars->virtualInputDevice) {
        ivars->virtualInputDevice->release();
        ivars->virtualInputDevice = nullptr;
    }
    if (ivars->virtualOutputDevice) {
        ivars->virtualOutputDevice->release();
        ivars->virtualOutputDevice = nullptr;
    }
    return ret;
}

kern_return_t
VocanaAudioDriver::Stop_Impl(IOService * provider)
{
    IOLog("VocanaAudioDriver: Stopping audio driver\n");
    
    // Cleanup audio streams
    if (ivars->inputStream) {
        ivars->inputStream->release();
        ivars->inputStream = nullptr;
    }
    
    if (ivars->outputStream) {
        ivars->outputStream->release();
        ivars->outputStream = nullptr;
    }
    
    // Cleanup virtual audio devices
    if (ivars->virtualInputDevice) {
        ivars->virtualInputDevice->release();
        ivars->virtualInputDevice = nullptr;
    }
    
    if (ivars->virtualOutputDevice) {
        ivars->virtualOutputDevice->release();
        ivars->virtualOutputDevice = nullptr;
    }
    
    IOLog("VocanaAudioDriver: Audio driver stopped\n");
    return kIOReturnSuccess;
}