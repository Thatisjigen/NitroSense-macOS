/*
 * SSDT-NITRO — EC access for NitroEC.kext on Acer Nitro V 15 ANV15-52 (macOS only). Branch anv15-52, read-only.
 *
 * The firmware of this board maps its EC RAM 1:1 at SystemMemory 0xFE708500 (DSDT: OperationRegion ERAM under
 * \_SB.PC00.LPCB.EC0, 0x100 bytes, 140 named fields) and reads every EC field through it; the AN515-57 of the
 * upstream project has the same window at 0xFE0B0800 with a different field map. We use the same window with the
 * same Lock semantics, so no raw 0x62/0x66 port I/O happens.
 *
 * Read-only: only RE1B (one byte) and RDMP (the whole window). No write method and no firmware WMI call is
 * exported, so nothing user space asks can reach the EC until the fan and mode bytes of this board are identified
 * (the EC dump only identifies temperatures, fan speeds, AC, lid, power limits and the keyboard
 * backlight; see the README). The NitroSense key mapping of the AN515-57 is not included: its scancode is unverified here.
 */
DefinitionBlock ("", "SSDT", 2, "NITRO", "NITROEC", 0x00001000)
{
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

            // Interface version, checked by the kext (the read methods are those of v4)
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

            // Read EC bytes 0x00..0xFF -> Buffer (0x100)
            Method (RDMP, 0, Serialized)
            {
                Return (BUF0) /* \_SB_.NTRO.BUF0 */
            }
        }
    }
}
