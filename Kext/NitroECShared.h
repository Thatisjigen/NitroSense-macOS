// Shared between NitroEC.kext and user-space clients (nitroctl, daemon).
#ifndef NitroECShared_h
#define NitroECShared_h

#define kNitroECServiceClass  "NitroEC"
#define kNitroECDumpSize      256
#define kNitroECACPIVersion   4
#define kNitroECWMBHInSize    16
#define kNitroECWMBHOutSize   16
#define kNitroECModeStateSize 44

enum NitroECSelector {
    kNitroECSelReadByte = 0,  // in: scalar[0] = offset       out: scalar[0] = value
    kNitroECSelDump     = 1,  // out: struct[256] = EC RAM 0x00..0xFF
    kNitroECSelWriteByte = 2, // in: scalar[0] = offset, scalar[1] = value   out: scalar[0] = read-back
                              // root only; offset/value must pass the kext whitelist
    kNitroECSelWMBH     = 3,  // in: scalar[0] = opcode, struct[16] = WMBH buffer
                              // out: struct[<=16] = WMBH result. root only, opcode whitelist
    kNitroECSelWMBE     = 4,  // same shape as WMBH, for the battery-health WMI (WMBE)
    kNitroECSelModeState = 5, // out: struct[44] = TUGM, CCOL, IDPF, 0, then the M1..M5 mode tables: firmware fields,
                              // read only, no SMI, no root (needs an SSDT-NITRO with RMOD)
    kNitroECSelCount
};

#endif
