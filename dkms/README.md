# DKMS package for bc250-amdgpu

This wraps the BC-250 40 CU patch (`patch/bc250-40cu-amdgpu.patch`) as a
[DKMS](https://github.com/dell/dkms) module. The patched `amdgpu` is
rebuilt automatically every time the kernel is updated, so unlike the
one-shot `scripts/bc250-enable-40cu.sh` flow you do **not** lose 40 CU
after `pacman -Syu` bumps the kernel.

Tested target: CachyOS / Arch with `linux-cachyos` + `linux-cachyos-headers`.
The same package should work on any distro whose kernel headers ship the
full `drivers/gpu/drm/amd/` source tree under
`/usr/lib/modules/$(uname -r)/build/`.

## Prerequisites

- AMD BC-250 (PCI device `0x13FE`). The patch is a no-op on anything else.
- Secure Boot **disabled** in UEFI. The DKMS-built module is unsigned;
  with Secure Boot on, the kernel will refuse to load it.
- Packages (CachyOS / Arch):
  ```bash
  sudo pacman -Syu
  sudo pacman -S --needed dkms base-devel linux-cachyos-headers zstd patch git
  ```
  Reboot after the upgrade so `uname -r` matches the installed headers.

## Install

From a checkout of this repo:

```bash
sudo ./dkms/install.sh
```

The script:

1. Copies the DKMS sources to `/usr/src/bc250-amdgpu-1.0/` and the patch
   into `/usr/src/bc250-amdgpu-1.0/patch/`.
2. Runs `dkms add` / `dkms build` / `dkms install` for the running
   kernel.
3. Writes `/etc/modprobe.d/bc250-40cu.conf` with
   `options amdgpu bc250_cc_write_mode=3`.

Then you must regenerate initramfs (so the patched `amdgpu` and the
modprobe option are picked up by the early boot) and reboot:

```bash
sudo dracut --regenerate-all --force      # CachyOS on dracut (default)
# or
sudo mkinitcpio -P                        # CachyOS on mkinitcpio

sudo reboot
```

## Verify

```bash
cat /sys/module/amdgpu/parameters/bc250_cc_write_mode    # expect: 3
sudo dmesg | grep bc250-40cu                              # expect: CC/SPI writes
sudo dmesg | grep active_cu_number                        # expect: active_cu_number 40
RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu   # expect: num_cu = 40
```

`dkms status` should also show the module as installed for the running
kernel:

```bash
dkms status -m bc250-amdgpu
# bc250-amdgpu/1.0, <kernelver>, x86_64: installed
```

## How it works

- `dkms.conf` declares one built module (`amdgpu`) and points DKMS at
  `prepare.sh` as `PRE_BUILD`.
- `prepare.sh` stages the kernel's `drivers/gpu/drm/amd/` subtree into
  the DKMS build directory (hardlinks where possible) and applies
  `patch/bc250-40cu-amdgpu.patch` with `patch -p5` against `gfx_v10_0.c`.
  The full `amd/` tree is needed because amdgpu's Kbuild references
  sibling directories (`../display`, `../pm`, `../include`).
- DKMS then runs `make -C ${kernel_source_dir} M=$(pwd)/amd/amdgpu modules`
  and installs the resulting `amdgpu.ko[.zst]` into
  `/lib/modules/<kver>/updates/dkms/`, which `depmod` resolves with
  higher priority than the in-tree `amdgpu.ko` under `kernel/`.
- `AUTOINSTALL=yes` in `dkms.conf` means the standard Arch/CachyOS
  pacman hooks (`dkms-modules.hook` / `dkms-remove.hook`) will rebuild
  the module for every newly installed kernel.

## Upgrades and kernel updates

On `pacman -Syu` that bumps `linux-cachyos`, the DKMS hook will:

1. Remove the bc250-amdgpu module built for the outgoing kernel.
2. Build and install it for the new kernel.
3. Trigger initramfs regeneration via the kernel package's own hooks.

If the patch ever fails to apply (because AMD changed the layout of
`gfx_v10_0.c` upstream), `dkms build` will fail and you'll be on the
stock 24 CU amdgpu until the patch is updated. Watch the output of
`pacman -Syu` for `bc250-amdgpu` build errors.

## Uninstall

```bash
sudo ./dkms/uninstall.sh
sudo dracut --regenerate-all --force      # or: sudo mkinitcpio -P
sudo reboot
```
