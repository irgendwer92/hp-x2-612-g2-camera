# Windows Intel control-logic (TPS68470) reverse engineering notes

Static analysis only: the binaries were disassembled with capstone and never run.
Binaries come from the HP driver pack `Drivers_RS3/x64`:

- `iactrllogic64.sys` (InternalName `SkcController.sys`, "Intel(R) Control Logic" 1.0.0.1)
- `ov8858.sys` ("Camera Sensor OV8858" 10.0.10011.16384)

All addresses below are **RVAs** (image base not added). Function names come from the WPP
trace strings that each function passes to its entry/exit tracer (`lea reg, [rip+X]` -> string).
Legend: **[READ]** = read directly from instructions or constant data. **[INF]** = inferred.

## 0. Primitives

| RVA | What | Evidence |
|---|---|---|
| `0x11b7c` | `PmicRead(ctx, reg, *out, len)`. Retries once after 2 ms. | [READ] |
| `0x11cac` | `PmicWrite(ctx, reg, val, len)`. If `len == 0x20`, it only sleeps `val` ms. Retries once after 2 ms. | [READ] `cmp r9d,0x20 ; mov ecx,r8d ; call 0x23c8` |
| `0x23c8` | `Sleep(ms)`: `KeDelayExecutionThread(-10000*ms)` | [READ] `imul rcx, rax, -0x2710` |
| `0x11dfc` | SPB I2C transfer (IOCTL 0x41808). The `ctx` passed everywhere is the WDF device context. | [READ] |

## 1. Class selection

### 1a. CLDB parsing
`0x1280` evaluates `CLDB` (ACPI eval IOCTL 0x32c004, input signature `'AeiB' + 'CLDB'`).
`0x11678` copies the 32-byte buffer to `ctx+0x520`. `0x11ac0` then derives:

| ctx field | Source | Meaning |
|---|---|---|
| `0x4a8` | CLDB[2] | control-logic ID |
| `0x4ac` | CLDB[3] | "CRD version". Only 0x20, 0x30, 0x50 and 0x80 are kept; any other value becomes 0. [READ] `0x11ac0..0x11b0c` |
| `0x4b0` | CLDB[1] | type: 1 = discrete, 2 = TPS68470, 3 = uP6641, 4 = TestPMIC |
| `0x524` | CLDB[4] | PLL input clock: 0 = 19.2 MHz, 1 = 24 MHz, 2 = 26 MHz |
| `0x525`, `0x526` | CLDB[5], CLDB[6] | together select the "SS" variant (see 1b) |
| `0x52c`, `0x52d`, `0x52e` | CLDB[12..14] | flags. CLDB[14] sets the VA enable order for the UF (front) rail only |

Two `_DSM` lists are also read but do not matter on the TPS68470 path:
`79234640-9e10-4fea-a5c1-b5aa8b19756f` (count and entries at `0x41c`/`0x420`) and
`26257549-9271-4ca4-bb43-c4899d5a4881` (`0x44c`/`0x450`). They are used for discrete GPIO mapping (`0x26c3e`).

### 1b. PMIC object factory, `0x4168` [READ]
```
type(0x4b0)==2:
   if CLDB[5]==9 && CLDB[6]==1  -> SSTps68470   (ctor 0x6e50 -> SSCrdG2TiSensor)
   else                          -> TPS68470     (ctor 0xb650)
type==3 -> uP6641, type==1 -> discrete (0x591c / 0x4654), type==4 -> TestPMIC
```

### 1c. Sensor class inside `TPS68470::TPS68470` (`0xb650`) [READ]
```
0000b77b: mov eax, dword ptr [r14 + 4]     ; r14 = copy of ctx+0x4a8.., +4 = CRD version
0000b784: cmp eax, 0x30   -> CrdGTiSensor  (0x126b0) + clock vtbl 0x20848
0000b7fb: cmp eax, 0x50   -> CrdG2TiSensor (0x12578) + clock vtbl 0x20880
otherwise: no sensor object (SensorOn fails)
```
**CRD version byte 0x50 is what selects CrdG2.** No subsystem ID, registry value or OEM string is consulted.

### 1d. GPIO helper inside `CrdG2TiSensor::CrdG2TiSensor` (`0x12578`) [READ]
```
if ((dword ctx[0x4a4] >> (8*CLDB[2])) & 3) == 2  -> CrdG2TiQuantaGpio (vtbl 0x20900, GpioOper 0xff1c)
else                                              -> CrdG2TiGpio       (vtbl 0x208f0, GpioOper 0xfb60)
```
`ctx+0x4a4` is never written anywhere in the image. Every displacement-0x4a4 access is a read
(`0x10270`, `0x125fa`). `ctx+0x490..0x4a3` holds the 20-byte `_PLD` (DEVPKEY_Device_PhysicalDeviceLocation,
written at `0x10dc`). So the field stays at 0 and **CrdG2TiGpio is always used**. The Quanta path is dead in this build.
[READ that there are no writes; the conclusion that the field is always 0 is INF, high confidence]

### 1e. Our board (`docs/acpi_vals.txt`)
`CLP0.CLDB = 00 02 00 50 00 00 ...` gives:
- TPS68470 (not SS, because CLDB[5]=0)
- CrdG2TiSensor with CrdG2TiGpio
- 19.2 MHz PLL input (CLDB[4]=0)

## 2. Sensor power configuration passed by `ov8858.sys`

`ov8858.sys` fills a 0x3c-byte struct at `sensor_ctx+0xae0` and passes it to the control-logic
interface (`ctx+0xa20`: +0x20 Init, +0x28 PowerOn, +0x30 PowerOff). It is set at `0x5ffc..0x6050` and `0x3177..0x322c` [READ]:

| cfg off | Value | Source |
|---|---|---|
| +0x00 | `(_PLD dword2 >> 3) & 7` = panel. 5 = back, 4 = front | `0x6016..0x6045`. LNK0 `_PLD` byte 8 = 0x69, so panel **5** |
| +0x04 | SSDB.mclkspeed (SSDB+86). Ctor default 19 200 000 | `0x5ffc`, `0x38b7d` |
| +0x08 | VD (core) **1200 mV** (0x4b0) | `0x604b` |
| +0x0a | VA **2800 mV** | `mov [rbx+0xaea], 0x7080af0` |
| +0x0c | VIO **1800 mV** | same instruction |
| +0x0e | VCM **2800 mV** | `mov [rbx+0xaee], 0x7080af0` |
| +0x10 | VSIO **1800 mV** | same instruction |
| +0x18 | SSDB.version | `0x317e` |
| +0x24 | SSDB[95], set only if SSDB.version==1 | `0x31a1` |

In the control-logic driver, `cfg+0x18 == 1` means "use `cfg+0x24` (0 = WF, 1 = UF)". Otherwise it uses
`cfg+0` (5 = WF/world-facing/rear, 4 = UF/user-facing/front). Our SSDB.version is 0 and the panel is 5, so the
**WF (rear) path** applies. [READ the logic; the panel=5 value is from our ACPI dump]

## 3. SensorPowerOn for TPS68470 + CrdG2 + WF (rear OV8858)

Call chain [READ]: `CommonFunc::Cmd_SensorPowerOn` (`0x111c0`) calls `TPS68470::SensorOn` (`0xca38`):

1. `sensor->SetSensorConf` (`0x13174`) runs `VoltageWF::SetConf` (`0x1437c`) and copies the 5 voltages.
2. If `!clock->IsEnable` (`0xda9c`: `(PLLCTL & 0x70) == 0x50`), it runs `InitializeControlLogic` (`0xc380`) and then `SensorInitialize` (`0xc5f4`).
3. `sensor->MclkOutput(on=1)` (`0x128b8`)
4. `sensor->SensorPowerOn` (`0x12cb4`)
5. `sensor->SetGpio(0)` followed by `sensor->SetGpio(1)` (`0x12efc`, which calls GpioOper)
6. `CheckPMICStatus` (`0xbb00`): reads regs 0x01, 0x02, 0x03 and 0x29 for logging only

### Ordered register writes (first power-on, PLL not yet running)
| # | Reg | Value | Where | Note |
|---|---|---|---|---|
| 1 | 0x50 RESET | 0xFF | `ResetControlLogic` `0xc534` | [READ] |
| 2 | 0x2C, 0x2D, 0x2F, 0x2E | 0x00 each | `Tps68470Flash::FlashInitialize` `0xe350` | flash/ILED regs [READ] |
| 3 | 0x30 | `flashcfg[0x10] & 7` | same | [READ] |
| 4 | 0x0A XTALDIV | **0xAA** | `StartClock` `0xdcec` with values from `Clock::Initialize` `0xd888` | 0xD2 for 24 MHz input, 0xE6 for 26 MHz [READ] |
| 5 | 0x08 BUCKDIV | **0x02** | | MCLK 19.2 MHz (24 MHz: 0x04, 26 MHz: 0x05) |
| 6 | 0x07 BOOSTDIV | **0x03** | | (24 MHz: 0x08, 26 MHz: 0x0A) |
| 7 | 0x0B PLLDIV | **0x20** | | (24 MHz: 0x50, 26 MHz: 0x64) |
| 8 | 0x0C POSTDIV | 0x01 | | |
| 9 | 0x06 POSTDIV2 | 0x01 | | |
| 10 | 0x10 CLKCFG2 | **0x05** | `(1<<2)|1` | |
| 11 | 0x09 PLLSWR | **0x11** | | |
| 12 | 0x0D PLLCTL | **0xD1** | `(5<<4)|0x81` | |
| 13 | sleep 1 ms | | | |
| 14 | 0x0D PLLCTL | read, `&~1` (0xD0) | `ConfigHCLKAB` `0xd438` (from SetHCLKAB `0xdb88`, refcounted) | |
| 15 | 0x0F CLKCFG1 | `(old & 0xF0) | 0x02 | (0x02<<2)` = **0x0A** | | HCLK_A = 2, HCLK_B = 2. Both are always enabled together: `MclkOutput` passes (on,on) |
| 16 | 0x0D PLLCTL | 0xD1 | | |
| 17 | 0x43 S_I2C_CTL | read, `|= 0x03` | `VoltageWF::IoActive` `0x13920` -> `SetVSIOCtl` `0x14ed8` | done if refcount==1 or bit1 clear, and only if VSIO != 0 |
| 18 | 0x41 VAVAL | **0x6D** (2800 mV) | `VoltageWF::Initialize` `0x1362c` | |
| 19 | 0x40 VSIOVAL | **0x34** (1800) | | |
| 20 | 0x42 VDVAL | **0x0C** (1200) | | |
| 21 | 0x3C VCMVAL | **0x6D** (2800) | | |
| 22 | 0x3F VIOVAL | **0x34** (1800) | | |
| 23 | 0x47 VACTL | read, `|= 1` | `SetVACtl` `0x14590` | |
| 24 | 0x48 VDCTL | read, `|= 1` | `SetVDCtl` `0x14bc8` | |
| 25 | 0x44 VCMCTL | read, `|= 1` | `SetVCMCtl` `0x148b8` | **VCM rail is enabled at 2.8 V** |
| 26 | 0x22 SGPO | read, `&~0x04` | GpioOper(off) `0xfb60` | s_resetn low |
| 27 | sleep 1 ms | | | |
| 28 | 0x22 SGPO | `&~0x01` | | s_enable low |
| 29 | 0x22 SGPO | `|= 0x04` | GpioOper(on) | **s_resetn high first** |
| 30 | sleep 1 ms | | | |
| 31 | 0x22 SGPO | `|= 0x01` | | s_enable high |

Notes:
- **Voltage code formulas** [READ, doubles at `.rdata 0x20760..0x20780`]:
  - VA, VIO, VCM, VSIO, VAUX1, VAUX2: `code = (mV-875)/17.8`, rounded up when the truncated result is more than 0.5 mV low, then `& 0x7F`.
  - VD: `code = (mV-900)/25`, same rounding.
- **Defaults when the sensor driver gives no value** (ctor `0x133c8`): VD 1050 mV (0x06), VA/VCM 2800, VIO/VSIO 1800. ov8858 overrides VD to 1200.
- VIO has no CTL register write. It is treated as always-on [INF from the register map].
- **Delays:** no delays between the regulator enables. The only delays are 1 ms after the PLL start and 1 ms between s_resetn and s_enable.
- **Regular GPIOs:** for a WF (panel 5) sensor the rear path touches **no regular GPIO**. It uses only SGPO bits 2 (s_resetn) and 0 (s_enable). s_idle (bit 1) is never written.
- **Daisy chain:** the plain TPS68470/CrdG2 path never writes GPCTL1A/GPCTL2A (0x16/0x18). The only "daisy chain" action is S_I2C_CTL |= 3 in step 17.
- **MCLK input:** the PLL setup assumes a 19.2 MHz input (CLDB[4]=0). The MCLK *output* table is selected by cfg+4 (SSDB mclk): 19.2 MHz, 24 MHz or 26 MHz. Any other value falls back to the 19.2 MHz table.

### Other variants, for reference
- **UF (front, panel 4) on CrdG2:** `VoltageUF` [READ]
  - `Initialize` `0x13440` writes:
    - GPCTL4A (0x1C) = 0x8A
    - VAUX2VAL (0x3E) = code(VSIO)
    - VAUX1VAL (0x3D) = code(VD)
    - GPCTL3A (0x1A) = 0x8A
  - `PowerOn` `0x13e60` uses these controls:
    - "VA" = GPDO bit4 (GPIO4)
    - VSIO = VAUX2CTL bit0
    - VD = VAUX1CTL bit0
    - VCM = GPDO bit3 (GPIO3)
    - The point at which VA is switched on depends on CLDB[14] (0: first, 1: after VSIO, 2: after VD).
  - GpioOper type 4:
    - GPCTL5A (0x1E) = 0xC2, then GPDO bit5
    - GPCTL6A (0x20) = 0xC2, then GPDO bit6
    - No delay between them.
  - So **GPIO3/4/5/6 and VAUX1/2 belong to the front FN50FF-562H camera, not the OV8858.**
- **CrdG (CRD 0x30),** `CrdGTiGpio` `0x10110`:
  - SGPO |= 0x04, then sleep 1 ms.
  - If the (dead) `0x4a4` selector == 1, it drives GPIO5 high (GPCTL5A=0xC2, GPDO bit5).
  - Otherwise it sets SGPO |= 0x01.
- **Quanta (dead):**
  - type 5: GPCTL3A = 0xC2, then GPDO bit3.
  - type 4: GPCTL5A = 0xC2, then GPDO bit5.
- **SS variant** (CLDB[5]=9 and CLDB[6]=1, not our board):
  - `SSCrdG2TiSensor::SetI2CDaisyChain` `0x9cfc` only does read-modify-write of S_I2C_CTL (0x43) bit0, set or clear.
  - `SSCrdG2TiGpio::GpioOper` `0x90b8` uses the same SGPO bit2/bit0 (type 5) and GPIO5/6 (type 4) logic.

## 4. SensorPowerOff (`TPS68470::SensorOff` `0xc764`) [READ]
1. If CRD==0x30, or CRD==0x50 and panel==5: `Tps68470Flash::TorchPowerOff`.
2. `SetGpio(0)`: SGPO `&~0x04`, sleep 1 ms, SGPO `&~0x01`.
3. `MclkOutput(0)`: the HCLK refcount is decremented. At 0 it does:
   - PLLCTL `&~1`
   - CLKCFG1 bits[3:0] = 0
   - PLLCTL `|1`
   - then `StopClock` `0xe108`: PLLCTL `&~1`
4. `SensorPowerOff` `0x12ab8`:
   - `VoltageWF::PowerOff` `0x13cd8`: VACTL `&~1`, VDCTL `&~1`, VCMCTL `&~1`
   - then `IoIdle` `0x13a5c`: refcount decrement. At 0, S_I2C_CTL `&~0x03`.
5. `CheckPMICStatus`.

## 5. ov8858.sys
- **I2C address:** no hard-coded address. Register access goes through the SPB connection from the ACPI `_CRS`
  [INF: no 0x10 or 0x36 constants are passed to the I2C helper `0x3438`]. Note that LNK0 `_CRS` puts the sensor at
  **0x10 on `\_SB.PCI0.I2C2`, the same bus as the PMIC (0x48)**. The sensor is addressed on the main bus, not on a separate one.
- **Power-on** (`0x4480`):
  1. Control-logic SensorPowerOn (`0x6a0c` -> iface+0x28). This runs only if the SSDB byte1 (sku) upper nibble is in {2,3,5,7}; ours is 5.
  2. **`Sleep(20 ms)`** (`0x4573: mov ecx,0x14 ; call 0xa6c8`, which is KeDelayExecutionThread in ms). The sleep is skipped for modules named CM500RF05SW700, NSMM4D5 or START2FRONT.
  3. On the first power-on, `0x6850` -> `0x55cc` reads 2 bytes at **reg 0x300B** and expects **0x8858**.
- **EEPROM:** the chip-ID read is the first sensor access. NVM/EEPROM routines (strings `nvmRead0`, `RomRead1/2`, `Cmd_Brca016Read`) are separate and called later through callbacks at `ctx+0x8e0/0x8e8`. [INF: medium confidence about the ordering beyond the chip-ID read]

## 6. Differences from the current Linux setup (what to try)
1. **Enable VCM 2.8 V** (VCMVAL 0x6D, VCMCTL bit0). Windows always enables it for the rear sensor together with VA/VD.
2. **Ordering:**
   1. Windows starts the PLL and HCLK A+B first.
   2. Then S_I2C_CTL=3, then VAL writes, then VA, VD, VCM enables with no delays.
   3. Then SGPO: resetn+enable low, then **s_resetn high, 1 ms, s_enable high**.
   4. Then **20 ms** before the first I2C access (chip ID at 0x300B).
3. **MCLK:** Windows uses 19.2 MHz (XTALDIV 0xAA, PLLDIV 0x20, BOOSTDIV 3, BUCKDIV 2, POSTDIV 1, POSTDIV2 1, CLKCFG2 0x05, PLLSWR 0x11, PLLCTL 0xD1). Linux uses 24 MHz. This probably does not matter for the I2C ACK, but it is a difference.
4. **GPIOs:** GPIO 0..6 are not used by Windows for the rear camera, and neither is daisy-chain GPCTL1A/2A. GPIO5 reading low is expected: it is the front camera's reset/powerdown output and is never driven for the rear sensor.
5. VD = 1.2 V, VA = 2.8 V (0x6D), VIO = VSIO = 1.8 V (0x34) and CLKCFG1 = 0x0A already match Windows.
