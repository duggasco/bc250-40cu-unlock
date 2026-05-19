#!/bin/bash
# Remove the bc250-amdgpu DKMS module and the modprobe option file.
# After running this, regenerate initramfs and reboot to return to the
# stock 24 CU amdgpu.
set -euo pipefail

PKG="bc250-amdgpu"
VERSION="1.0"

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E "$0" "$@"
fi

if command -v dkms >/dev/null 2>&1; then
    dkms remove -m "${PKG}" -v "${VERSION}" --all || true
fi

rm -rf "/usr/src/${PKG}-${VERSION}"
rm -f /etc/modprobe.d/bc250-40cu.conf

cat <<EOF
[bc250-amdgpu] uninstalled.

next steps to return to stock 24 CU:
  1) regenerate initramfs:
       sudo dracut --regenerate-all --force      # CachyOS on dracut (default)
       sudo mkinitcpio -P                        # CachyOS on mkinitcpio
  2) reboot
EOF
