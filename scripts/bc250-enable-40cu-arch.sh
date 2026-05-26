#!/usr/bin/env bash
# bc250-enable-40cu-arch.sh — Build and install a patched amdgpu for 40 CU on BC-250
#
# Usage:
#   sudo ./bc250-enable-40cu-arch.sh build     # patch + compile + install
#   sudo ./bc250-enable-40cu-arch.sh enable    # set 40 CU mode and reboot
#   sudo ./bc250-enable-40cu-arch.sh disable   # return to stock 24 CU and reboot
#   sudo ./bc250-enable-40cu-arch.sh status    # show current CU state
#   sudo ./bc250-enable-40cu-arch.sh restore   # restore original amdgpu module
#
# Requirements: linux-headers, gcc, make, zstd, curl. Must run as root on BC-250.
# Tested on: Arch Linux
#
# Authors: duggasco, Claude | License: GPL-2.0

set -euo pipefail

KVER="$(uname -r)"
KVER_BASE="${KVER%%-*}"          # e.g. 6.9.3 from 6.9.3-arch1-1
MODDIR="/usr/lib/modules/${KVER}"
MODPATH="${MODDIR}/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
MODSRC=""
BUILDDIR="/tmp/bc250-40cu-build"
CONF40="/etc/modprobe.d/bc250-40cu.conf"
BACKUP_SUFFIX=".bc250-backup-$(date +%Y%m%d)"
BC250_PCI_ID="13fe"

info()  { printf '\033[0;32m[+]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
err()   { printf '\033[0;31m[E]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

write_param_patch() {
    cat > "$1" << 'ENDPARAM'

/* BC-250 40 CU unlock: clears harvest mask + enables SPI dispatch to all WGPs */
static int bc250_cc_write_mode;
module_param(bc250_cc_write_mode, int, 0444);
MODULE_PARM_DESC(bc250_cc_write_mode,
	"BC-250: 0=off 1=probe-SE0SH0 2=clear-SE0SH0 3=clear-all-SAs 4=probe-all-SAs");
#define BC250_PCI_DEVICE_ID 0x13FE

ENDPARAM
}

write_cc_patch() {
    cat > "$1" << 'ENDCC'

	/* BC-250: unlock harvested CUs — CC (enumeration) + SPI (dispatch) + RLC (power) */
	if (bc250_cc_write_mode > 0 && adev->pdev->device == BC250_PCI_DEVICE_ID) {
		int bc_se, bc_sh;
		for (bc_se = 0; bc_se < adev->gfx.config.max_shader_engines; bc_se++) {
			for (bc_sh = 0; bc_sh < adev->gfx.config.max_sh_per_se; bc_sh++) {
				u32 bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after;
				if (bc250_cc_write_mode == 2 && (bc_se > 0 || bc_sh > 0))
					continue;
				gfx_v10_0_select_se_sh(adev, bc_se, bc_sh, 0xffffffff, 0);
				bc_cc_orig = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
				WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, 0);
				bc_cc_after = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
				bc_spi_orig = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
				WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, 0x1f);
				bc_spi_after = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
				WREG32_SOC15(GC, 0, mmRLC_PG_ALWAYS_ON_WGP_MASK, 0x1f);
				if (bc250_cc_write_mode == 1 || bc250_cc_write_mode == 4) {
					WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, bc_cc_orig);
					WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, bc_spi_orig);
					dev_info(adev->dev,
						"bc250-40cu-probe: se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x (restored)",
						bc_se, bc_sh, bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
				} else {
					dev_info(adev->dev,
						"bc250-40cu-enable: mode=%d se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x",
						bc250_cc_write_mode, bc_se, bc_sh,
						bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
				}
			}
		}
		gfx_v10_0_select_se_sh(adev, 0xffffffff, 0xffffffff, 0xffffffff, 0);
	}

ENDCC
}

check_bc250() {
    if ! lspci -nn 2>/dev/null | grep -qi "${BC250_PCI_ID}"; then
        warn "No BC-250 (PCI ID 13fe) detected. This patch is BC-250 specific."
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) exit 1 ;; esac
    fi
}

check_deps() {
    local missing=""
    command -v gcc  >/dev/null 2>&1 || missing="${missing} gcc"
    command -v make >/dev/null 2>&1 || missing="${missing} make"
    command -v zstd >/dev/null 2>&1 || missing="${missing} zstd"
    command -v curl >/dev/null 2>&1 || missing="${missing} curl"
    if [ ! -d "${MODDIR}/build" ]; then
        missing="${missing} linux-headers"
    fi
    if [ -n "$missing" ]; then
        err "Missing dependencies:${missing}"
        err "Install with: pacman -S base-devel zstd curl linux-headers"
        exit 1
    fi
}

find_source() {
    local d
    # Check common source locations (including Arch /usr/src/linux)
    for d in \
        "/usr/src/linux-${KVER}" \
        "/usr/src/linux-${KVER_BASE}" \
        "/usr/src/linux" \
        "/usr/src/linux-source-${KVER_BASE}"; do
        if [ -f "$d/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]; then
            MODSRC="$d"
            return 0
        fi
    done

    # Check for a pre-extracted tarball left from a previous build
    if [ -f "${BUILDDIR}/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]; then
        MODSRC="${BUILDDIR}/src"
        return 0
    fi

    # Download minimal amdgpu subtree directly from kernel.org
    local major="${KVER_BASE%%.*}"
    local url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${KVER_BASE}.tar.xz"
    info "Kernel source not found locally."
    info "Downloading amdgpu source from kernel.org (~120 MB)..."
    info "  ${url}"

    mkdir -p "${BUILDDIR}/src"
    if curl -fL --progress-bar "$url" | \
        tar xJ -C "${BUILDDIR}/src" --strip-components=1 \
            --wildcards \
            '*/drivers/gpu/drm/amd/' \
            '*/include/drm/' \
            '*/include/uapi/drm/' \
            2>/dev/null; then
        if [ -f "${BUILDDIR}/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]; then
            MODSRC="${BUILDDIR}/src"
            return 0
        fi
    fi

    die "Cannot find kernel source for ${KVER_BASE}.
  Option 1: pacman -S asp && asp checkout linux   (then makepkg -o)
  Option 2: place extracted source at /usr/src/linux-${KVER_BASE}"
}

patch_source() {
    local gfx="${MODSRC}/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"
    [ -f "$gfx" ] || die "gfx_v10_0.c not found at ${gfx}"

    if grep -q 'bc250_cc_write_mode' "$gfx"; then
        info "Source already patched."
        return 0
    fi

    info "Patching gfx_v10_0.c..."
    cp "$gfx" "${gfx}.orig"

    # Step 1: insert module parameter before '#include "amdgpu.h"'
    if ! grep -q '#include "amdgpu.h"' "$gfx"; then
        die "Cannot find anchor: #include amdgpu.h"
    fi

    local param_file
    param_file="$(mktemp)"
    write_param_patch "$param_file"
    sed -i "/#include \"amdgpu.h\"/r ${param_file}" "$gfx"
    rm -f "$param_file"

    # Step 2: insert CC write block in gfx_v10_0_get_cu_info after mutex_lock
    local cc_file
    cc_file="$(mktemp)"
    write_cc_patch "$cc_file"

    # Two-phase awk: avoid matching the forward declaration of gfx_v10_0_get_cu_info.
    # A forward declaration ends with "); " on a later line, while the actual body
    # starts with a standalone "{" on its own line right after the signature.
    awk -v insertfile="$cc_file" '
    /static.*gfx_v10_0_get_cu_info/ { maybe_func = 1 }
    maybe_func && /;/               { maybe_func = 0 }
    maybe_func && /^\{/             { in_cu_info = 1; maybe_func = 0 }
    in_cu_info && /mutex_lock/ && !inserted {
        print
        while ((getline line < insertfile) > 0) print line
        close(insertfile)
        inserted = 1
        next
    }
    { print }
    ' "$gfx" > "${gfx}.new"

    if grep -q 'bc250-40cu-enable' "${gfx}.new"; then
        mv "${gfx}.new" "$gfx"
        rm -f "$cc_file"
        info "Patch applied successfully."
    else
        rm -f "${gfx}.new" "$cc_file"
        mv "${gfx}.orig" "$gfx"
        die "Failed to insert CC write block. Kernel source layout may differ."
    fi
}

build_module() {
    local amdgpu_dir="${MODSRC}/drivers/gpu/drm/amd/amdgpu"
    [ -d "$amdgpu_dir" ] || die "amdgpu source directory not found"

    # define_trace.h (in the kernel headers) resolves the trace header as:
    #   ../../drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h
    # relative to its own location, ending up at:
    #   ${kbuild}/drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h
    # That directory already exists in linux-headers (contains only Kconfig),
    # so we copy the trace header there temporarily for the build.
    local kbuild="${MODDIR}/build"
    local kbuild_amdgpu="${kbuild}/drivers/gpu/drm/amd/amdgpu"
    local trace_dst="${kbuild_amdgpu}/amdgpu_trace.h"
    local trace_copied=0
    if [ ! -f "$trace_dst" ]; then
        mkdir -p "$kbuild_amdgpu"
        cp "${amdgpu_dir}/amdgpu_trace.h" "$trace_dst"
        trace_copied=1
    fi

    info "Building amdgpu module for kernel ${KVER} (2-5 min)..."
    make -C "$kbuild" M="$amdgpu_dir" -j"$(nproc)" modules 2>&1 | tail -10 >&2
    local make_rc=${PIPESTATUS[0]}

    [ "$trace_copied" -eq 1 ] && rm -f "$trace_dst"

    [ "$make_rc" -eq 0 ] || die "Build failed (make exited $make_rc)"

    local built="${amdgpu_dir}/amdgpu.ko"
    [ -f "$built" ] || die "Build failed - amdgpu.ko not produced"

    # Use grep -qa to avoid SIGPIPE/pipefail issue with `strings | grep -q` on large .ko files
    if ! grep -qa 'bc250_cc_write_mode' "$built"; then
        die "Built module missing bc250_cc_write_mode - patch failed"
    fi

    info "Build successful: ${built} ($(du -h "$built" | cut -f1))"
    echo "$built"
}

install_module() {
    local built="$1"
    local target="${MODPATH}"

    if [ -f "${target}.zst" ]; then
        target="${target}.zst"
    elif [ ! -f "$target" ]; then
        target="${target}.zst"
    fi

    if [ -f "$target" ] && [ ! -f "${target}${BACKUP_SUFFIX}" ]; then
        info "Backing up original to ${target}${BACKUP_SUFFIX}"
        cp "$target" "${target}${BACKUP_SUFFIX}"
    fi

    if [ "${target%.zst}" != "$target" ]; then
        info "Compressing and installing module..."
        zstd -f "$built" -o "$target"
    else
        cp "$built" "$target"
    fi

    depmod -a "$KVER"
    info "Module installed at ${target}"
}

do_build() {
    check_bc250
    check_deps
    find_source
    patch_source
    local built
    built="$(build_module)"
    install_module "$built"
    echo ""
    info "Done! Patched amdgpu module installed."
    info "Next: sudo $0 enable"
}

do_enable() {
    printf '# BC-250 40 CU re-enablement\noptions amdgpu bc250_cc_write_mode=3\n' > "$CONF40"
    info "40 CU mode configured in ${CONF40}"
    if ! ( set +o pipefail; modinfo amdgpu 2>/dev/null | grep -q 'bc250_cc_write_mode' ); then
        warn "Patched module not detected. Run: sudo $0 build"
        rm -f "$CONF40"
        exit 1
    fi
    info "Rebooting..."
    sleep 2
    reboot
}

do_disable() {
    rm -f "$CONF40"
    info "40 CU config removed. Rebooting to stock 24 CU..."
    sleep 2
    reboot
}

do_restore() {
    local target="${MODPATH}"
    if [ -f "${target}.zst" ]; then target="${target}.zst"; fi
    local backup
    backup="$(ls -1 "${target}.bc250-backup-"* 2>/dev/null | head -1)"
    [ -n "$backup" ] || die "No backup found"
    cp "$backup" "$target"
    rm -f "$CONF40"
    depmod -a "$KVER"
    info "Original module restored. Reboot to apply."
}

do_status() {
    printf '\033[1m=== BC-250 CU Status ===\033[0m\n\n'

    if lspci -nn 2>/dev/null | grep -qi "${BC250_PCI_ID}"; then
        printf '  PCI device:     \033[0;32mBC-250 detected\033[0m\n'
    else
        printf '  PCI device:     \033[0;31mBC-250 not found\033[0m\n'
    fi

    if ( set +o pipefail; modinfo amdgpu 2>/dev/null | grep -q 'bc250_cc_write_mode' ); then
        printf '  amdgpu module:  \033[0;32mpatched\033[0m\n'
    else
        printf '  amdgpu module:  \033[0;33mstock (unpatched)\033[0m\n'
    fi

    local mode
    mode="$(cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || echo 'N/A')"
    printf '  write_mode:     %s\n' "$mode"

    local cu_line
    cu_line="$(dmesg 2>/dev/null | grep 'active_cu_number' | tail -1)"
    if [ -n "$cu_line" ]; then
        local cus
        cus="$(echo "$cu_line" | grep -o 'active_cu_number [0-9]*' | awk '{print $2}')"
        if [ "$cus" = "40" ]; then
            printf '  active CUs:     \033[0;32m\033[1m40\033[0m (full die)\n'
        elif [ "$cus" = "24" ]; then
            printf '  active CUs:     \033[0;33m24\033[0m (stock)\n'
        else
            printf '  active CUs:     %s\n' "$cus"
        fi
    fi

    if [ -f "$CONF40" ]; then
        printf '  modprobe conf:  \033[0;32m%s (40 CU enabled)\033[0m\n' "$CONF40"
    else
        printf '  modprobe conf:  (none - stock mode)\n'
    fi
    echo ""
}

case "${1:-}" in
    build)   do_build ;;
    enable)  do_enable ;;
    disable) do_disable ;;
    restore) do_restore ;;
    status)  do_status ;;
    *)
        echo "BC-250 40 CU Re-enablement Tool (Arch Linux)"
        echo ""
        echo "Usage: sudo $0 <command>"
        echo ""
        echo "  build     Patch, compile, install patched amdgpu (~5 min)"
        echo "  enable    Activate 40 CU mode and reboot"
        echo "  disable   Return to stock 24 CU and reboot"
        echo "  status    Show current CU state"
        echo "  restore   Restore original amdgpu module"
        echo ""
        echo "Quick start:"
        echo "  sudo $0 build && sudo $0 enable"
        echo ""
        echo "Dependencies: pacman -S base-devel zstd curl linux-headers"
        ;;
esac
