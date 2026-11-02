#ifndef NitroEC_hpp
#define NitroEC_hpp

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLocks.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

// Matches \_SB.NTRO (_HID "NTRO0001") from SSDT-NITRO and exposes EC RAM reads. Branch anv15-52: reads only.
class NitroEC : public IOService {
    OSDeclareDefaultStructors(NitroEC)

    IOACPIPlatformDevice *acpi {nullptr};
    IOLock *lock {nullptr};

public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    IOReturn readByte(uint32_t offset, uint8_t *value);
    IOReturn dump(uint8_t *buffer, uint32_t length);
    IOReturn writeByte(uint32_t offset, uint32_t value);
    IOReturn callWMBH(uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength);
    IOReturn callWMBE(uint32_t method, const uint8_t *in, uint8_t *out, uint32_t *outLength);

    static bool isWriteAllowed(uint32_t offset, uint32_t value);
    static bool isWMBHAllowed(uint32_t opcode, const uint8_t *in);
    static bool isWMBEAllowed(uint32_t method, const uint8_t *in);

};

class NitroECUserClient : public IOUserClient {
    OSDeclareDefaultStructors(NitroECUserClient)

    NitroEC *owner {nullptr};
    bool isAdmin {false};

    static const IOExternalMethodDispatch methods[];
    static IOReturn sReadByte(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sDump(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWriteByte(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMBH(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMBE(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWMI(OSObject *target, IOExternalMethodArguments *args, bool battery);

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target,
                            void *reference) override;
};

#endif
