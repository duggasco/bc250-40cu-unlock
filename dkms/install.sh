#!/bin/bash
# Install the bc250-amdgpu DKMS module.
#
# Copies the DKMS sources to /usr/src/bc250-amdgpu-<version>/, runs
# dkms add/build/install for the running kernel, and writes the modprobe
# option file. AUTOINSTALL=yes in dkms.conf takes care of rebuilds on
# future kernel updates.
set -euo pipefail

PKG="bc250-amdgpu"
VERSION="1.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
PATCH_SRC="${REPO_ROOT}/patch/bc250-40cu-amdgpu.patch"

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E "$0" "$@"
fi

if ! command -v dkms >/dev/null 2>&1; then
    echo "dkms is not installed. On CachyOS/Arch: sudo pacman -S --needed dkms" >&2
    exit 1
fi

if [[ ! -f "${PATCH_SRC}" ]]; then
    echo "patch not found: ${PATCH_SRC}" >&2
    exit 1
fi

KVER="$(uname -r)"
if [[ ! -d "/usr/lib/modules/${KVER}/build/drivers/gpu/drm/amd/amdgpu" ]] \
   && [[ ! -d "/lib/modules/${KVER}/build/drivers/gpu/drm/amd/amdgpu" ]]; then
    echo "kernel source tree for ${KVER} not found." >&2
    echo "install matching headers (e.g. linux-cachyos-headers) and reboot first." >&2
    exit 1
fi

SRC_DIR="/usr/src/${PKG}-${VERSION}"

echo "[bc250-amdgpu] populating ${SRC_DIR}"
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}/patch"
install -m 0644 "${HERE}/dkms.conf"  "${SRC_DIR}/dkms.conf"
install -m 0755 "${HERE}/prepare.sh" "${SRC_DIR}/prepare.sh"
install -m 0644 "${PATCH_SRC}"       "${SRC_DIR}/patch/bc250-40cu-amdgpu.patch"

if dkms status -m "${PKG}" -v "${VERSION}" 2>/dev/null | grep -q "${PKG}"; then
    echo "[bc250-amdgpu] ${PKG}/${VERSION} already registered; removing before re-adding"
    dkms remove -m "${PKG}" -v "${VERSION}" --all || true
fi

echo "[bc250-amdgpu] dkms add"
dkms add -m "${PKG}" -v "${VERSION}"

echo "[bc250-amdgpu] dkms build for ${KVER} (this can take a few minutes)"
dkms build -m "${PKG}" -v "${VERSION}" -k "${KVER}"

echo "[bc250-amdgpu] dkms install for ${KVER}"
dkms install -m "${PKG}" -v "${VERSION}" -k "${KVER}" --force

CONF="/etc/modprobe.d/bc250-40cu.conf"
if [[ ! -f "${CONF}" ]]; then
    {
        echo "# Enable BC-250 40 CU unlock (set by bc250-amdgpu/install.sh)"
        echo "options amdgpu bc250_cc_write_mode=3"
    } > "${CONF}"
    echo "[bc250-amdgpu] wrote ${CONF}"
else
    echo "[bc250-amdgpu] leaving existing ${CONF} alone"
fi

cat <<EOF

[bc250-amdgpu] done.

next steps:
  1) regenerate initramfs (otherwise the stock amdgpu is loaded from initramfs):
       sudo dracut --regenerate-all --force      # CachyOS on dracut (default)
       sudo mkinitcpio -P                        # CachyOS on mkinitcpio
  2) reboot
  3) verify:
       cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # expect: 3
       sudo dmesg | grep bc250-40cu                            # expect: CC/SPI writes
       sudo dmesg | grep active_cu_number                      # expect: active_cu_number 40
EOF
