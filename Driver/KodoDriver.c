// Kodo's output device: an entry in the Mac's Sound output list for your Kodo group.
//
// Apps that play to it are heard through Kodo, which captures every app's audio with a
// process tap and plays it through the group's speakers in sync. The device itself plays
// nothing: it keeps time for the apps and carries the volume and mute that the volume keys
// and Control Center change, which Kodo passes on to the group.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>

#define kBundleID "com.felipetrejos.kodo.driver"
#define kDeviceUID "KodoDevice"
#define kModelUID "KodoModel"

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
    kObjectID_Volume = 4,
    kObjectID_Mute = 5,
};

static const UInt32 kChannelCount = 2;
static const Float64 kSampleRates[] = { 44100, 48000, 88200, 96000 };
static const UInt32 kSampleRateCount = sizeof(kSampleRates) / sizeof(kSampleRates[0]);
// How often a zero time stamp falls, in frames. Any period works for a device that plays
// nothing; this matches the HAL's usual ring buffer size.
static const UInt32 kZeroTimeStampPeriod = 16384;
static const Float32 kMinimumDecibels = -64;
static const Float32 kMaximumDecibels = 0;

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;

// Guarded by gStateMutex.
static Float64 gSampleRate = 48000;
static Float32 gVolume = 1;
static bool gMuted = false;
static UInt32 gIOCount = 0;

// Guarded by gIOMutex; read on the IO thread.
static pthread_mutex_t gIOMutex = PTHREAD_MUTEX_INITIALIZER;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStampCount = 0;

#pragma mark - Helpers

static Float64 HostTicksPerFrame(Float64 sampleRate) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    return ticksPerSecond / sampleRate;
}

static bool IsSupportedSampleRate(Float64 rate) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) {
        if (kSampleRates[i] == rate) {
            return true;
        }
    }
    return false;
}

static AudioStreamBasicDescription Format(Float64 sampleRate) {
    AudioStreamBasicDescription format = { 0 };
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 4 * kChannelCount;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4 * kChannelCount;
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel = 32;
    return format;
}

// The volume slider maps evenly onto decibels.
static Float32 ScalarToDecibels(Float32 scalar) {
    scalar = fminf(fmaxf(scalar, 0), 1);
    return kMinimumDecibels + scalar * (kMaximumDecibels - kMinimumDecibels);
}

static Float32 DecibelsToScalar(Float32 decibels) {
    decibels = fminf(fmaxf(decibels, kMinimumDecibels), kMaximumDecibels);
    return (decibels - kMinimumDecibels) / (kMaximumDecibels - kMinimumDecibels);
}

static void SaveLevels(Float32 volume, bool muted) {
    if (gHost == NULL) {
        return;
    }
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat32Type, &volume);
    gHost->WriteToStorage(gHost, CFSTR("volume"), number);
    CFRelease(number);
    gHost->WriteToStorage(gHost, CFSTR("muted"), muted ? kCFBooleanTrue : kCFBooleanFalse);
}

static void LoadLevels(void) {
    CFPropertyListRef volume = NULL;
    if (gHost->CopyFromStorage(gHost, CFSTR("volume"), &volume) == 0 && volume != NULL) {
        if (CFGetTypeID(volume) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)volume, kCFNumberFloat32Type, &gVolume);
            gVolume = fminf(fmaxf(gVolume, 0), 1);
        }
        CFRelease(volume);
    }
    CFPropertyListRef muted = NULL;
    if (gHost->CopyFromStorage(gHost, CFSTR("muted"), &muted) == 0 && muted != NULL) {
        if (CFGetTypeID(muted) == CFBooleanGetTypeID()) {
            gMuted = CFBooleanGetValue((CFBooleanRef)muted);
        }
        CFRelease(muted);
    }
}

#pragma mark - Plug-in lifetime

static HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface);
static ULONG AddRef(void* driver);
static ULONG Release(void* driver);
static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo);
static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, UInt32* outDataSize, void* outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, const void* data);
static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

// Named in Info.plist's CFPlugInFactories.
void* KodoDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    return gDriver;
}

static HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface) {
    if (driver != gDriver || outInterface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    bool known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) {
        return E_NOINTERFACE;
    }
    pthread_mutex_lock(&gStateMutex);
    gRefCount++;
    pthread_mutex_unlock(&gStateMutex);
    *outInterface = gDriver;
    return S_OK;
}

static ULONG AddRef(void* driver) {
    if (driver != gDriver) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void* driver) {
    if (driver != gDriver) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) {
        gRefCount--;
    }
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriver) {
        return kAudioHardwareBadObjectError;
    }
    gHost = host;
    LoadLevels();
    gHostTicksPerFrame = HostTicksPerFrame(gSampleRate);
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID) {
    (void)driver; (void)description; (void)clientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
    (void)driver; (void)deviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo) {
    (void)clientInfo;
    return driver == gDriver && deviceObjectID == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo) {
    (void)clientInfo;
    return driver == gDriver && deviceObjectID == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

// A sample rate change asked for in SetPropertyData lands here, once the HAL has stopped IO.
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo) {
    (void)changeInfo;
    if (driver != gDriver || deviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    Float64 rate = (Float64)changeAction;
    if (!IsSupportedSampleRate(rate)) {
        return kAudioHardwareIllegalOperationError;
    }
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = rate;
    pthread_mutex_unlock(&gStateMutex);
    pthread_mutex_lock(&gIOMutex);
    gHostTicksPerFrame = HostTicksPerFrame(rate);
    pthread_mutex_unlock(&gIOMutex);
    return 0;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo) {
    (void)changeAction; (void)changeInfo;
    return driver == gDriver && deviceObjectID == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

#pragma mark - Properties

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address) {
    (void)clientPID;
    if (driver != gDriver || address == NULL) {
        return false;
    }
    switch (objectID) {
        case kObjectID_PlugIn:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
            }
            return false;

        case kObjectID_Device:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
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
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyIcon:
                    return true;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredChannelLayout:
                    return address->mScope == kAudioObjectPropertyScopeOutput;
            }
            return false;

        case kObjectID_Stream:
            switch (address->mSelector) {
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
                    return true;
            }
            return false;

        case kObjectID_Volume:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    return true;
            }
            return false;

        case kObjectID_Mute:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioBooleanControlPropertyValue:
                    return true;
            }
            return false;
    }
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable) {
    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(driver, objectID, clientPID, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    switch (objectID) {
        case kObjectID_Device:
            *outIsSettable = address->mSelector == kAudioDevicePropertyNominalSampleRate;
            break;
        case kObjectID_Stream:
            *outIsSettable = address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat;
            break;
        case kObjectID_Volume:
            *outIsSettable = address->mSelector == kAudioLevelControlPropertyScalarValue || address->mSelector == kAudioLevelControlPropertyDecibelValue;
            break;
        case kObjectID_Mute:
            *outIsSettable = address->mSelector == kAudioBooleanControlPropertyValue;
            break;
        default:
            *outIsSettable = false;
    }
    return 0;
}

// The objects the device owns in a scope: the stream and controls are all on the output side.
static UInt32 DeviceOwnedObjects(AudioObjectPropertyScope scope, AudioObjectID* outObjects, UInt32 capacity) {
    if (scope == kAudioObjectPropertyScopeInput) {
        return 0;
    }
    const AudioObjectID owned[] = { kObjectID_Stream, kObjectID_Volume, kObjectID_Mute };
    UInt32 count = 0;
    for (UInt32 i = 0; i < 3 && count < capacity; i++) {
        if (outObjects != NULL) {
            outObjects[count] = owned[i];
        }
        count++;
    }
    return count;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize) {
    (void)qualifierDataSize; (void)qualifierData;
    if (outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(driver, objectID, clientPID, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioDevicePropertyIcon:
            *outDataSize = sizeof(CFURLRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
            switch (objectID) {
                case kObjectID_PlugIn:
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;
                case kObjectID_Device:
                    *outDataSize = DeviceOwnedObjects(address->mScope, NULL, 3) * sizeof(AudioObjectID);
                    return 0;
                default:
                    *outDataSize = 0;
                    return 0;
            }
        case kAudioPlugInPropertyDeviceList:
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioDevicePropertyStreams:
            *outDataSize = address->mScope == kAudioObjectPropertyScopeInput ? 0 : sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList:
            *outDataSize = 2 * sizeof(AudioObjectID);
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = kSampleRateCount * sizeof(AudioValueRange);
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = kSampleRateCount * sizeof(AudioStreamRangedDescription);
            return 0;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *outDataSize = sizeof(Float32);
            return 0;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        default:
            // The rest are all UInt32s.
            *outDataSize = sizeof(UInt32);
            return 0;
    }
}

#define REQUIRE_SIZE(type) \
    do { \
        if (dataSize < sizeof(type)) { \
            return kAudioHardwareBadPropertySizeError; \
        } \
        *outDataSize = sizeof(type); \
    } while (0)

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, UInt32* outDataSize, void* outData) {
    if (outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(driver, objectID, clientPID, address)) {
        return kAudioHardwareUnknownPropertyError;
    }

    pthread_mutex_lock(&gStateMutex);
    Float64 sampleRate = gSampleRate;
    Float32 volume = gVolume;
    bool muted = gMuted;
    UInt32 ioCount = gIOCount;
    pthread_mutex_unlock(&gStateMutex);

    switch (objectID) {
        case kObjectID_PlugIn:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = kAudioPlugInClassID;
                    return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE_SIZE(AudioObjectID);
                    *(AudioObjectID*)outData = kAudioObjectUnknown;
                    return 0;
                case kAudioObjectPropertyManufacturer:
                    REQUIRE_SIZE(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("Kodo");
                    return 0;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (dataSize < sizeof(AudioObjectID)) {
                        *outDataSize = 0;
                        return 0;
                    }
                    *(AudioObjectID*)outData = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    REQUIRE_SIZE(AudioObjectID);
                    if (qualifierDataSize != sizeof(CFStringRef) || qualifierData == NULL) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    CFStringRef uid = *(const CFStringRef*)qualifierData;
                    *(AudioObjectID*)outData = uid != NULL && CFEqual(uid, CFSTR(kDeviceUID)) ? kObjectID_Device : kAudioObjectUnknown;
                    return 0;
                }
                case kAudioPlugInPropertyResourceBundle:
                    REQUIRE_SIZE(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("");
                    return 0;
            }
            break;

        case kObjectID_Device:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = kAudioDeviceClassID;
                    return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE_SIZE(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectID_PlugIn;
                    return 0;
                case kAudioObjectPropertyName:
                    REQUIRE_SIZE(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("Kodo");
                    return 0;
                case kAudioObjectPropertyManufacturer:
                    REQUIRE_SIZE(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("Kodo");
                    return 0;
                case kAudioDevicePropertyDeviceUID:
                    REQUIRE_SIZE(CFStringRef);
                    *(CFStringRef*)outData = CFSTR(kDeviceUID);
                    return 0;
                case kAudioDevicePropertyModelUID:
                    REQUIRE_SIZE(CFStringRef);
                    *(CFStringRef*)outData = CFSTR(kModelUID);
                    return 0;
                case kAudioObjectPropertyOwnedObjects: {
                    UInt32 count = DeviceOwnedObjects(address->mScope, (AudioObjectID*)outData, dataSize / sizeof(AudioObjectID));
                    *outDataSize = count * sizeof(AudioObjectID);
                    return 0;
                }
                case kAudioDevicePropertyTransportType:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
                    return 0;
                case kAudioDevicePropertyRelatedDevices:
                    if (dataSize < sizeof(AudioObjectID)) {
                        *outDataSize = 0;
                        return 0;
                    }
                    *(AudioObjectID*)outData = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyIsHidden:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = 0;
                    return 0;
                case kAudioDevicePropertyDeviceIsAlive:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = 1;
                    return 0;
                case kAudioDevicePropertyDeviceIsRunning:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = ioCount > 0 ? 1 : 0;
                    return 0;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    REQUIRE_SIZE(UInt32);
                    // It's only an output; it can't stand in for a microphone.
                    *(UInt32*)outData = address->mScope == kAudioObjectPropertyScopeInput ? 0 : 1;
                    return 0;
                case kAudioDevicePropertyStreams:
                    if (address->mScope == kAudioObjectPropertyScopeInput || dataSize < sizeof(AudioObjectID)) {
                        *outDataSize = 0;
                        return 0;
                    }
                    *(AudioObjectID*)outData = kObjectID_Stream;
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;
                case kAudioObjectPropertyControlList: {
                    AudioObjectID* controls = (AudioObjectID*)outData;
                    UInt32 count = 0;
                    if (dataSize >= sizeof(AudioObjectID)) {
                        controls[count++] = kObjectID_Volume;
                    }
                    if (dataSize >= 2 * sizeof(AudioObjectID)) {
                        controls[count++] = kObjectID_Mute;
                    }
                    *outDataSize = count * sizeof(AudioObjectID);
                    return 0;
                }
                case kAudioDevicePropertyNominalSampleRate:
                    REQUIRE_SIZE(Float64);
                    *(Float64*)outData = sampleRate;
                    return 0;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    UInt32 count = (UInt32)(dataSize / sizeof(AudioValueRange));
                    if (count > kSampleRateCount) {
                        count = kSampleRateCount;
                    }
                    AudioValueRange* ranges = (AudioValueRange*)outData;
                    for (UInt32 i = 0; i < count; i++) {
                        ranges[i].mMinimum = kSampleRates[i];
                        ranges[i].mMaximum = kSampleRates[i];
                    }
                    *outDataSize = count * sizeof(AudioValueRange);
                    return 0;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = kZeroTimeStampPeriod;
                    return 0;
                case kAudioDevicePropertyIcon: {
                    REQUIRE_SIZE(CFURLRef);
                    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(kBundleID));
                    CFURLRef icon = bundle != NULL ? CFBundleCopyResourceURL(bundle, CFSTR("Kodo"), CFSTR("icns"), NULL) : NULL;
                    if (icon == NULL) {
                        return kAudioHardwareUnspecifiedError;
                    }
                    *(CFURLRef*)outData = icon;
                    return 0;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    if (dataSize < 2 * sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    UInt32* channels = (UInt32*)outData;
                    channels[0] = 1;
                    channels[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    return 0;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);
                    if (dataSize < size) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                    memset(layout, 0, size);
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    layout->mNumberChannelDescriptions = kChannelCount;
                    layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    *outDataSize = size;
                    return 0;
                }
            }
            break;

        case kObjectID_Stream:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = kAudioStreamClassID;
                    return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE_SIZE(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectID_Device;
                    return 0;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return 0;
                case kAudioStreamPropertyIsActive:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = 1;
                    return 0;
                case kAudioStreamPropertyDirection:
                    REQUIRE_SIZE(UInt32);
                    // 0 is output.
                    *(UInt32*)outData = 0;
                    return 0;
                case kAudioStreamPropertyTerminalType:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = kAudioStreamTerminalTypeSpeaker;
                    return 0;
                case kAudioStreamPropertyStartingChannel:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = 1;
                    return 0;
                case kAudioStreamPropertyLatency:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = 0;
                    return 0;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    REQUIRE_SIZE(AudioStreamBasicDescription);
                    *(AudioStreamBasicDescription*)outData = Format(sampleRate);
                    return 0;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    UInt32 count = (UInt32)(dataSize / sizeof(AudioStreamRangedDescription));
                    if (count > kSampleRateCount) {
                        count = kSampleRateCount;
                    }
                    AudioStreamRangedDescription* formats = (AudioStreamRangedDescription*)outData;
                    for (UInt32 i = 0; i < count; i++) {
                        formats[i].mFormat = Format(kSampleRates[i]);
                        formats[i].mSampleRateRange.mMinimum = kSampleRates[i];
                        formats[i].mSampleRateRange.mMaximum = kSampleRates[i];
                    }
                    *outDataSize = count * sizeof(AudioStreamRangedDescription);
                    return 0;
                }
            }
            break;

        case kObjectID_Volume:
        case kObjectID_Mute:
            switch (address->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = objectID == kObjectID_Volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID;
                    return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE_SIZE(AudioClassID);
                    *(AudioClassID*)outData = objectID == kObjectID_Volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID;
                    return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE_SIZE(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectID_Device;
                    return 0;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return 0;
                case kAudioControlPropertyScope:
                    REQUIRE_SIZE(AudioObjectPropertyScope);
                    *(AudioObjectPropertyScope*)outData = kAudioObjectPropertyScopeOutput;
                    return 0;
                case kAudioControlPropertyElement:
                    REQUIRE_SIZE(AudioObjectPropertyElement);
                    *(AudioObjectPropertyElement*)outData = kAudioObjectPropertyElementMain;
                    return 0;
                case kAudioLevelControlPropertyScalarValue:
                    REQUIRE_SIZE(Float32);
                    *(Float32*)outData = volume;
                    return 0;
                case kAudioLevelControlPropertyDecibelValue:
                    REQUIRE_SIZE(Float32);
                    *(Float32*)outData = ScalarToDecibels(volume);
                    return 0;
                case kAudioLevelControlPropertyDecibelRange: {
                    REQUIRE_SIZE(AudioValueRange);
                    AudioValueRange* range = (AudioValueRange*)outData;
                    range->mMinimum = kMinimumDecibels;
                    range->mMaximum = kMaximumDecibels;
                    return 0;
                }
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                    REQUIRE_SIZE(Float32);
                    *(Float32*)outData = ScalarToDecibels(*(Float32*)outData);
                    return 0;
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    REQUIRE_SIZE(Float32);
                    *(Float32*)outData = DecibelsToScalar(*(Float32*)outData);
                    return 0;
                case kAudioBooleanControlPropertyValue:
                    REQUIRE_SIZE(UInt32);
                    *(UInt32*)outData = muted ? 1 : 0;
                    return 0;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static void NotifyLevelChanged(AudioObjectID control) {
    if (control == kObjectID_Volume) {
        AudioObjectPropertyAddress changed[] = {
            { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        gHost->PropertiesChanged(gHost, kObjectID_Volume, 2, changed);
    } else {
        AudioObjectPropertyAddress changed[] = {
            { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        gHost->PropertiesChanged(gHost, kObjectID_Mute, 1, changed);
    }
}

static OSStatus RequestSampleRate(Float64 rate) {
    if (!IsSupportedSampleRate(rate)) {
        return kAudioHardwareIllegalOperationError;
    }
    pthread_mutex_lock(&gStateMutex);
    bool unchanged = rate == gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    if (unchanged) {
        return 0;
    }
    // The HAL stops IO, then calls PerformDeviceConfigurationChange with the rate.
    return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, const void* data) {
    (void)qualifierDataSize; (void)qualifierData;
    if (data == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    Boolean settable = false;
    OSStatus status = IsPropertySettable(driver, objectID, clientPID, address, &settable);
    if (status != 0) {
        return status;
    }
    if (!settable) {
        return kAudioHardwareUnsupportedOperationError;
    }

    switch (address->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            if (dataSize != sizeof(Float64)) {
                return kAudioHardwareBadPropertySizeError;
            }
            return RequestSampleRate(*(const Float64*)data);

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (dataSize != sizeof(AudioStreamBasicDescription)) {
                return kAudioHardwareBadPropertySizeError;
            }
            const AudioStreamBasicDescription* format = (const AudioStreamBasicDescription*)data;
            AudioStreamBasicDescription supported = Format(format->mSampleRate);
            if (format->mFormatID != supported.mFormatID || format->mChannelsPerFrame != supported.mChannelsPerFrame || format->mBitsPerChannel != supported.mBitsPerChannel) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return RequestSampleRate(format->mSampleRate);
        }

        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue: {
            if (dataSize != sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            Float32 value = *(const Float32*)data;
            Float32 scalar = address->mSelector == kAudioLevelControlPropertyScalarValue ? fminf(fmaxf(value, 0), 1) : DecibelsToScalar(value);
            pthread_mutex_lock(&gStateMutex);
            bool changed = scalar != gVolume;
            gVolume = scalar;
            bool muted = gMuted;
            pthread_mutex_unlock(&gStateMutex);
            if (changed) {
                SaveLevels(scalar, muted);
                NotifyLevelChanged(kObjectID_Volume);
            }
            return 0;
        }

        case kAudioBooleanControlPropertyValue: {
            if (dataSize != sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            bool muted = *(const UInt32*)data != 0;
            pthread_mutex_lock(&gStateMutex);
            bool changed = muted != gMuted;
            gMuted = muted;
            Float32 volume = gVolume;
            pthread_mutex_unlock(&gStateMutex);
            if (changed) {
                SaveLevels(volume, muted);
                NotifyLevelChanged(kObjectID_Mute);
            }
            return 0;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    (void)clientID;
    if (driver != gDriver || deviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gStateMutex);
    bool first = gIOCount == 0;
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    if (first) {
        pthread_mutex_lock(&gIOMutex);
        gAnchorHostTime = mach_absolute_time();
        gTimeStampCount = 0;
        pthread_mutex_unlock(&gIOMutex);
    }
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    (void)clientID;
    if (driver != gDriver || deviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) {
        gIOCount--;
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

// The device keeps time with the host clock: a zero time stamp every period's worth of frames.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)clientID;
    if (driver != gDriver || deviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gIOMutex);
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroTimeStampPeriod;
    UInt64 now = mach_absolute_time();
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * ticksPerPeriod);
    if (next <= now) {
        gTimeStampCount++;
    }
    *outSampleTime = (Float64)(gTimeStampCount * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gIOMutex);
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)clientID;
    if (driver != gDriver || deviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    // Takes the mix so apps keep playing; Kodo hears them through its tap.
    *outWillDo = operationID == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo;
    return driver == gDriver && deviceObjectID == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)streamObjectID; (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo; (void)ioMainBuffer; (void)ioSecondaryBuffer;
    return driver == gDriver && deviceObjectID == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo;
    return driver == gDriver && deviceObjectID == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}
