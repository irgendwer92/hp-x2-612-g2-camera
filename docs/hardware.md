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
  VCM rail `vdd` for `i2c-INT3477:00-VCM` 2.8 V (VCM regulator).
- GPIOs (tps68470-gpio, guessed from CRD-G / Surface Go): 9 = `reset` (active low), 7 = `powerdown` (active low)
- Clock: `xvclk` from tps68470 clk, consumer `i2c-INT3477:00`. Driver modes assume 24 MHz.
- ipu-bridge: `IPU_SENSOR_CONFIG("INT3477", 1, 360000000)` (OV8858_LINK_FREQ).
