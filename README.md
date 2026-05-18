# BC-250 40 CU Unlock

Re-enable all 40 CUs on the AMD BC-250 (gfx1013 / Cyan Skillfish / salvaged PS5 APU).

The BC-250 ships with 24 of 40 RDNA2 CUs active. This patch unlocks all 40 by writing two hardware registers during amdgpu driver init. No firmware mods, no permanent changes — just a kernel module parameter.

## Results

**pp512 (Vulkan LLM inference, Qwen3.5-9B Q4_K_XL):**

| Config | pp512 tok/s | Power | Temp | SCLK |
|--------|------------|-------|------|------|
| Stock 24 CU | 230 | 95W | 79C | 1500MHz |
| **40 CU unlocked** | **372** | **125W** | **83C** | **1500MHz** |
| **Ratio** | **1.61x** | +30W | +4C | same |

At 2 GHz (governor default): 302 → 466 tok/s = 1.54x, but hits 96C. 1500 MHz / 900 mV is the recommended sweet spot.

## How It Works

Two registers control CU availability — both must be modified:

| Register | What it does | Stock | Unlocked |
|----------|-------------|-------|----------|
| `CC_GC_SHADER_ARRAY_CONFIG` | Enumeration mask (tells driver how many CUs) | `0xfff80000` (24 CU) | `0xffe00000` (40 CU) |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | Dispatch gate (tells SPI where to send waves) | `0x7` (WGP 0-2) | `0x1F` (WGP 0-4) |

**Neither alone is sufficient.** CC alone changes what the driver reports but SPI still dispatches to 24 CUs. SPI alone enables hardware dispatch but the driver only generates work for 24 CUs.

The patch writes both during `gfx_v10_0_get_cu_info()`, guarded by `device == 0x13FE` (BC-250 only) and `bc250_cc_write_mode=3` (off by default).

## Quick Start

### Option 1: Build Script (any distro)

```bash
git clone https://github.com/duggasco/bc250-40cu-unlock.git
cd bc250-40cu-unlock
sudo ./scripts/bc250-enable-40cu.sh build
sudo ./scripts/bc250-enable-40cu.sh enable   # reboots
```

Requirements: `gcc`, `make`, `zstd`, kernel headers (`linux-headers-$(uname -r)`)

### Option 2: Apply Patch Manually

```bash
# Get your kernel source
cd /path/to/linux-source/drivers/gpu/drm/amd/amdgpu/

# Apply
patch -p5 < /path/to/bc250-40cu-unlock/patch/bc250-40cu-amdgpu.patch

# Build just amdgpu
make -C /lib/modules/$(uname -r)/build M=$(pwd) -j$(nproc) modules

# Install
sudo cp amdgpu.ko.zst /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/
sudo depmod -a

# Enable
echo 'options amdgpu bc250_cc_write_mode=3' | sudo tee /etc/modprobe.d/bc250-40cu.conf
sudo reboot
```

### Option 3: CachyOS / Arch

Apply `patch/bc250-40cu-amdgpu.patch` to your kernel PKGBUILD patch set, rebuild, add the modprobe config.

## Verification

After reboot:

```bash
# Check CU count
dmesg | grep active_cu_number
# Expected: active_cu_number 40

# Check register writes
dmesg | grep bc250-40cu
# Expected: bc250-40cu-enable: mode=3 se=0 sh=0 CC=0xfff80000->0xffe00000 SPI=0x00000007->0x0000001f

# Check RADV
RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu
# Expected: num_cu = 40
```

## CU Harvest Map

Check your board's stock CU layout (run without the patch):

```bash
./scripts/cu_map.sh
```

Our boards show contiguous harvesting:
```
SE0 SH0: ■■■■■■□□□□
SE0 SH1: ■■■■■■□□□□
SE1 SH0: ■■■■■■□□□□
SE1 SH1: ■■■■■■□□□□
24/40 CUs active, 16 harvested
```

We're collecting maps from across the fleet to find out if all BC-250s share this pattern.

## Governor / Thermal

40 CU at 2 GHz draws ~181W and hits 96C. Recommended: cap at 1500 MHz / 900 mV via `cyan-skillfish-governor`:

```toml
# /etc/cyan-skillfish-governor/config.toml
[[safe-points]]
frequency = 350
voltage = 700

[[safe-points]]
frequency = 1500
voltage = 900
```

## Selective CU Masking

Not all unlocked CUs may be healthy — boards with scattered harvest patterns (`■■□□■■□□■■`) may have defective silicon. You can enable all 40 CUs but selectively mask bad ones via `amdgpu.disable_cu`.

### WGP / CU Mapping (per shader array)

```
WGP 0 = CU 0,1    (stock active)
WGP 1 = CU 2,3    (stock active)
WGP 2 = CU 4,5    (stock active)
WGP 3 = CU 6,7    (unlocked — test these)
WGP 4 = CU 8,9    (unlocked — test these)
```

Disabling works at **WGP granularity** — disabling CU 6 also disables CU 7 (same WGP).

Format: `amdgpu.disable_cu=SE.SH.CU` (comma-separated, added to modprobe config)

### Examples

```bash
# Enable all 40, but mask WGP 3 in SE1/SH0 (CUs 6-7) — gives 38 CUs
options amdgpu bc250_cc_write_mode=3 disable_cu=1.0.6,1.0.7

# Mask WGP 4 across all shader arrays — gives 32 CUs
options amdgpu bc250_cc_write_mode=3 disable_cu=0.0.8,0.0.9,0.1.8,0.1.9,1.0.8,1.0.9,1.1.8,1.1.9
```

### Automated Health Testing

```bash
# Run per-WGP isolation test (20 reboots, tests each WGP individually)
sudo ./scripts/bc250-cu-health-test.sh start

# Quick correctness test on current config (no reboot)
./scripts/bc250-compute-verify.sh

# Generate disable_cu config from health results
./scripts/bc250-cu-mask.sh --results /var/lib/bc250-cu-health-test/results.tsv

# Install the mask (adds to modprobe config)
sudo ./scripts/bc250-cu-mask.sh --results /var/lib/bc250-cu-health-test/results.tsv --install

# View harvest map with health overlay
./scripts/cu_map.sh --health /var/lib/bc250-cu-health-test/results.tsv
```

## Disabling

```bash
sudo ./scripts/bc250-enable-40cu.sh disable   # removes config, reboots to 24 CU
sudo ./scripts/bc250-enable-40cu.sh restore   # restores original amdgpu module
```

## Technical Details

See [docs/technical-report.md](docs/technical-report.md) for the full writeup including:
- 4-state A/B test proving both registers are needed
- Register map (UMR dumps)
- Architecture analysis (CC vs SPI vs RLC vs SMU)
- Why `ignore_cu_harvest` doesn't work
- Power/thermal characterization

## Safety

- Default off (`bc250_cc_write_mode=0`) — does nothing unless explicitly enabled
- Guarded by PCI device ID `0x13FE` — only fires on BC-250
- No permanent hardware changes — reboot without the config returns to stock 24 CU
- The harvested CUs have power, clocks, and matching CGTS config — they were disabled by firmware policy, not silicon defects (RLC_PG_CNTL = 0, no power gating active)

## Credits

- **duggasco** — research, testing, documentation
- **filippor** — independent testing, `ignore_cu_harvest` kernel patch, cyan-skillfish-governor
- **Claude** — analysis, tooling, SPI register discovery
- **Codex** — identified SPI_PG_ENABLE_STATIC_WGP_MASK architecture
- **BC-250 Discord** — thermal/voltage guidance, fleet testing

## License

GPL-2.0 (same as the Linux kernel)
