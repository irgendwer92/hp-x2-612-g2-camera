# HP Pro x2 612 G2 — camera hardware (from ACPI, evaluated at runtime via acpi_call)

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
- HID INT347F (believed Sony IMX241, unverified), module "FN50FF-562H"
- I2C3 at 0x37, CSI-2 port 1, 2 lanes, MCLK 19.2 MHz. No Linux driver. Out of scope.

## Interface contract between the patches
Consumer device: `i2c-INT3477:00`
- Regulators (TPS68470): `avdd` 2.8 V (ANA), `dovdd` 1.8 V (VSIO / VIO), `dvdd` 1.2 V (CORE);
  VCM rail `vcc` (dw9714, VCM type 2) + `vdd` for `i2c-INT3477:00-VCM`, 2.8 V (VCM regulator).
- Rail mapping copies the Surface Go CRD-G wiring; NOT confirmed for this board (no schematic, BIOS hints empty).
- GPIOs (tps68470-gpio, guessed from CRD-G / Surface Go): 9 = `reset` (active low), 7 = `powerdown` (active low)
- Clock: `xvclk` — consumers are named automatically by tps68470.c from the PMIC ACPI dependents; no board data needed. Driver modes assume 24 MHz.
- ipu-bridge: `IPU_SENSOR_CONFIG("INT3477", 1, 360000000)` (OV8858_LINK_FREQ).

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
