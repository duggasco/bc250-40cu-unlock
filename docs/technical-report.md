# BC-250 40 CU Re-enablement — Technical Summary

Date: 2026-05-18

## Result

40 physical CUs on BC-250 (gfx1013, Cyan Skillfish) re-enabled with **1.61x compute scaling** at 1500 MHz, verified via controlled A/B/A testing.

## Two Registers Required

Neither alone is sufficient. Both must be modified:

1. **CC_GC_SHADER_ARRAY_CONFIG** (GC offset 0x0226f) — enumeration mask
   - Tells amdgpu/RADV/KFD how many CUs exist
   - Stock: `0xfff80000` (WGP 3-4 inactive) → Cleared: `0xffe00000` (all WGPs active)
   - Set via patched amdgpu kernel module (`bc250_cc_write_mode=3`)

2. **SPI_PG_ENABLE_STATIC_WGP_MASK** (GC offset 0x1277) — hardware dispatch gate
   - Controls which WGPs the SPI sends wavefronts to
   - Stock: `0x7` (WGP 0-2 only) → Enabled: `0x1F` (WGP 0-4)
   - No Linux driver code touches this register; firmware sets it at boot
   - Set via UMR post-boot: `umr -w cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 0x1f`
   - Also set: `umr -w cyan_skillfish.gfx1013.mmRLC_PG_ALWAYS_ON_WGP_MASK 0x1f`

**Why both:** CC tells RADV "40 CUs exist" so it generates dispatches for all of them. SPI tells the hardware "route waves to all 5 WGPs." CC alone = driver sees 40 but SPI only dispatches to 24. SPI alone = hardware allows 40 but RADV only generates work for 24.

## 4-State A/B Test (bc250-2, pp512 @ 2 GHz)

```
State   CC   SPI     Enum   Dispatch   pp512 tok/s   Power     SCLK      Temp
  1      0   0x07     24      24         302          56W     1000MHz    73C
  2      0   0x1F     24      40         302         140W     2000MHz    91C
  3      3   0x07     40      24         302          55W     1000MHz    74C
  4      3   0x1F     40      40         466         181W     2000MHz    96C
```

## A/B/A at 1500 MHz / 900 mV (sweet spot)

```
             pp512 tok/s    SCLK     Voltage    Power    Temp
24 CU (A):    230.38      1500MHz    881mV      95W      67→79C
40 CU (B):    371.60      1500MHz    874mV     125W      70→83C
24 CU (A):    230.44      1500MHz    881mV      94W      68→79C

Ratio: 371.6 / 230.4 = 1.61x
```

1500 MHz is the recommended operating point: close to theoretical 1.67x, sustainable thermals (83C), only 30W extra power.

## Stock Harvest Pattern

Both boards have identical contiguous harvesting:

```
SE0 SH0: ■■■■■■□□□□
SE0 SH1: ■■■■■■□□□□
SE1 SH0: ■■■■■■□□□□
SE1 SH1: ■■■■■■□□□□
24/40 CUs active, 16 harvested
```

CU 0-5 active (WGP 0-2), CU 6-9 fused (WGP 3-4) per SA. Symmetrical across all 4 SAs. Fuse mask: `CC_GC_SHADER_ARRAY_CONFIG = 0xfff80000`.

## Why CC Alone Didn't Work

Previously we thought clearing CC_GC_SHADER_ARRAY_CONFIG was sufficient. It isn't — the register is only an enumeration/topology input. The actual dispatch gate is `SPI_PG_ENABLE_STATIC_WGP_MASK`. Evidence:

- CC=3, SPI=0x7: throughput identical to stock (302 tok/s), power identical (55W)
- All 4 driver sources (dmesg, RADV, KFD, UMR) reported 40 CUs but silicon only computed with 24
- filippor's `ignore_cu_harvest` kernel parameter independently confirmed: enumeration changes don't affect compute

The SPI mask was discovered via UMR register analysis. On Vangogh (another RDNA2 APU), the equivalent control is `SMU_MSG_RequestActiveWgp`. Cyan Skillfish doesn't expose that SMU message, but the SPI register is directly writable.

## Supporting Evidence

- **CGTS** clock gating registers show identical configuration for harvested WGPs (3-4) and active WGPs (0-2) — the clock tree serves all 5 WGPs
- **RLC_PG_CNTL = 0** — all power gating is disabled on BC-250
- **glmark2** (3D graphics): 9430 → 9844 (+4.4%) — expected, graphics is fill-rate bound not CU-bound
- CUs pass Vulkan compute correctness tests (4M elements, zero errors) at 40 CU

## How To Apply

1. Build patched amdgpu module with `bc250_cc_write_mode` parameter
2. Set `options amdgpu bc250_cc_write_mode=3` in modprobe config
3. Reboot
4. After boot, run:
   ```
   umr -w cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 0x1f
   umr -w cyan_skillfish.gfx1013.mmRLC_PG_ALWAYS_ON_WGP_MASK 0x1f
   ```
5. Configure governor for 1500 MHz / 900 mV sweet spot

**TODO:** Integrate SPI write into the amdgpu kernel patch so both changes happen at driver init (no UMR needed post-boot).

## Credits

- duggasco — research, testing, documentation
- filippor — independent testing, `ignore_cu_harvest` kernel patch, governor
- Claude — analysis, tooling, register discovery
- Codex — identified SPI_PG_ENABLE_STATIC_WGP_MASK architecture
- BC-250 Discord community — thermal/voltage guidance, fleet survey
