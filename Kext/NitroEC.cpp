#include "NitroEC.hpp"
#include "NitroECShared.h"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>

#define LOG(fmt, ...) IOLog("NitroEC: " fmt "\n", ##__VA_ARGS__)

OSDefineMetaClassAndStructors(NitroEC, IOService)
OSDefineMetaClassAndStructors(NitroECUserClient, IOUserClient)

// MARK: - Write policy: none (ANV15-52 branch, read-only)
//
// The EC map of the Acer Nitro V 15 ANV15-52 (ERAM at 0xFE708500) is known only for temperatures, fan speeds, AC, lid,
// power limits and the keyboard backlight (an EC dump decoded against the DSDT field names); the fan,
// mode, LED and charge bytes of the AN515-57 whitelist do not apply here and their counterparts are not identified.
// Until they are, every write and every firmware WMI call is refused, and the SSDT of this branch exports no write
// method either.

bool NitroEC::isWriteAllowed(uint32_t, uint32_t) { return false; }
bool NitroEC::isWMBHAllowed(uint32_t, const uint8_t *) { return false; }
bool NitroEC::isWMBEAllowed(uint32_t, const uint8_t *) { return false; }

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

    uint8_t cpuTemp = 0;
    if (readByte(0x58, &cpuTemp) == kIOReturnSuccess)   // CTMP on the ANV15-52
        LOG("started, SSDT v%u, CPU temp %u C", version, cpuTemp);

    setProperty("NitroEC SSDT Version", version, 32);
    registerService();
    return true;
}

void NitroEC::stop(IOService *provider) {
    // Nothing to put back: this branch never writes to the EC.
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

IOReturn NitroEC::dump(uint8_t *buffer, uint32_t length) {
    if (!buffer || length < kNitroECDumpSize)
        return kIOReturnBadArgument;

    OSObject *result = nullptr;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateObject("RDMP", &result);
    IOLockUnlock(lock);
    if (ret != kIOReturnSuccess)
        return ret;

    OSData *data = OSDynamicCast(OSData, result);
    if (!data || data->getLength() < kNitroECDumpSize) {
        OSSafeReleaseNULL(result);
        return kIOReturnUnderrun;
    }

    memcpy(buffer, data->getBytesNoCopy(), kNitroECDumpSize);
    result->release();
    return kIOReturnSuccess;
}

IOReturn NitroEC::writeByte(uint32_t offset, uint32_t value) {
    LOG("refused write 0x%02X = 0x%02X (read-only on the ANV15-52)", offset, value);
    return kIOReturnNotPermitted;
}

IOReturn NitroEC::callWMBH(uint32_t opcode, const uint8_t *in, uint8_t *, uint32_t *) {
    LOG("refused WMBH 0x%02X [%02X %02X] (read-only on the ANV15-52)", opcode, in[0], in[1]);
    return kIOReturnNotPermitted;
}

IOReturn NitroEC::callWMBE(uint32_t method, const uint8_t *in, uint8_t *, uint32_t *) {
    LOG("refused WMBE 0x%02X [%02X %02X %02X] (read-only on the ANV15-52)", method, in[0], in[1], in[2]);
    return kIOReturnNotPermitted;
}

// MARK: - NitroECUserClient

const IOExternalMethodDispatch NitroECUserClient::methods[kNitroECSelCount] = {
    // function, scalarIn, structIn, scalarOut, structOut
    [kNitroECSelReadByte]  = {&NitroECUserClient::sReadByte, 1, 0, 1, 0},
    [kNitroECSelDump]      = {&NitroECUserClient::sDump, 0, 0, 0, kNitroECDumpSize},
    [kNitroECSelWriteByte] = {&NitroECUserClient::sWriteByte, 2, 0, 1, 0},
    [kNitroECSelWMBH]      = {&NitroECUserClient::sWMBH, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
    [kNitroECSelWMBE]      = {&NitroECUserClient::sWMBE, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
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
    return sWMI(target, args, false);
}

IOReturn NitroECUserClient::sWMBE(OSObject *target, void *, IOExternalMethodArguments *args) {
    return sWMI(target, args, true);
}

IOReturn NitroECUserClient::sWMI(OSObject *target, IOExternalMethodArguments *args, bool battery) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (!self->isAdmin)
        return kIOReturnNotPrivileged;
    if (args->scalarInput[0] > 0xFF || args->structureOutputSize == 0)
        return kIOReturnBadArgument;

    uint32_t opcode = static_cast<uint32_t>(args->scalarInput[0]);
    auto in = static_cast<const uint8_t *>(args->structureInput);
    auto out = static_cast<uint8_t *>(args->structureOutput);
    uint32_t outLength = min(args->structureOutputSize, (uint32_t)kNitroECWMBHOutSize);
    IOReturn ret = battery ? self->owner->callWMBE(opcode, in, out, &outLength)
                           : self->owner->callWMBH(opcode, in, out, &outLength);
    if (ret == kIOReturnSuccess)
        args->structureOutputSize = outLength;
    return ret;
}
