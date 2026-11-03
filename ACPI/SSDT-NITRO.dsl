/*
 * SSDT-NITRO — EC access for NitroEC.kext on Acer Nitro V 15 ANV15-52 (macOS only). Branch anv15-52-control:
 * EC reads only, the firmware battery-health WMI for the charge limit, and the firmware gaming WMI for the fan
 * behaviour and the power mode.
 *
 * The firmware of this board maps its EC RAM 1:1 at SystemMemory 0xFE708500 (DSDT: OperationRegion ERAM under
 * \_SB.PC00.LPCB.EC0, 0x100 bytes, 140 named fields) and reads every EC field through it; the AN515-57 of the
 * upstream project has the same window at 0xFE0B0800 with a different field map. We use the same window with the
 * same Lock semantics, so no raw 0x62/0x66 port I/O happens.
 *
 * EC: only RE1B (one byte) and RDMP (the whole window). There is still no EC write method (WE1B of upstream v2): no
 * byte of the EC is ever written from here.
 *
 * WMEX -> \_SB.PC00.WMID.WMBE (upstream v4): the 80 % battery charge limit that Acer's NitroSense sets on Windows
 * through the battery-health WMI (GUID 79772EC5-04B1-4BFD-843C-61E7F77B6CC9; method 0x14 reads the status, 0x15 sets
 * it). SSDT10 of this board has the same WMBE as the AN515-57: both ids hand the buffer to the firmware SMI (WSMI) and
 * 0x15 also notifies \_SB.BAT1.
 *
 * WMBX -> \_SB.PC00.WMID.WMBH (upstream v3): the gaming WMI (GUID 7A4DDFE7-5B5D-40B4-8595-4408E0CC7F56). The MOF of this
 * firmware (WQAB in SSDT10) declares SetGamingFanBehavior 14, GetGamingFanBehavior 15, GetGamingKBBacklight 21,
 * SetGamingMiscSetting 22 and GetGamingMiscSetting 23, and WMBH hands each of them to the firmware SMI; 22 then runs
 * \_SB.PC00.LPCB.EC0.HIDB, which passes the operating mode (CCOL) on to DPTF and NVPCF.
 *
 * WMEX and WMBX forward whatever they get and answer only Darwin: which method ids and buffers may pass is decided by
 * NitroEC.kext, which has an exact whitelist, and only root reaches it. The NitroSense key mapping of the AN515-57 is
 * not included: its scancode is unverified here.
 *
 * SMOD: the power mode through the firmware's own route (DSDT: _Q30 switches on TUGM), because this firmware answers status 1
 * to SetGamingMiscSetting and GetGamingMiscSetting 0x0B. The one write here to a byte the EC shares. The route is nghiant03's
 * for Linuwu-Sense on the same model (0xFE708607 + _Q30): https://github.com/0x7375646F/Linuwu-Sense/pull/147
 *
 * RMOD is a plain read of the firmware fields behind the power modes (the regions ERM4, ERM6 and EMBX of the DSDT, used
 * by its _Q30): no SMI, no write. It tells what each mode is set to do on this board without needing Windows.
 */
DefinitionBlock ("", "SSDT", 2, "NITRO", "NITROEC", 0x00001000)
{
    External (_SB_.PC00.WMID.WMBE, MethodObj)    // 3 Arguments
    External (_SB_.PC00.WMID.WMBH, MethodObj)    // 3 Arguments
    External (_SB_.PC00.LPCB.EC0._Q30, MethodObj)    // 0 Arguments

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

            // Interface version, checked by the kext (a subset of the v4 methods; the kext checks for WMEX, WMBX and RMOD itself)
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

            // Firmware fields behind the power modes, same addresses as the DSDT; only SMOD writes, TUGM and IDPF:
            // ERM4 + 0xA0: M1N1 M1M1 M1T1 M1P2 M1DB M1CT M1CP, one spare byte, then M2.., M3.., M4.., M5DB M5CT M5CP
            OperationRegion (ERT4, SystemMemory, 0xFE7084A0, 0x28)
            Field (ERT4, ByteAcc, Lock, Preserve)
            {
                BUF4,   320
            }

            // ERM6 + 0x07: TUGM, the mode index _Q30 switches on
            OperationRegion (ERT6, SystemMemory, 0xFE708607, One)
            Field (ERT6, ByteAcc, Lock, Preserve)
            {
                BTUG,   8
            }

            // EMBX + 0xD2: IDPF, selects M?M1 or M?N1 as PL1
            OperationRegion (ERTI, SystemMemory, 0xFE708AD2, One)
            Field (ERTI, ByteAcc, Lock, Preserve)
            {
                BIDP,   8
            }

            // EMBX + 0xF4: CCOL, the operating mode HIDB passes on
            OperationRegion (ERTC, SystemMemory, 0xFE708AF4, One)
            Field (ERTC, ByteAcc, Lock, Preserve)
            {
                BCOL,   8
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

            // Firmware mode fields: Buffer (0x2C) = TUGM, CCOL, IDPF, 0, then the 0x28 bytes of ERM4 + 0xA0
            Method (RMOD, 0, Serialized)
            {
                Name (RHDR, Buffer (0x04)
                {
                     0x00, 0x00, 0x00, 0x00
                })
                RHDR [Zero] = BTUG /* \_SB_.NTRO.BTUG */
                RHDR [One] = BCOL /* \_SB_.NTRO.BCOL */
                RHDR [0x02] = BIDP /* \_SB_.NTRO.BIDP */
                Return (Concatenate (RHDR, BUF4))
            }

            // Power mode: Arg0 is the index _Q30 switches on, 1 performance, 2 balance, 3 quiet. _Q30 sets CCOL, PL1 and PL2 in the
            // CPU, FANT, tells the EC and runs HIDB. IDPF picks its PL1 column: it reads 0 without Intel's DTT, which would give
            // 30, 25 and 15 W, under what the board runs after POST; for this call it asks for the other one, 50, 45 and 35 W.
            Method (SMOD, 1, Serialized)
            {
                If (_OSI ("Darwin"))
                {
                    If (CondRefOf (\_SB.PC00.LPCB.EC0._Q30))
                    {
                        If (((Arg0 >= One) && (Arg0 <= 0x03)))
                        {
                            Local0 = BIDP /* \_SB_.NTRO.BIDP */
                            BIDP = 0x55
                            BTUG = Arg0
                            \_SB.PC00.LPCB.EC0._Q30 ()
                            BIDP = Local0
                            Return (Zero)
                        }
                    }
                }

                Return (One)
            }

            // Gaming WMI the way NitroSense does it:
            // WMBX (opcode, Buffer) -> WMBH (0, opcode, Buffer). Whitelisted by the kext; Darwin only.
            Method (WMBX, 2, Serialized)
            {
                If (_OSI ("Darwin"))
                {
                    If (CondRefOf (\_SB.PC00.WMID.WMBH))
                    {
                        Return (\_SB.PC00.WMID.WMBH (Zero, Arg0, Arg1))
                    }
                }

                Return (Buffer (0x04)
                {
                     0xFF, 0xFF, 0xFF, 0xFF
                })
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
