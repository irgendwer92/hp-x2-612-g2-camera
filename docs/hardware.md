# HP Pro x2 612 G2 — camera hardware and bring-up log

> **Note:** the sections up to "Interface contract" summarise the hardware as
> it is understood now. Everything from "Bring-up log" on is a **historical,
> chronological log**: entries were written as things were found out, and
> later entries supersede earlier ones (for example the first guesses about
> rails, GPIOs and the front camera core voltage). For the current state see
> the [README](../README.md) and [front-camera.md](front-camera.md).

ACPI values below were evaluated at runtime via `acpi_call`; the raw dump is in
[`acpi_vals.txt`](acpi_vals.txt).

DMI: sys_vendor "HP", product_name "HP Pro x2 612 G2". Kernel baseline: v7.2.9 (Arch 7.2.9-arch1-1).
Platform: Skylake, Intel IPU3 (CIO2 PCI 0000:00:14.3, ImgU 0000:00:05.0).

## PMIC — \_SB.PCI0.CLP0
- ACPI HID INT3472, instance `INT3472:05`, _DDN "PMIC-CRDG" (Intel CRD-G reference design)
- CLDB: version 0, control-logic type 2 (= TPS68470), CRD version 0x50
- TPS68470 on I2C2 (i2c_designware.2) at 0x48, REVID 0x21
- Upstream failure: `int3472-tps68470 i2c-INT3472:05: error -ENODEV: No board-data found for this model`
- C0GP/C0Px/C0Gx/C0Fx (GPIO/power hint fields) are all 0 — BIOS gives no pin mapping.

## Rear camera — \_SB.PCI0.LNK0
- HID INT3477 (OV8858, 8 MP), module "6BA803T2", sensor model field L0SM=3
- I2C2: 0x10 sensor, 0x0c VCM (L0VC=2), 0x50–0x53 EEPROM (L0EE=8)
- CSI-2 port 0, 4 lanes, MCLK 19.2 MHz (L0CK=0x124f800), _PLD rear (0x69)
- Will enumerate as i2c device `i2c-INT3477:00` once the PMIC probes (ACPI _DEP).

## Front camera — \_SB.PCI0.LNK1
- HID INT347F, Sony IMX241 (5 MP; confirmed by the ID registers and the Windows INF), module "FN50FF-562H"
- I2C3 at 0x37, CSI-2 port 1, 2 lanes, MCLK 19.2 MHz in ACPI (runs at 24 MHz on Linux, see below).
- Driver: new `imx241` (patches/0005), see [front-camera.md](front-camera.md).

## Interface contract between the patches (current)
Rear, `i2c-INT3477:00` (ov8858):
- Regulators (TPS68470): `dvdd` 1.2 V (CORE), `avdd` 2.8 V (ANA), `dovdd` 1.8 V (VSIO);
  VCM rail 2.8 V as `vcc` (dw9714, VCM type 2) and `vdd` for `i2c-INT3477:00-VCM`, kept always on
  because the OV8858 does not answer on I2C without it. VIO 1.8 V always on.
- GPIOs (tps68470-gpio): 9 = `reset` (s_resetn, active low), 7 = `powerdown` (s_enable, active low).
- The rail mapping and GPIOs started as a copy of the Surface Go (CRD-G) wiring and were later
  confirmed against the Windows control-logic driver ([windows-ctrllogic-re.md](windows-ctrllogic-re.md)).
- ipu-bridge: `IPU_SENSOR_CONFIG("INT3477", 1, 360000000)` (OV8858_LINK_FREQ).

Front, `i2c-INT347F:00` (imx241):
- Regulators: `vsio` (VSIO, shared with the rear `dovdd`; switches the sensor I2C/IO path),
  `vcore` 1.053 V (VAUX1), `vio` 1.8 V (VAUX2).
- GPIOs: 4 = `avdd-enable` (external 2.8 V regulator), 5 = `reset`, 6 = `powerdown` (both active low).
  GPIO3 (Windows' VCM supply for the front module) is not mapped: the module is fixed focus.
- ipu-bridge: `IPU_SENSOR_CONFIG("INT347F", 1, 498000000)`.

Both:
- Clock: one shared TPS68470 output, `xvclk`; consumers are named automatically by tps68470.c from
  the PMIC ACPI dependents. The ov8858 probe sets it to 24 MHz; imx241 accepts 24 or 19.2 MHz.
- GPIO1/2 are the PMIC's I2C daisy chain (`daisy-chain-enable`) and must stay inputs.

## Bring-up log
### 2026-10-14, first hardware tests (patches 0001–0003, kernel 7.2.9-arch1-1)
- PMIC probes with the board data; `i2c-INT3477:00` is enumerated; ipu3-cio2 reports
  "Found supported sensor INT3477:00" / "Connected 1 cameras".
- Measured while powered (debugfs): CORE 1200 mV → dvdd, ANA 2815 mV → avdd,
  VSIO 1800 mV → dovdd, VIO 1800 mV always-on, VCM off; tps68470-clk 24 MHz enabled for
  `xvclk`; s_enable (7) and s_resetn (9) driven high (released).
- Chip-ID read (0x300a) at 0x10 is NACKed (-121), also with 20 ms settle delays.
- A blind `i2cdetect -r` scan of i2c-2 during the power hold wedged the bus
  (designware "controller timed out" from somewhere in 0x11–0x1f onward). The PMIC became
  unreachable, so the rails could not be switched off until a full power-off.
  Do not scan this bus; use targeted reads only.
- Open questions: reset/powerdown on PMIC GPIOs other than 7/9 (Dell 7212 uses 3/4)?
  Sensor at another address (0x36)? Does the module EEPROM (0x50) answer when powered?

### 2026-10-14, second run (after full power-off)
- Module EEPROM at 0x50 answers (`01 03 01 00`) while the sensor NACKs at 0x10 and 0x36:
  the module is powered and on i2c-2.
- Requesting PMIC GPIOs 0–6 as outputs caused `i2c_dw_handle_tx_abort: lost arbitration`
  on i2c-2 right after GPIO1 was driven → GPIO1/GPIO2 are wired to the I2C lines
  (TPS68470 I2C daisy chain). Board data now sets `daisy-chain-enable` (GPIO1/2 inputs).
- Rail switch-off failed again afterwards (`CORE: failed to disable: -EAGAIN`); full power-off
  needed after each failed experiment.

### 2026-10-14, third run (daisy chain enabled)
- Bus stays healthy for the whole hold (no arbitration loss / timeouts) with GPIO1/2 as inputs.
- Sensor NACKs at 0x10 and 0x36 for: GPIOs 0, 3, 4, 5, 6 driven high (together and singly), and every
  raw-level combination of s_resetn (9), s_enable (7) and s_idle (8). EEPROM 0x50 answers throughout.
- TPS68470 registers during the hold: PLLCTL d7, CLKCFG1 0a (HCLK A+B), SGPO 05, GPDI 59
  (GPIO1/2/5 read low; GPIO5 low despite pull-up), VAVAL 6d / VACTL 01, VDVAL 0c / VDCTL 05,
  VSIOVAL 34 / S_I2C_CTL 03, VIOVAL 34, VCM/AUX1/AUX2 off. Matches the intended config.

## Windows driver (HP SoftPaq sp93485, Intel IPU3 camera driver 30.15063.6.8317)
- `ov8858.inf` binds `ACPI\INT3477` ("HP Truevision 8MP Rear") and ships tuning for module
  `OV8858_6BA803T2_SKY` — confirms OV8858 + our module. `imx241.inf` covers the front module
  `IMX241_FN50FF-562H` (front sensor confirmed as IMX241).
- No power configuration in any INF. `iactrllogic64.sys` (control logic for `ACPI\INT3472`) has
  distinct TPS68470 code paths: `CrdGTi*` (CRD-G, as on the Surface Go), `CrdG2Ti*` (CRD-G2),
  `CrdG2TiQuantaGpio` (CRD-G2 with an OEM-specific GPIO variant), and `SSCrdG2Ti*` including
  `SetI2CDaisyChain` and `SetHCLKAB`. This board's daisy-chain wiring points at CRD-G2, i.e. the
  Surface Go (CRD-G) sequence copied in 0001 is likely the wrong model. See
  `docs/windows-ctrllogic-re.md` for the reverse-engineered sequence.
- The Intel binaries and tuning files are not redistributable and are not part of this repo.

### 2026-10-14, working
- Turning on the VCM rail (2.8 V) was the missing piece. With it the sensor answers:
  `Detected OV8858 sensor, revision 0xb2` (R2A, so 4 lanes are supported), `Instantiated dw9714 VCM`,
  and libcamera registers "Internal back camera" (`\_SB_.PCI0.LNK0`). `cam` and `qcam` stream.
- Reprobing the PMIC in the same boot fails ("INT3472 seems to have no dependents"); test once per boot.

### 2026-10-14, first picture
- `qcam`: orientation correct, Bayer order correct (reds stay red), autofocus (dw9714 + libcamera
  contrast AF) converges, but slowly.
- Strong lens-shading cast (magenta centre, cyan corners) plus vignetting. libcamera 0.7.2's IPU3
  IPA only implements Af, Agc, Awb, BlackLevelCorrection and ToneMapping. It has no lens-shading
  or CCM algorithm, although the ImgU hardware has both (`gd_shading`, `ccm`). Fixing the cast needs
  an IPU3 shading algorithm in libcamera, not just an `ov8858.yaml`.
- The module EEPROM (0x50–0x53) likely holds factory OTP calibration (the Windows ov8858.sys has
  NVM-read routines); a possible source for per-module shading/AWB data.

## Roadmap (2026-10-14; historical, all items done except upstream submission)
1. Lens shading correction: libcamera IPU3 `Lsc` algorithm + flat-field calibration tool (in progress).
   Flat-field method: white paper held against the lens, pointed at bright even light; raw capture.
2. Front camera (IMX241, `INT347F`, module FN50FF-562H, I2C3 0x37, CSI port 1, 2 lanes):
   first a cheap probe: power it with the recovered Windows sequence (VAUX1 core, VAUX2 I/O,
   GPIO4 analog enable, GPIO3, GPIO5/6 reset/powerdown; see windows-ctrllogic-re.md) and read
   registers 0x0000–0x0010 to see whether it is MIPI CCS/SMIA++ compliant (→ generic `ccs` driver)
   or needs a new driver. Watch for the shared TPS68470 clock (ov8858 runs at 24 MHz).
3. Publishing: real Signed-off-by, git remote, upstream submissions.

### 2026-10-14, flat-field calibration (tools/lsc)
- Black level measured from covered-lens frames: 14.75–16 DN at 10 bit (b 14.75, gb/gr 16, r 15),
  matching the 0x10 BLC target the driver programs. libcamera's IPU3 BlackLevelCorrection
  hard-codes 64, which over-subtracts on this sensor (crushed shadows) — to fix alongside Lsc.
- Flat field (paper against the lens, bright sky; direct sun clipped): corner/centre response
  r 0.14–0.16, gr/gb 0.19–0.21, b 0.21–0.22; corner R/G ≈ 0.75, B/G ≈ 1.09 (the cyan cast).
  Unclamped red corner gain ≈ 7×; with the default 4× cap 129/825 red points are clamped.
- libcamera 0.7.2 IPU3 raw stream reports sequence 0 for every buffer (cam's file sink overwrites
  raw frames); capture.sh works around it with one cam run per frame.

### 2026-10-14, LSC on hardware (libcamera/patches 0001–0004, tables from tools/lsc, max gain 8)
Measured on qcam PNG output (gamma-encoded), paper against the lens:

| | no LSC | LSC, BLC 64 | LSC, BLC 16 |
|---|---|---|---|
| corner luminance / centre | 0.37–0.40 | 0.86–0.94 | 1.00–1.17 |
| corner R/G | 0.62–0.66 | 0.87–0.92 | 1.02–1.03 |
| corner B/G | 0.97–1.01 | 0.99 | 1.00–1.01 |

- With the black level at 16 the colour shading is gone. The remaining luminance spread is asymmetric
  (1.00 to 1.17 between corners), i.e. most likely uneven illumination of the paper in that shot,
  not a systematic over-correction; worth re-checking with a cleaner flat field.
- A real scene (balcony) shows correct blacks (BLC 16 is right in ImgU units), natural colours,
  no corner cast; corners somewhat noisier (gains up to 7.15×).
- Not seen: grid offset, a striping seam, or wrong gain scaling (the open risks in libcamera/README.md).

### 2026-10-14, front camera probe, first attempt
- Patch 0004 asked AUX1 for exactly 1.2 V, which is not on the TPS68470 AUX grid (875 mV + n × 17.8 mV).
  `tps68470-regulator` then failed to probe entirely (`error -EINVAL: registering AUX1 regulator`),
  leaving even the rear camera unpowered for that boot. Fixed to 1.2132 V (n = 19), which is what the
  Windows driver programs (it rounds up). All board-data voltages are now checked against the grids:
  CORE 900 mV + n × 25 mV; ANA/VCM/VIO/VSIO/AUX1/AUX2 875 mV + n × 17.8 mV.

### 2026-10-14, front camera answers
- With 0004 (AUX1 1.2132 V, AUX2 1.8006 V, GPIO4 analog enable, GPIO5/6 high) the front sensor
  answers at the ACPI address 0x37 on i2c-3 (no answer at 0x10/0x1a/0x36; GPIO3/VCM not needed).
- ID registers: model 0x0241 (IMX241), revision 0x00, manufacturer 0x0b (Sony), SMIA version 0x0a
  (SMIA 1.0), pixel order 0x01 (RGGB), data pedestal 0x0040 (64 at 10 bit).
- Clock: the TPS68470 clock is shared; with the OV8858 holding it at 24 MHz, setting 19.2 MHz fails
  with -EBUSY. The IMX241 answers at 24 MHz.

### 2026-10-14, IMX241 SMIA limits (dump_limits=1)
Populated: analogue gain codes 0–224, gain = 256/(256 − code) (m0 0, c0 256, m1 −1, c1 256);
digital gain 0x0100–0x0fff step 1; coarse integration min 1, margin 5; ext clk 6–27 MHz (IEEE754
floats, SMIA 1.0); pre-PLL div 1–4, PLL input 6–27 MHz, multiplier 16–255, PLL output 384–1000 MHz;
vt_sys_clk_div 1–2, vt_pix_clk_div 8–20; op_sys_clk_div 1–2, op_pix_clk_div 8–10; frame length
202–65535 lines, line length 1456–65520 pck, min line blanking 312, min frame blanking 6; pixel array
0..1935 × 0..1095 (1936 × 1096); output 256×192 to 1952×1096; even inc 1, odd inc 1–15; no scaler.
**Zero (missing):** min/max vt_sys_clk_freq, vt_pix_clk_freq (0x1124–0x1133) and op_sys_clk_freq,
op_pix_clk_freq (0x1164–0x116b). The ccs driver's PLL calculator needs these, so ccs would need a
static data (limits override) file. Data format descriptors at 0x0040 and 0x00c0 are populated.

### Correction (2026-10-14): front camera core voltage
The imx241.sys check at 0x140007548 calls `_stricmp` (returns 0 on a *match*): modules FN50FF469H and
FN50FF-562H get VD = 0 ("unset" → control-logic default 1050 mV); every *other* module gets 1200 mV.
The earlier reading was inverted. 0004 now sets VAUX1 to 1.0530 V (n = 10, 1050 mV rounded up to the
grid, as Windows does). The two probe runs before this correction ran the IMX241 core at 1.2132 V for a
few seconds each; the sensor responded normally.
Further IMX241 findings from the Windows driver (docs/imx241-windows-re.md): Windows uses a 19.2 MHz
MCLK with a 2592×1944 readout (5 MP; the SMIA limit registers' 1936×1096 array size is wrong), PLL
998.4 MHz, link frequency 499.2 MHz, VT dividers in manufacturer registers 0x3037/0x3038 (standard
0x0301/0x0303 never written), 2 pixels per VT clock, and mandatory manufacturer register writes.

### 2026-10-14, front camera needs VSIO
- First test boot: imx241 binds next to ov8858 ("Connected 2 cameras"), streams correct SMIA colour
  bars at 1296x972 (CSI-2 port 1, 2 lanes, 498 MHz, 24 MHz clock). Later power-ups NACK.
- Every successful front power-up coincided with the rear sensor being powered (the -EBUSY on the
  shared clock gave it away); every failure had the rear idle. With the rear forced on
  (power/control=on) the IMX241 answers again. Windows' common CrdG2TiSensor::SensorPowerOn
  (0x140012cb4) calls IoActive (0x140013920) for any sensor, which sets S_I2C_CTL (0x43) |= 3,
  i.e. VSIO and the sensor I2C switch, refcounted. 0004 now adds VSIO as "vsio" supply of the
  IMX241 and the driver enables it first.

### 2026-10-14, front camera works
- With VSIO as an IMX241 supply (0004) and the rear idle (PipeWire stopped), the front camera streams
  in the test boot: correct SMIA colour bars and a real 1296x972 image (binned mode), no errors.
- System libcamera 0.7.2 (no IMX241 helper) rejects only the front camera ("Failed to create camera
  sensor helper for imx241") and still registers the rear camera. The patched local build
  (libcamera/patches 0005/0006) registers both: "Internal back camera" and "Internal front camera".
- Not yet tested: full 2592x1944 mode, libcamera streaming from the front camera.
- Full 2592x1944 mode at 24 MHz / 498 MHz link also streams cleanly (4 frames of 6469632 bytes:
  3328 bytes per line × 1944). qcam from the patched local libcamera shows a live, processed
  front-camera image ("okayish sharp"); mirror orientation still to be confirmed with a text test.

### 2026-10-14, front camera brightness
- In an evening-lit room the IPU3 AGC saturated at 33 ms / 8x analogue gain with a dark image.
  Measured raw signal above black (64) at fixed 15 ms: 3.7 DN at 1x, 27.6 DN at 8x (ratio 7.5,
  so the IMX241 analogue gain works as 256/(256 − code)); the sensor is simply insensitive.
- libcamera patch 0007: the IPU3 AGC now uses the sensor digital gain (V4L2_CID_DIGITAL_GAIN,
  default value = unity) up to 4x, keeping 30 fps (a design choice). The AGC settles at about
  1.5x digital gain in that room. libcamera 0008 raises the IMX241 AGC target to 0.32 (default
  0.16; a subjective choice): measured 2.07x digital gain at 0.24 and 3.24x at 0.36, so about 2.8x at 0.32.
