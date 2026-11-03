#include "NitroEC.hpp"
#include "NitroECShared.h"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>

#define LOG(fmt, ...) IOLog("NitroEC: " fmt "\n", ##__VA_ARGS__)

OSDefineMetaClassAndStructors(NitroEC, IOService)
OSDefineMetaClassAndStructors(NitroECUserClient, IOUserClient)

// MARK: - Write policy (ANV15-52 branch): EC read-only, exact firmware WMI calls only
//
// No byte of the EC is written from here: the SSDT of this branch has no WE1B, writeByte refuses and isWriteAllowed is
// false. The mode and fan bytes of the AN515-57 whitelist do not apply on this board (ERAM at 0xFE708500).
//
// The firmware calls allowed are the ones below, with these exact buffers and nothing else. All of them go to the
// firmware SMI (SSDT10, WMBE and WMBH); the IDs and types are in the MOF of this firmware (WQAB in SSDT10), the layouts
// come from Linux's acer-wmi (fan behaviour, misc settings) and Linuwu-Sense (battery health, keyboard backlight) on
// other Acer models. What the SMM handler does with them cannot be read from ACPI: every reply carries a status byte,
// which the clients check, and each write has a GET to read it back with.

// Battery-health WMI (\_SB.PC00.WMID.WMBE), all forwarded to BIOS SMM.
// Layout from Linuwu-Sense: get [battery 1, query 1], set [battery 1, mask, status].
enum : uint32_t {
    kWMBEGetHealth = 0x14,
    kWMBESetHealth = 0x15,
    kHealthMaskLimit = 0x01,  // 80 % charge limit. Calibration (0x02) is deliberately not allowed.
};

// Gaming WMI (\_SB.PC00.WMID.WMBH), forwarded to BIOS SMM.
enum : uint32_t {
    kWMBHSetFanBehavior = 0x0E,  // SetGamingFanBehavior, uint64: bits 15:0 fan bitmap, 17:16 CPU mode, 23:22 GPU mode
    kWMBHGetFanBehavior = 0x0F,  // GetGamingFanBehavior, uint32 fan bitmap
    kWMBHSetFanSpeed    = 0x10,  // SetGamingFanSpeed, uint64: byte 0 fan (1 CPU, 4 GPU), byte 1 percent
    kWMBHGetKBBacklight = 0x15,  // GetGamingKBBacklight, uint32 1. Read only: SetGamingKBBacklight (0x14) is not allowed.
    kWMBHSetMisc        = 0x16,  // SetGamingMiscSetting, uint64: byte 0 index, byte 1 value; the firmware then runs HIDB
    kWMBHGetMisc        = 0x17,  // GetGamingMiscSetting, uint32 index

    kFanCPU = 0x01, kFanGPU = 0x08, kFanBoth = kFanCPU | kFanGPU,
    // Third byte of the uint64: both fans in Auto (mode 1, 0x410009), Max (mode 2, firmware "turbo", 0x820009) or Custom (mode 3,
    // 0xC30009). A manual duty under kFanSpeedMin is refused, so that no call can park a fan.
    kFanAutoByte = 0x41, kFanMaxByte = 0x82, kFanCustomByte = 0xC3,
    kFanSpeedCPU = 1, kFanSpeedGPU = 4, kFanSpeedMin = 30,

    kMiscSupportedProfiles = 0x0A,  // read only
    kMiscPlatformProfile   = 0x0B,
    // The values CCOL takes in _Q30 of this DSDT: 0 quiet, 1 balanced, 4 performance. Turbo (5) and eco (6) stay out.
    kProfileQuiet = 0x00, kProfileBalanced = 0x01, kProfilePerformance = 0x04,
};

static bool isZeroFrom(const uint8_t *in, uint32_t start) {
    for (uint32_t i = start; i < kNitroECWMBHInSize; i++)
        if (in[i])
            return false;
    return true;
}

bool NitroEC::isWriteAllowed(uint32_t, uint32_t) { return false; }

bool NitroEC::isWMBHAllowed(uint32_t opcode, const uint8_t *in) {
    switch (opcode) {
    case kWMBHSetFanBehavior:
        return in[0] == kFanBoth && in[1] == 0 && (in[2] == kFanAutoByte || in[2] == kFanMaxByte || in[2] == kFanCustomByte) && isZeroFrom(in, 3);
    case kWMBHSetFanSpeed:
        return (in[0] == kFanSpeedCPU || in[0] == kFanSpeedGPU) && in[1] >= kFanSpeedMin && in[1] <= 100 && isZeroFrom(in, 2);
    case kWMBHGetFanBehavior:
        return (in[0] == kFanCPU || in[0] == kFanGPU) && isZeroFrom(in, 1);
    case kWMBHGetKBBacklight:
        return in[0] == 1 && isZeroFrom(in, 1);
    case kWMBHSetMisc:
        return in[0] == kMiscPlatformProfile &&
               (in[1] == kProfileQuiet || in[1] == kProfileBalanced || in[1] == kProfilePerformance) && isZeroFrom(in, 2);
    case kWMBHGetMisc:
        return (in[0] == kMiscPlatformProfile || in[0] == kMiscSupportedProfiles) && isZeroFrom(in, 1);
    default:
        return false;
    }
}

bool NitroEC::isWMBEAllowed(uint32_t method, const uint8_t *in) {
    switch (method) {
    case kWMBEGetHealth:
        return in[0] == 1 && in[1] == kHealthMaskLimit && isZeroFrom(in, 2);
    case kWMBESetHealth:
        return in[0] == 1 && in[1] == kHealthMaskLimit && in[2] <= 1 && isZeroFrom(in, 3);
    default:
        return false;
    }
}

// Apge WMI (\_SB.PC00.WMID.WMAA), forwarded to BIOS SMM. Method 1 sets, 2 reads. Layouts from Linuwu-Sense, whose USB charging and
// backlight timeout calls these are; the replies say whether this firmware has them.
bool NitroEC::isWMAAAllowed(uint32_t method, const uint8_t *in) {
    switch (method) {
    case 2:
        return (in[0] == 0x04 && isZeroFrom(in, 1)) || (in[0] == 0x01 && in[1] == 0x84 && in[2] == 0x08 && isZeroFrom(in, 3));
    case 1:
        if (in[0] == 0x04 && isZeroFrom(in, 3))   // USB charging: off, or on down to 10, 20 or 30 % of battery
            return (in[1] == 0x1F && in[2] == 0x0A) || (in[1] == 0x0F && (in[2] == 0x0A || in[2] == 0x14 || in[2] == 0x1E));
        return in[0] == 0x02 && in[1] == 0x84 && in[2] == 0x08 && in[3] == 0 && in[4] == 0 && (in[5] == 0 || in[5] == 0x1E) && isZeroFrom(in, 6);
    default:
        return false;
    }
}

// MARK: - NitroEC

bool NitroEC::start(IOService *provider) {
    if (!IOService::start(provider))
        return false;

    acpi = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!acpi) {
        LOG("provider is not an ACPI device");
        return false;
    }

    UInt32 version = 0;
    if (acpi->evaluateInteger("VERS", &version) != kIOReturnSuccess || version != kNitroECACPIVersion) {
        LOG("SSDT-NITRO missing or wrong version (got %u, want %u)", version, kNitroECACPIVersion);
        return false;
    }

    lock = IOLockAlloc();
    if (!lock)
        return false;

    acpi->retain();

    // The SSDTs of the older branches report the same VERS but lack these methods (anv15-52 has none, anv15-52-battery has
    // only WMEX): what is missing is refused, not evaluated.
    hasWMEX = acpi->validateObject("WMEX") == kIOReturnSuccess;
    hasWMBX = acpi->validateObject("WMBX") == kIOReturnSuccess;
    hasRMOD = acpi->validateObject("RMOD") == kIOReturnSuccess;
    hasSMOD = acpi->validateObject("SMOD") == kIOReturnSuccess;
    hasWMAX = acpi->validateObject("WMAX") == kIOReturnSuccess;

    uint8_t cpuTemp = 0;
    if (readByte(0x58, &cpuTemp) == kIOReturnSuccess)   // CTMP on the ANV15-52
        LOG("started, SSDT v%u, CPU temp %u C, battery WMI %s, gaming WMI %s", version, cpuTemp,
            hasWMEX ? "available" : "absent (no WMEX)", hasWMBX ? "available" : "absent (no WMBX)");

    setProperty("NitroEC SSDT Version", version, 32);
    setProperty("NitroEC Battery WMI", hasWMEX);
    setProperty("NitroEC Gaming WMI", hasWMBX);
    setProperty("NitroEC Mode State", hasRMOD);
    setProperty("NitroEC Power Mode", hasSMOD);
    setProperty("NitroEC Apge WMI", hasWMAX);
    registerService();
    return true;
}

void NitroEC::stop(IOService *provider) {
    // The EC is never written. The one thing to put back: if a call through this kext took the fans away from Auto and
    // no later call brought them back, never leave them that way without a driver behind them. Otherwise the firmware
    // is not touched here.
    if (fanLeftOffAuto && hasWMBX) {
        uint8_t in[kNitroECWMBHInSize] = {kFanBoth, 0, kFanAutoByte};
        uint8_t out[kNitroECWMBHOutSize] = {};
        uint32_t outLength = sizeof(out);
        LOG("stop: fans back to Auto");
        callWMI("WMBX", kWMBHSetFanBehavior, in, out, &outLength);
    }
    OSSafeReleaseNULL(acpi);
    IOService::stop(provider);
}

void NitroEC::free() {
    if (lock) {
        IOLockFree(lock);
        lock = nullptr;
    }
    IOService::free();
}

IOReturn NitroEC::readByte(uint32_t offset, uint8_t *value) {
    if (offset >= kNitroECDumpSize || !value)
        return kIOReturnBadArgument;

    OSNumber *arg = OSNumber::withNumber(offset, 32);
    if (!arg)
        return kIOReturnNoMemory;

    OSObject *params[] = {arg};
    UInt32 result = 0;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateInteger("RE1B", &result, params, 1);
    IOLockUnlock(lock);
    arg->release();

    if (ret != kIOReturnSuccess)
        return ret;
    if (result > 0xFF)
        return kIOReturnError;

    *value = static_cast<uint8_t>(result);
    return kIOReturnSuccess;
}

IOReturn NitroEC::readBuffer(const char *method, uint8_t *buffer, uint32_t size) {
    OSObject *result = nullptr;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateObject(method, &result);
    IOLockUnlock(lock);
    if (ret != kIOReturnSuccess)
        return ret;

    OSData *data = OSDynamicCast(OSData, result);
    if (!data || data->getLength() < size) {
        OSSafeReleaseNULL(result);
        return kIOReturnUnderrun;
    }

    memcpy(buffer, data->getBytesNoCopy(), size);
    result->release();
    return kIOReturnSuccess;
}

IOReturn NitroEC::dump(uint8_t *buffer, uint32_t length) {
    if (!buffer || length < kNitroECDumpSize)
        return kIOReturnBadArgument;
    return readBuffer("RDMP", buffer, kNitroECDumpSize);
}

IOReturn NitroEC::modeState(uint8_t *buffer, uint32_t length) {
    if (!buffer || length < kNitroECModeStateSize)
        return kIOReturnBadArgument;
    if (!hasRMOD)
        return kIOReturnUnsupported;
    return readBuffer("RMOD", buffer, kNitroECModeStateSize);
}

// Performance, Balance and Quiet only, as _Q30 numbers them; Turbo (0) and Eco (4) stay out.
IOReturn NitroEC::setMode(uint32_t index) {
    if (index < 1 || index > 3) {
        LOG("refused power mode %u (not whitelisted)", index);
        return kIOReturnNotPermitted;
    }
    if (!hasSMOD)
        return kIOReturnUnsupported;

    OSNumber *arg = OSNumber::withNumber(index, 32);
    if (!arg)
        return kIOReturnNoMemory;

    OSObject *params[] = {arg};
    UInt32 result = 1;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateInteger("SMOD", &result, params, 1);
    IOLockUnlock(lock);
    arg->release();

    LOG("power mode %u: SMOD -> 0x%x, result %u", index, ret, result);
    if (ret != kIOReturnSuccess)
        return ret;
    return result == 0 ? kIOReturnSuccess : kIOReturnError;
}

IOReturn NitroEC::writeByte(uint32_t offset, uint32_t value) {
    LOG("refused write 0x%02X = 0x%02X (read-only on the ANV15-52)", offset, value);
    return kIOReturnNotPermitted;
}

IOReturn NitroEC::callWMBH(uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!isWMBHAllowed(opcode, in)) {
        LOG("refused WMBH 0x%02X [%02X %02X %02X] (not whitelisted)", opcode, in[0], in[1], in[2]);
        return kIOReturnNotPermitted;
    }
    if (!hasWMBX) {
        LOG("refused WMBH 0x%02X: the loaded SSDT-NITRO has no WMBX", opcode);
        return kIOReturnUnsupported;
    }
    IOReturn ret = callWMI("WMBX", opcode, in, out, outLength);
    if (opcode == kWMBHSetFanBehavior) {
        bool answered = ret == kIOReturnSuccess && *outLength > 0;
        bool accepted = answered && out[0] == 0;
        // Max accepted, or no answer at all, so that the state is unknown: stop() will ask for Auto. A refusal changed nothing.
        if ((in[2] == kFanMaxByte || in[2] == kFanCustomByte) && (accepted || !answered))
            fanLeftOffAuto = true;
        if (in[2] == kFanAutoByte && accepted)
            fanLeftOffAuto = false;
    }
    return ret;
}

IOReturn NitroEC::callWMAA(uint32_t method, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!isWMAAAllowed(method, in)) {
        LOG("refused WMAA 0x%02X [%02X %02X %02X] (not whitelisted)", method, in[0], in[1], in[2]);
        return kIOReturnNotPermitted;
    }
    if (!hasWMAX) {
        LOG("refused WMAA 0x%02X: the loaded SSDT-NITRO has no WMAX", method);
        return kIOReturnUnsupported;
    }
    return callWMI("WMAX", method, in, out, outLength);
}

IOReturn NitroEC::callWMBE(uint32_t method, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!isWMBEAllowed(method, in)) {
        LOG("refused WMBE 0x%02X [%02X %02X %02X] (not whitelisted)", method, in[0], in[1], in[2]);
        return kIOReturnNotPermitted;
    }
    if (!hasWMEX) {
        LOG("refused WMBE 0x%02X: the loaded SSDT-NITRO has no WMEX", method);
        return kIOReturnUnsupported;
    }
    return callWMI("WMEX", method, in, out, outLength);
}

IOReturn NitroEC::callWMI(const char *wrapper, uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!acpi)
        return kIOReturnNotReady;

    OSNumber *argOpcode = OSNumber::withNumber(opcode, 32);
    OSData *argBuffer = OSData::withBytes(in, kNitroECWMBHInSize);
    if (!argOpcode || !argBuffer) {
        OSSafeReleaseNULL(argOpcode);
        OSSafeReleaseNULL(argBuffer);
        return kIOReturnNoMemory;
    }

    OSObject *params[] = {argOpcode, argBuffer};
    OSObject *result = nullptr;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateObject(wrapper, &result, params, 2);
    IOLockUnlock(lock);
    argOpcode->release();
    argBuffer->release();
    if (ret != kIOReturnSuccess)
        return ret;

    OSData *data = OSDynamicCast(OSData, result);
    if (!data) {
        OSSafeReleaseNULL(result);
        return kIOReturnError;
    }
    uint32_t length = min(data->getLength(), *outLength);
    memcpy(out, data->getBytesNoCopy(), length);
    *outLength = length;
    result->release();

    LOG("%s 0x%02X [%02X %02X %02X %02X %02X %02X] -> %02X", wrapper, opcode, in[0], in[1], in[2], in[3], in[4], in[5],
        length ? out[0] : 0xFF);
    return kIOReturnSuccess;
}

// MARK: - NitroECUserClient

const IOExternalMethodDispatch NitroECUserClient::methods[kNitroECSelCount] = {
    // function, scalarIn, structIn, scalarOut, structOut
    [kNitroECSelReadByte]  = {&NitroECUserClient::sReadByte, 1, 0, 1, 0},
    [kNitroECSelDump]      = {&NitroECUserClient::sDump, 0, 0, 0, kNitroECDumpSize},
    [kNitroECSelWriteByte] = {&NitroECUserClient::sWriteByte, 2, 0, 1, 0},
    [kNitroECSelWMBH]      = {&NitroECUserClient::sWMBH, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
    [kNitroECSelWMBE]      = {&NitroECUserClient::sWMBE, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
    [kNitroECSelModeState] = {&NitroECUserClient::sModeState, 0, 0, 0, kNitroECModeStateSize},
    [kNitroECSelSetMode]   = {&NitroECUserClient::sSetMode, 1, 0, 0, 0},
    [kNitroECSelWMAA]      = {&NitroECUserClient::sWMAA, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
};

bool NitroECUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (!IOUserClient::initWithTask(owningTask, securityID, type))
        return false;
    isAdmin = clientHasPrivilege(owningTask, kIOClientPrivilegeAdministrator) == kIOReturnSuccess;
    return true;
}

bool NitroECUserClient::start(IOService *provider) {
    owner = OSDynamicCast(NitroEC, provider);
    if (!owner)
        return false;
    return IOUserClient::start(provider);
}

IOReturn NitroECUserClient::clientClose() {
    terminate();
    return kIOReturnSuccess;
}

IOReturn NitroECUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                           IOExternalMethodDispatch *, OSObject *, void *) {
    if (selector >= kNitroECSelCount)
        return kIOReturnUnsupported;
    return IOUserClient::externalMethod(selector, args,
                                        const_cast<IOExternalMethodDispatch *>(&methods[selector]),
                                        this, nullptr);
}

IOReturn NitroECUserClient::sReadByte(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    uint8_t value = 0;
    IOReturn ret = self->owner->readByte(static_cast<uint32_t>(args->scalarInput[0]), &value);
    if (ret == kIOReturnSuccess)
        args->scalarOutput[0] = value;
    return ret;
}

IOReturn NitroECUserClient::sDump(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (args->structureOutputSize < kNitroECDumpSize)
        return kIOReturnBadArgument;
    return self->owner->dump(static_cast<uint8_t *>(args->structureOutput), kNitroECDumpSize);
}

IOReturn NitroECUserClient::sModeState(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (args->structureOutputSize < kNitroECModeStateSize)
        return kIOReturnBadArgument;
    return self->owner->modeState(static_cast<uint8_t *>(args->structureOutput), kNitroECModeStateSize);
}

IOReturn NitroECUserClient::sSetMode(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (!self->isAdmin)
        return kIOReturnNotPrivileged;
    if (args->scalarInput[0] > 0xFF)
        return kIOReturnBadArgument;
    return self->owner->setMode(static_cast<uint32_t>(args->scalarInput[0]));
}

IOReturn NitroECUserClient::sWriteByte(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (!self->isAdmin)
        return kIOReturnNotPrivileged;

    uint32_t offset = static_cast<uint32_t>(args->scalarInput[0]);
    uint32_t value = static_cast<uint32_t>(args->scalarInput[1]);
    if (args->scalarInput[0] > 0xFF || args->scalarInput[1] > 0xFF)
        return kIOReturnBadArgument;

    IOReturn ret = self->owner->writeByte(offset, value);
    if (ret != kIOReturnSuccess)
        return ret;

    uint8_t readBack = 0;
    ret = self->owner->readByte(offset, &readBack);
    if (ret == kIOReturnSuccess)
        args->scalarOutput[0] = readBack;
    return ret;
}

IOReturn NitroECUserClient::sWMBH(OSObject *target, void *, IOExternalMethodArguments *args) {
    return sWMI(target, args, 0);
}

IOReturn NitroECUserClient::sWMBE(OSObject *target, void *, IOExternalMethodArguments *args) {
    return sWMI(target, args, 1);
}

IOReturn NitroECUserClient::sWMAA(OSObject *target, void *, IOExternalMethodArguments *args) {
    return sWMI(target, args, 2);
}

IOReturn NitroECUserClient::sWMI(OSObject *target, IOExternalMethodArguments *args, int bank) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (!self->isAdmin)
        return kIOReturnNotPrivileged;
    if (args->scalarInput[0] > 0xFF || args->structureOutputSize == 0)
        return kIOReturnBadArgument;

    uint32_t opcode = static_cast<uint32_t>(args->scalarInput[0]);
    auto in = static_cast<const uint8_t *>(args->structureInput);
    auto out = static_cast<uint8_t *>(args->structureOutput);
    uint32_t outLength = min(args->structureOutputSize, (uint32_t)kNitroECWMBHOutSize);
    IOReturn ret = bank == 2 ? self->owner->callWMAA(opcode, in, out, &outLength)
                 : bank == 1 ? self->owner->callWMBE(opcode, in, out, &outLength)
                             : self->owner->callWMBH(opcode, in, out, &outLength);
    if (ret == kIOReturnSuccess)
        args->structureOutputSize = outLength;
    return ret;
}
