/*
 * SSDT-NITRO — EC access for NitroEC.kext on Acer Nitro V 15 ANV15-52 (macOS only). Branch anv15-52-battery:
 * EC reads only, plus the firmware battery-health WMI for the charge limit.
 *
 * The firmware of this board maps its EC RAM 1:1 at SystemMemory 0xFE708500 (DSDT: OperationRegion ERAM under
 * \_SB.PC00.LPCB.EC0, 0x100 bytes, 140 named fields) and reads every EC field through it; the AN515-57 of the
 * upstream project has the same window at 0xFE0B0800 with a different field map. We use the same window with the
 * same Lock semantics, so no raw 0x62/0x66 port I/O happens.
 *
 * EC: only RE1B (one byte) and RDMP (the whole window). No EC write method (WE1B of upstream v2) and no gaming WMI
 * wrapper (WMBX -> WMBH of v3) is exported, because the fan and mode bytes of this board are not identified yet
 * (EC dump: temperatures, fan speeds, AC, lid, power limits, keyboard backlight; see the README).
 *
 * WMEX -> \_SB.PC00.WMID.WMBE (upstream v4) is back for one feature: the 80 % battery charge limit that Acer's
 * NitroSense sets on Windows through the battery-health WMI (GUID 79772EC5-04B1-4BFD-843C-61E7F77B6CC9; method
 * 0x14 reads the status, 0x15 sets it). SSDT10 of this board has the same WMBE as the AN515-57: both ids hand the
 * buffer to the firmware SMI (WSMI) and 0x15 also notifies \_SB.BAT1. Which method ids and buffers may pass is
 * decided by NitroEC.kext (whitelist); WMEX itself answers only Darwin. The NitroSense key mapping of the AN515-57
 * is not included: its scancode is unverified here.
 */
DefinitionBlock ("", "SSDT", 2, "NITRO", "NITROEC", 0x00001000)
{
    External (_SB_.PC00.WMID.WMBE, MethodObj)    // 3 Arguments

    Scope (\_SB)
    {
        Device (NTRO)
        {
            Name (_HID, "NTRO0001")  // _HID: Hardware ID
            Name (_UID, Zero)  // _UID: Unique ID

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0F)
                }

                Return (Zero)
            }

            // Interface version, checked by the kext (a subset of the v4 methods; the kext checks for WMEX itself)
            Method (VERS, 0, NotSerialized)
            {
                Return (0x04)
            }

            // EC RAM window 0x00..0xFF, the firmware's ERAM of the ANV15-52
            OperationRegion (ERDM, SystemMemory, 0xFE708500, 0x0100)
            Field (ERDM, ByteAcc, Lock, Preserve)
            {
                BUF0,   2048
            }

            // Read one EC byte: RE1B (offset) -> 0x00..0xFF, Ones on bad offset
            Method (RE1B, 1, Serialized)
            {
                If ((Arg0 > 0xFF))
                {
                    Return (Ones)
                }

                Local0 = BUF0 /* \_SB_.NTRO.BUF0 */
                Return (DerefOf (Local0 [Arg0]))
            }

            // Battery health WMI the way NitroSense does it:
            // WMEX (method, Buffer) -> WMBE (0, method, Buffer). Whitelisted by the kext; Darwin only.
            Method (WMEX, 2, Serialized)
            {
                If (_OSI ("Darwin"))
                {
                    If (CondRefOf (\_SB.PC00.WMID.WMBE))
                    {
                        Return (\_SB.PC00.WMID.WMBE (Zero, Arg0, Arg1))
                    }
                }

                Return (Buffer (0x04)
                {
                     0xFF, 0xFF, 0xFF, 0xFF
                })
            }

            // Read EC bytes 0x00..0xFF -> Buffer (0x100)
            Method (RDMP, 0, Serialized)
            {
                Return (BUF0) /* \_SB_.NTRO.BUF0 */
            }
        }
    }
}
