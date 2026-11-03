#ifndef NitroEC_hpp
#define NitroEC_hpp

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLocks.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

// Matches \_SB.NTRO (_HID "NTRO0001") from SSDT-NITRO and exposes EC RAM reads. Branch anv15-52-control: EC reads only,
// plus an exact whitelist of firmware WMI calls: the charge limit (WMBE 0x14 / 0x15), the fan behaviour and the power
// mode (WMBH 0x0E / 0x0F, 0x16 / 0x17), the keyboard backlight status (WMBH 0x15).
class NitroEC : public IOService {
    OSDeclareDefaultStructors(NitroEC)

    IOACPIPlatformDevice *acpi {nullptr};
    IOLock *lock {nullptr};
    bool hasWMEX {false};   // the loaded SSDT-NITRO exports WMEX (the read-only SSDT of branch anv15-52 does not)
    bool hasWMBX {false};   // ... WMBX (the SSDT of branch anv15-52-battery does not either)
    bool hasRMOD {false};   // ... RMOD (same)
    bool hasSMOD {false};   // ... SMOD (same)
    bool hasWMAX {false};   // ... WMAX (same)
    bool hasRPCU {false};   // ... RPCU (same)
    bool fanLeftOffAuto {false};  // a call through this kext took the fans off Auto and none brought them back yet

public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    IOReturn readByte(uint32_t offset, uint8_t *value);
    IOReturn dump(uint8_t *buffer, uint32_t length);
    IOReturn modeState(uint8_t *buffer, uint32_t length);
    IOReturn pcu(uint8_t *buffer, uint32_t length);
    IOReturn setMode(uint32_t index);
    IOReturn writeByte(uint32_t offset, uint32_t value);
    IOReturn callWMBH(uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength);
    IOReturn callWMBE(uint32_t method, const uint8_t *in, uint8_t *out, uint32_t *outLength);
    IOReturn callWMAA(uint32_t method, const uint8_t *in, uint8_t *out, uint32_t *outLength);

    static bool isWriteAllowed(uint32_t offset, uint32_t value);
    static bool isWMBHAllowed(uint32_t opcode, const uint8_t *in);
    static bool isWMBEAllowed(uint32_t method, const uint8_t *in);
    static bool isWMAAAllowed(uint32_t method, const uint8_t *in);

private:
    IOReturn readBuffer(const char *method, uint8_t *buffer, uint32_t size);
    IOReturn callWMI(const char *wrapper, uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength);
};

class NitroECUserClient : public IOUserClient {
    OSDeclareDefaultStructors(NitroECUserClient)

    NitroEC *owner {nullptr};
    bool isAdmin {false};

    static const IOExternalMethodDispatch methods[];
    static IOReturn sReadByte(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sDump(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sModeState(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sPCU(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sSetMode(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWriteByte(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMBH(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMBE(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMAA(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMI(OSObject *target, IOExternalMethodArguments *args, int bank);

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target,
                            void *reference) override;
};

#endif
