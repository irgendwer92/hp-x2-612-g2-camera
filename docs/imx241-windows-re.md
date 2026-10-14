# Windows IMX241 sensor driver: reverse-engineering notes

Static analysis only. The binary was disassembled with objdump/pefile and never run.
Source: HP SoftPaq sp93485, `Drivers_RS3/x64/imx241.sys` (x86-64 PE, image base 0x140000000).
Extraction: the inner CAB starts at file offset 0x4be8a of `sp93485.exe`; `bsdtar` extracts it.

All addresses are **VAs** (image base 0x140000000 included) unless marked as RVAs.
Legend: **[READ]** = read directly from instructions or constant data. **[INF]** = inferred.

## 0. Primitives

| VA | What | Evidence |
|---|---|---|
| `0x14000d1c4` | `RegRead(ctx, reg16, *buf, len)` | [READ] callers pass `edx=reg`, `r9d=len` |
| `0x14000d64c` | `RegWrite(ctx, reg16, val, len)`, len 1 or 2, big-endian on the wire | [READ] |
| `0x14000d350` | burst read (`0x0340`, 16 bytes) | [READ] |
| `0x14000d940` | `WriteTable(ctx, table*)` | [READ] see §1 |
| `0x14000a960` | `Sleep(ms)` (`KeDelayExecutionThread`, `imul rcx,rax,-10000`) | [READ] |
| `0x140013278` | `_stricmp` thunk (returns 0 on a match) | [READ] import at `0x140018188` |

Module-name strings (compared against the module string at `ctx+0x300`):
`0x140015b80` "CM500RF05SW700", `0x140016020` "START2FRONT", `0x140016030` "NSMM4D5",
`0x140016040` "FN50FF469H", `0x140016050` "FN50FF-562H".

## 1. Register-table format [READ]

Each entry is 16 bytes: `{u32 len, u32 reg, u32 val, u32 0}`.
- `len` 1..4 means "write `len` bytes of `val` to `reg`". `WriteTable` merges runs of consecutive
  registers into one I2C burst of up to 0x22 bytes. When `ctx+0x3dc` is set, it reads each burst back to verify it.
- `len == 0x20` means "sleep `val` ms" (`0x14000dc5d: mov ecx,[rbx+8]; call Sleep`).
- `len == 0xffff` ends the table.

Small tables:

| VA | Content | Use |
|---|---|---|
| `0x140018fc8` | `0100=00` | stream off (`0x140007a9c`, dl=0) |
| `0x140018ff8` | `0100=01` | stream on |
| `0x140019038` | `0104=01` | grouped-parameter hold on (exposure update) |
| `0x140019068` | `0104=00` | grouped-parameter hold off |
| `0x140019098` | `0103=01`, sleep 10 ms | soft-reset table. It looks unreferenced; the code writes 0x0103 directly (§5) |

## 2. Mode selection (`0x1400084e0`) [READ]

`ctx+0x9ee` holds the MCLK in Hz. Only **19 200 000 (0x124f800)** and **26 000 000 (0x18cba80)** are handled.
Any other value, **including 24 MHz**, logs an error and writes **no** mode table.
The request struct gives width (+0), height (+2) and fps (+0xc).

| MCLK | Mode | Module condition | Table VA |
|---|---|---|---|
| 19.2 | 2592x1944 | module ≠ CM500RF05SW700 and ≠ NSMM4D5 (**this includes FN50FF-562H**) | **A `0x1400190e0`** |
| 19.2 | 2592x1944 | CM500RF05SW700 or NSMM4D5 | B `0x1400194f0` |
| 19.2 | 1296x972 | fps == 60 | C `0x1400198f0` |
| 19.2 | 1296x972 | otherwise (30) | D `0x140019d00` |
| 26 | 2592x1944 | any | E `0x14001a120` |
| 26 | 1296x972 | fps == 30 | F `0x14001a580` |

The 26 MHz path is forced only for module "START2FRONT": `0x140007527: mov [rbx+0x9ee],0x18cba80`.
For every other module, including FN50FF-562H, the MCLK comes from platform data. On this machine that is 19.2 MHz (SSDB), so **table A is what Windows runs on the HP x2 612 G2**. [READ for the code path; INF that SSDB gives 19.2 here]

## 3. Mode tables (register values) [READ]

All six tables share this skeleton (order as written):
```
0101=00  303c=3b 303d=00 3041=d7 30e0=00 30e1=00 30f6=(20|00) 34ce=ff
0340/41=FLL  0342/43=LLP
0344..034b = 0,0,0,0, 0a1f, 0797          (x 0..2591, y 0..1943: full 2592x1944 array)
0381=01 0383=01 0385=01 0387=(01|03)
3048=(20|25) 30d5=00 3165=(20|28) 30d1=00 30d0=2a 3102=13 3103=47 3049=01 304d=02 304c=d7
0112=0a 0113=0a                            (RAW10)
034c/4d=out_w 034e/4f=out_h
0305=pre_div  [0306=00] 0307=mult
3037=0a 3038=01 303e=01
30a2=.. 30a5=.. 30a7=40 31aa=..
[26 MHz only: 0306=00 0309=0a 030d=0f 030e=03 030f=41 0310=00]
3301=00 3318=..
0202/03=coarse exposure  0204/05=0000 (again)  020e..0215 = 0100 x4 (digital gain 1.0)
```
`0x0301`, `0x0303`, `0x030b` and `0x0114` are **never written** in any table or by any code I found [READ].
`0x0309` is written (=10) only in the 26 MHz tables.

| Table | MCLK | Out | 0305 | 0307 | FLL 0340 | LLP 0342 | 0387 | 3048 | 30f6 | 3165 | 30a2 | 30a5 | 31aa | 3318 | 0202 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **A** | 19.2 | 2592x1944 | 2 | 0x68 (104) | 0x08e8 (2280) | 0x05b0 (1456) | 1 | 0x20 | 0x20 | 0x20 | 0x0e | 0x61 | 2 | 0x60 | 0x08e3 |
| B | 19.2 | 2592x1944 | 2 | 0x64 (100) | 0x080c (2060) | 1456 | 1 | 0x20 | 0x00 | 0x20 | 0x0e | 0x61 | 2 | 0x60 | 0x0807 |
| C | 19.2 | 1296x972 @60 | 2 | 0x34 (52) | 0x023a (570) | 1456 | 3 | 0x25 | 0x20 | 0x28 | 0x00 | 0x21 | 1 | 0x65 | 0x0235 |
| D | 19.2 | 1296x972 @30 | 2 | 0x24 (36) | 0x0316 (790) | 1456 | 3 | 0x25 | 0x20 | 0x28 | 0x00 | 0x21 | 1 | 0x67 | 0x0316 |
| E | 26 | 2592x1944 | 3 | 0x73 (115) | 0x08e9 (2281) | 1456 | 1 | 0x20 | 0x00 | 0x20 | 0x0e | 0x60 | 2 | 0x60 | 0x08e4 |
| F | 26 | 1296x972 @30 | 3 | 0x73 (115) | 0x081c (2076) | 0x0640 (1600) | 3 | 0x25 | 0x00 | 0x28 | 0x0e | 0x60 | 2 | 0x60 | 0x0817 |

Notes:
- **Pixel array: the driver reads out 2592x1944** (x_addr_end 0x0a1f, y_addr_end 0x0797). The
  "1936x1096" figure in the project notes does not match what Windows programs. [READ] Recheck the source of that number.
- The binned mode uses `0x0387=3` (vertical odd increment 3, i.e. 2:1 vertical skip/bin) plus
  `0x3048` bits[2:0]=5. Horizontal reduction comes from `0x3048`, not `0x0383`. [READ]
- `0x3048 & 7` is decoded by the driver as the binning factor: 0→1x1, 1→2x1, 5→2x2, 3→4x1 (`0x140005b25..0x140005b61`). [READ]
- The values `30a2/30a5/31aa/3318` follow the PLL rate (≈1 GHz: 0e/61/2/60; 499 MHz: 00/21/1/65;
  346 MHz: 00/21/1/67). They are probably MIPI/ADC timing for that bit rate. [INF]
- The writes `303c..34ce`, `3048..304c`, `3037/3038/303e`, `30a7`, `3301` appear in every mode (`3301`'s value never changes; the others vary per mode), so treat them as
  mandatory manufacturer setup. [READ for presence; INF for "mandatory"]
- `030d..0310` at 26 MHz: in CCS numbering these are op_pre_pll_div=15, op_pll_mult=0x0341, pll_mode=0.
  Single-PLL mode is selected, so the OP-PLL values are ignored. [INF]

## 4. Clock relations used by the driver itself [READ] (`0x140005920`)

The driver computes its own pixel clock. Excerpt:
```
5bc4: and eax,0xf               ; pre_div = reg0305 & 0xf
5cf7: mov eax,[mclk]; div pre_div
5d01: imul eax,reg0307          ; PLL out
5d05: div reg3037               ; /10
5d0a: div reg3038               ; /1
5d0c: add eax,eax               ; x2
```
It also reports line length as `2 * reg0342` (`0x140005a3b: add ax,ax`). It sets coarse integration
min/margin to 1/5 (`mov dword [rbx+0xc],0x50001`).

So on this sensor **0x3037 is the effective VT pixel divider (IVTPXCK_DIV, 10) and 0x3038 the VT system divider (IVTSYCK_DIV, 1)**.
The sensor clocks **2 pixels per VT pixel clock**: 1456 clocks per line ≥ 2592/2.
The driver's "pixel rate" is `2 * PLL / 10`. [READ for the formula; INF for the register names]

## 5. Computed operating points

Formulas: `pll_ip = mclk/0305`, `pll = pll_ip*mult`, `vt_sys = pll/3038(=1)`, `vt_pix = vt_sys/3037(=10)`,
pixel rate = 2·vt_pix, frame rate = vt_pix / (LLP·FLL).
For the output side, SMIA defines op_sys_clk as the per-lane bit clock. Assuming op_sys_div=1 and op_pix_div=10 (the RAW10 default, written explicitly as `0309=0a` at 26 MHz):
lane rate = pll, CSI-2 link frequency (DDR) = pll/2, op_pix = pll/10.
op_sys_div=1 is confirmed by bandwidth: full mode needs ≥ 2592·10/2 bits per line in 14.6 µs,
i.e. ≥ 888 Mbit/s per lane; op_sys_div=2 (499 Mbit/s) could not carry it. [INF, high confidence]

| Table | MCLK | pll_ip | PLL out = vt_sys = op_sys | vt_pix = op_pix | Pixel rate (2·vt_pix) | Link freq | Line time | fps |
|---|---|---|---|---|---|---|---|---|
| **A (ours)** | 19.2 | 9.6 | **998.4 MHz** | **99.84 MHz** | 199.68 Mpix/s | **499.2 MHz** | 14.58 µs | **30.07** |
| B | 19.2 | 9.6 | 960.0 | 96.0 | 192.0 | 480.0 | 15.17 µs | 32.0 |
| C | 19.2 | 9.6 | 499.2 | 49.92 | 99.84 | 249.6 | 29.17 µs | 60.15 |
| D | 19.2 | 9.6 | 345.6 | 34.56 | 69.12 | 172.8 | 42.13 µs | 30.04 |
| E | 26 | 8.667 | 996.67 | 99.67 | 199.33 | 498.33 | 14.61 µs | 30.01 |
| F | 26 | 8.667 | 996.67 | 99.67 | 199.33 | 498.33 | 16.05 µs | 30.01 |

Table D's PLL output (345.6 MHz) is below the 384 MHz minimum that the sensor reports as a limit, so Windows does not respect that limit.
For bin modes, 1296·10/2 = 6480 bits per line fits easily.

**24 MHz: Windows has no table** [READ]. A matching point for 24 MHz ext clk [INF]:
pre_div 2 → 12 MHz, mult 83 → **996 MHz** PLL, vt_pix 99.6 MHz, **link frequency 498 MHz**, ~30.0 fps
with LLP 1456 / FLL 2280. Alternatives are pre_div 4 → 6 MHz, mult 166 (also 996 MHz), or pre_div 3, mult 125 (exactly
1000 MHz, the PLL maximum; not recommended). Simpler option: run the TPS68470 at 19.2 MHz and copy table A exactly
(link freq 499.2 MHz).

## 6. Power-up / init sequence [READ unless noted]

1. Power rails/clock are switched on through the control-logic interface (`ctx+0xa08` vtable `+0x28` on,
   `+0x30` off; `0x1400079a4`). The rail timing is in `iactrllogic64.sys`; see `windows-ctrllogic-re.md`.
2. Sleep **20 ms** (`0x14000de39: mov ecx,0x14; call Sleep`), then the chip-ID read: `0x0000`, 2 bytes, expected **0x0241**
   (`0x14000587e: mov r8d,0x241`).
3. Soft reset: write `0x0103=01`, then sleep **1 ms** (`0x140008364..0x140008379`).
4. Stream off (`0100=00`), then the mode table (§3). Then the driver reads `0x0101` and writes it back with
   flip/mirror bits for the platform rotation (`0x1400086fa..0x140008770`). It also reads `0x0340` back as the
   minimum FLL (global `0x140020cec`) [INF on the purpose].
5. Stream on: `0100=01`.

Voltage struct (`0x1400074a0`):
- `+0xacc` = MCLK.
- `+0xad2`/`+0xad4` = 2800/1800 mV (AVDD/DOVDD).
- `+0xad6` = 2800 mV or 0 (VCM, if `ctx+0x3e4` is set).
- `+0xad0` = core (DVDD). **Correction to the earlier note:** with `_stricmp` returning 0 on a match, the code gives
  **DVDD = 0 for "FN50FF469H" and "FN50FF-562H"** and 1200 mV for every other module:
  ```
  75b5: call _stricmp("FN50FF469H"); test eax,eax; je 75df   ; match -> [ad0]=si (0)
  75c8: call _stricmp("FN50FF-562H"); test eax,eax; je 75df  ; match -> 0
  75d1: mov eax,0x4b0 ; [ad0]=1200                            ; anything else
  ```
  [READ]. Possible meaning: the FN50FF modules have an on-module core LDO, or "0" means "leave the rail as configured". [INF]
- `+0x10` gets a per-module 16-byte GUID: CM500RF05SW700/START2FRONT → `0x14001a100`, NSMM4D5 → `0x14001a110`,
  others → `0x140019088`. These are GUIDs, not register tables. [READ]

## 7. Exposure / gain (`0x140006264`) [READ]

Input: coarse exposure (u16), analogue gain code (u16, **rejected if > 0xe0**), digital gain (u16), and
a requested FLL. Sequence:
```
WriteTable(0104=01)                        ; group hold
0340 (2 bytes) = max(minFLL, coarse+5, requested FLL)
0202 (2 bytes) = coarse                    ; lines
0205 (1 byte)  = again code                ; only the low byte of 0x0204
020e..0215 (8-byte burst) = dgain x4       ; 8.8 fixed point, 0x0100 = 1.0x
WriteTable(0104=00)
```
- Exposure is in lines. Margin 5, minimum 1 (also from `0x50001` in §4).
- Analogue gain code range 0..224. With the usual Sony SMIA formula gain = 256/(256-code), 224 gives 8.0x.
  The formula is [INF]; the 0xe0 limit is [READ].
- Digital gain format 8.8 is [INF], based on the default 0x0100 written in all tables.

## 8. Recommended Linux CCS/limit values [INF]

The Windows operating points bracket PLL 345.6–998.4 MHz and vt_pix 34.56–99.84 MHz.

| Limit | Min | Max |
|---|---|---|
| vt_sys_clk_freq_hz | 340 MHz (or 384 MHz if you only use the A/C-like points) | 1000 MHz |
| vt_pix_clk_freq_hz | 34 MHz | 100 MHz |
| op_sys_clk_freq_hz | 340 MHz | 1000 MHz |
| op_pix_clk_freq_hz | 34 MHz | 100 MHz |

- Recommended link frequency: **498 000 000 Hz** at 24 MHz ext clk (PLL 996 MHz).
- At 19.2 MHz ext clk: **499 200 000 Hz**, which reproduces Windows table A bit-for-bit.

Caveats:
- The real VT dividers are `0x3037`/`0x3038`, not `0x0301`/`0x0303`. Windows never writes `0x0301`, `0x0303` or `0x030b`.
  A CCS driver that writes the standard registers may have no effect. It needs to write 0x3037=10/0x3038=1
  (e.g. via a quirk or a manufacturer register list) and keep the PLL near the Windows points so that the
  rate-dependent registers `30a2/30a5/31aa/3318` stay valid.
- Two pixels are clocked per vt_pix_clk (LLP 1456 < width 2592). The generic CCS min-LLP calculation
  (width + min blanking) will force a longer line, giving about half the frame rate unless a quirk handles it.
- Lane count (`0x0114`) is never written by Windows. The 2-lane configuration must be the power-on default,
  or is set by one of the manufacturer writes. [INF]
