#!/usr/bin/env bash
# eip-hermes-component:
#   name: disk-expand
#   description: Grow the root LV to use all free VG space (skips cleanly if not LVM, already grown, or unsupported FS)
#   default: enabled
#   ports:
#   requires:
#
# Why this runs near the top of the plan:
# Ubuntu Server's default partitioner creates a ~100G LV inside a VG that
# usually spans the whole disk, leaving most of the disk unallocated. A full
# Hermes install -- especially with `--with lab-host` (Win11 LTSC + virtio-win
# ISOs, ~1.5G) and the security toolchain -- will overrun 100G on a real lab
# host. Grow the LV to consume all free VG space *before* the big downloads.
#
# Skip with `install.sh --skip disk-expand` if you intentionally want to
# keep the rest of the VG unallocated (multiple LVs, future libvirt storage
# pool, etc.).

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

# === disk expansion ========================================================

disk_expand_root() {
  log "Checking whether the root filesystem can be grown into free VG space."
  log "  (the Ubuntu Server installer typically leaves most of the disk unallocated;"
  log "   we expand to use it. Skip with --skip disk-expand to keep the layout as-is.)"

  if ! need_cmd lvs || ! need_cmd findmnt; then
    log "LVM tools or findmnt not present; root is not LVM-managed. Skipping."
    return 0
  fi

  local root_src lv_path vg_name fstype free_extents free_bytes free_h before_h
  root_src="$(findmnt -no SOURCE /)"

  # Confirm root is on an LV before touching anything. `lvs <path>` returns
  # nonzero for non-LV paths, which is the cleanest probe.
  if ! sudo_cmd lvs "$root_src" >/dev/null 2>&1; then
    log "Root filesystem ($root_src) is not on LVM. Skipping disk expansion."
    return 0
  fi

  lv_path="$(sudo_cmd lvs --noheadings -o lv_path "$root_src" | awk '{print $1}')"
  vg_name="$(sudo_cmd lvs --noheadings -o vg_name "$lv_path"  | awk '{print $1}')"
  fstype="$(findmnt -no FSTYPE /)"
  free_extents="$(sudo_cmd vgs --noheadings -o vg_free_count "$vg_name" | awk '{print $1}')"
  free_bytes="$(sudo_cmd vgs --noheadings --units b --nosuffix -o vg_free "$vg_name" | awk '{print $1}')"
  free_h="$(numfmt --to=iec --suffix=B "$free_bytes" 2>/dev/null || echo "${free_bytes}B")"

  log "Root LV:  $lv_path"
  log "VG:       $vg_name"
  log "FS type:  $fstype"
  log "VG free:  $free_h ($free_extents extents)"

  if [ "${free_extents:-0}" -eq 0 ]; then
    success "VG '$vg_name' has no free extents -- root LV already fills the VG. Nothing to do."
    return 0
  fi

  before_h="$(df -h --output=size / | tail -1 | tr -d ' ')"

  case "$fstype" in
    ext4|ext3|ext2)
      log "Growing $lv_path by +100%FREE and resizing $fstype online ..."
      sudo_cmd lvextend -l +100%FREE "$lv_path"
      sudo_cmd resize2fs "$lv_path"
      ;;
    xfs)
      log "Growing $lv_path by +100%FREE and resizing xfs online ..."
      sudo_cmd lvextend -l +100%FREE "$lv_path"
      sudo_cmd xfs_growfs /
      ;;
    *)
      warn "Root filesystem type '$fstype' is not supported for online grow by this component (only ext2/3/4 and xfs). Skipping."
      return 0
      ;;
  esac

  local after_h
  after_h="$(df -h --output=size / | tail -1 | tr -d ' ')"
  success "Root grown: $before_h -> $after_h"
}

# === component entry points ================================================

run() {
  disk_expand_root
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
fi
