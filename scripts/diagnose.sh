#!/usr/bin/env bash
#
# diagnose.sh — READ-ONLY diagnosis for the "UUID does not exist / BusyBox" boot failure
#               caused by a missing `vmd` module (NVMe SSD behind Intel VMD).
#
# Run this from an Ubuntu Live USB ("Try Ubuntu"). It changes NOTHING — it only mounts
# your partitions read-only and prints findings. Safe to run.
#
# Usage:
#   chmod +x diagnose.sh
#   sudo ./diagnose.sh            # auto-detects the Ubuntu root partition
#   sudo ./diagnose.sh /dev/nvme0n1p7   # or pass the root partition explicitly
#
set -uo pipefail

ROOT_PART="${1:-}"
MNT=/mnt/diag-root

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }

say "1) Is this a Live/overlay session? (root should be overlay/squashfs)"
findmnt -no FSTYPE,SOURCE / || true

say "2) Is the NVMe SSD behind Intel VMD right now? (live USB can see it)"
if lsmod | grep -q '^vmd'; then ok "vmd module is loaded in this live session"; else warn "vmd not loaded here"; fi
NVME_PATH="$(readlink -f /sys/block/nvme0n1 2>/dev/null || true)"
echo "  nvme0n1 sysfs path: ${NVME_PATH:-<none>}"
if printf '%s' "$NVME_PATH" | grep -q 'pci10000:'; then
  ok "PCI domain 10000: present → SSD IS behind Intel VMD (needs the vmd module at boot)"
else
  warn "No 10000: domain detected — your NVMe may NOT be behind VMD (different root cause)"
fi

# --- Auto-detect the Ubuntu root partition if not provided ---
if [ -z "$ROOT_PART" ]; then
  say "3) Auto-detecting the Ubuntu root partition (ext4 containing /etc/fstab)"
  while read -r dev fstype; do
    [ "$fstype" = "ext4" ] || continue
    mkdir -p "$MNT"; mount -o ro "/dev/$dev" "$MNT" 2>/dev/null || continue
    if [ -f "$MNT/etc/fstab" ] && [ -d "$MNT/boot" ]; then
      ROOT_PART="/dev/$dev"; umount "$MNT"; break
    fi
    umount "$MNT" 2>/dev/null || true
  done < <(lsblk -rno NAME,FSTYPE | awk '$2=="ext4"{print $1, $2}')
fi

[ -n "$ROOT_PART" ] || { warn "Could not find the Ubuntu root partition. Pass it manually: sudo ./diagnose.sh /dev/nvmeXnXpX"; exit 1; }
ok "Ubuntu root partition: $ROOT_PART"

mkdir -p "$MNT"; mount -o ro "$ROOT_PART" "$MNT" || { echo "mount failed"; exit 1; }
trap 'umount "$MNT" 2>/dev/null || true' EXIT

say "4) Root UUID (this is the UUID that must exist at boot)"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"; echo "  $ROOT_UUID"

say "5) Installed kernels + initrd sizes (a much smaller initrd is suspicious)"
ls -la "$MNT"/boot/initrd.img-* 2>/dev/null | awk '{print "  "$5"  "$9}'

say "6) Module count per kernel (a huge gap = linux-modules-extra missing)"
for kdir in "$MNT"/lib/modules/*/; do
  [ -d "$kdir" ] || continue
  kv="$(basename "$kdir")"
  n="$(find "$kdir" -name '*.ko*' 2>/dev/null | wc -l)"
  has_vmd="$(find "$kdir" -name 'vmd.ko*' 2>/dev/null | head -1)"
  printf '  %-28s %6s modules   vmd.ko: %s\n' "$kv" "$n" "${has_vmd:+present}${has_vmd:-MISSING}"
done

say "7) Does each initrd already contain vmd?"
for img in "$MNT"/boot/initrd.img-*; do
  if lsinitramfs "$img" 2>/dev/null | grep -q 'vmd\.ko'; then
    ok "$(basename "$img") → contains vmd"
  else
    warn "$(basename "$img") → NO vmd (would fail to see the SSD)"
  fi
done

say "8) Leftover NVIDIA packages?"
n_nv="$(grep -c '^Package: .*nvidia' "$MNT"/var/lib/dpkg/status 2>/dev/null || echo 0)"
echo "  nvidia packages still installed: $n_nv"

say "DIAGNOSIS SUMMARY"
echo "  • If a kernel shows 'vmd.ko: MISSING' AND its module count is far lower than another kernel,"
echo "    that kernel is missing linux-modules-extra — booting it fails with 'UUID does not exist'."
echo "  • Fix path: boot the kernel whose initrd 'contains vmd', and/or add vmd to the initramfs."
echo "  • Run scripts/fix-boot.sh to apply the repair."
