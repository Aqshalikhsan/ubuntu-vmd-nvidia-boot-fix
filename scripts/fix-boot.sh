#!/usr/bin/env bash
#
# fix-boot.sh — Repair the "UUID does not exist / BusyBox" boot failure caused by a missing
#               `vmd` module (NVMe SSD behind Intel VMD) after an NVIDIA/kernel install.
#
# What it does (inside a chroot into your installed system):
#   1. Mounts your Ubuntu root partition read-write + binds /dev /proc /sys /run (+ EFI).
#   2. Adds `vmd`, `nvme`, `nvme_core` to /etc/initramfs-tools/modules (forces them into initramfs).
#   3. Rebuilds initramfs for all kernels.
#   4. Sets the GRUB default to a HEALTHY kernel (one whose modules are complete / initrd has vmd),
#      shows the GRUB menu as a safety net, and clears the recordfail flag.
#   5. Runs update-grub and unmounts cleanly.
#
# Run from an Ubuntu Live USB ("Try Ubuntu").
#
# Usage:
#   chmod +x fix-boot.sh
#   sudo ./fix-boot.sh                                  # auto-detect root + EFI + healthy kernel
#   sudo ./fix-boot.sh /dev/nvme0n1p7 /dev/nvme0n1p1    # root, EFI (optional overrides)
#   HEALTHY_KERNEL=6.8.0-40-generic sudo -E ./fix-boot.sh   # force which kernel becomes default
#
set -euo pipefail

ROOT_PART="${1:-}"
EFI_PART="${2:-}"
MNT=/mnt/root

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run with sudo."

# ---------- Auto-detect root partition ----------
if [ -z "$ROOT_PART" ]; then
  say "Auto-detecting the Ubuntu root partition"
  tmp=/mnt/_probe; mkdir -p "$tmp"
  while read -r dev fstype; do
    [ "$fstype" = "ext4" ] || continue
    mount -o ro "/dev/$dev" "$tmp" 2>/dev/null || continue
    if [ -f "$tmp/etc/fstab" ] && [ -d "$tmp/boot" ]; then ROOT_PART="/dev/$dev"; umount "$tmp"; break; fi
    umount "$tmp" 2>/dev/null || true
  done < <(lsblk -rno NAME,FSTYPE | awk '$2=="ext4"{print $1,$2}')
  rmdir "$tmp" 2>/dev/null || true
fi
[ -n "$ROOT_PART" ] || die "Could not auto-detect root. Pass it: sudo ./fix-boot.sh /dev/nvmeXnXpX"
ok "Root partition: $ROOT_PART"

# ---------- Auto-detect EFI partition ----------
if [ -z "$EFI_PART" ]; then
  EFI_PART="$(lsblk -rno NAME,PARTTYPE,FSTYPE | awk '$2=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print "/dev/"$1; exit}')"
  [ -z "$EFI_PART" ] && EFI_PART="$(lsblk -rno NAME,FSTYPE | awk '$2=="vfat"{print "/dev/"$1; exit}')"
fi
ok "EFI partition:  ${EFI_PART:-<none / skipped>}"

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
ok "Root UUID:      $ROOT_UUID"

# ---------- Mount + chroot binds ----------
say "Mounting $ROOT_PART read-write and binding /dev /proc /sys /run"
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"
for d in dev dev/pts proc sys run; do mount --bind "/$d" "$MNT/$d"; done
[ -n "${EFI_PART:-}" ] && mount "$EFI_PART" "$MNT/boot/efi" 2>/dev/null || true

cleanup() {
  say "Unmounting cleanly"
  sync
  umount "$MNT/boot/efi" 2>/dev/null || true
  for d in run sys proc dev/pts dev; do umount "$MNT/$d" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  ok "Done unmounting"
}
trap cleanup EXIT

# ---------- Pick the healthy kernel (default: the one whose initrd already contains vmd) ----------
say "Choosing a healthy kernel to boot by default"
HEALTHY_KERNEL="${HEALTHY_KERNEL:-}"
if [ -z "$HEALTHY_KERNEL" ]; then
  for img in "$MNT"/boot/initrd.img-*; do
    kv="$(basename "$img" | sed 's/^initrd.img-//')"
    if lsinitramfs "$img" 2>/dev/null | grep -q 'vmd\.ko'; then HEALTHY_KERNEL="$kv"; fi
  done
fi
[ -n "$HEALTHY_KERNEL" ] || die "No kernel with vmd in its initrd found. Set HEALTHY_KERNEL=... manually."
ok "Healthy kernel: $HEALTHY_KERNEL"

# ---------- 1) Force vmd/nvme into the initramfs ----------
say "Adding vmd/nvme to /etc/initramfs-tools/modules"
MODFILE="$MNT/etc/initramfs-tools/modules"
if ! grep -q '^vmd$' "$MODFILE" 2>/dev/null; then
  cat >> "$MODFILE" <<'EOF'

# --- Fix boot: NVMe SSD behind Intel VMD (added during repair) ---
vmd
nvme
nvme_core
EOF
  ok "Appended vmd/nvme/nvme_core"
else
  ok "vmd already present — skipping"
fi

# ---------- 2) Rebuild initramfs ----------
say "Rebuilding initramfs for all kernels"
chroot "$MNT" /bin/bash -c "update-initramfs -u -k all"

# ---------- 3) Set GRUB default to the healthy kernel ----------
say "Pointing GRUB default at $HEALTHY_KERNEL"
cp "$MNT/etc/default/grub" "$MNT/etc/default/grub.bak-repair"
ENTRY="gnulinux-advanced-${ROOT_UUID}>gnulinux-${HEALTHY_KERNEL}-advanced-${ROOT_UUID}"
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$ENTRY\"|" "$MNT/etc/default/grub"
sed -i "s|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|" "$MNT/etc/default/grub"
grep -q '^GRUB_TIMEOUT_STYLE=' "$MNT/etc/default/grub" || echo 'GRUB_TIMEOUT_STYLE=menu' >> "$MNT/etc/default/grub"
ok "Backup saved to /etc/default/grub.bak-repair"

# ---------- 4) update-grub + clear recordfail ----------
say "Running update-grub"
chroot "$MNT" /bin/bash -c "update-grub"
chroot "$MNT" /bin/bash -c "grub-editenv - unset recordfail" 2>/dev/null || true

# ---------- Verify ----------
say "Verification"
if lsinitramfs "$MNT/boot/initrd.img-$HEALTHY_KERNEL" | grep -q 'vmd\.ko'; then
  ok "initrd for $HEALTHY_KERNEL contains vmd → SSD will be visible at boot"
else
  die "vmd still missing from initrd — do NOT reboot; investigate further."
fi
grep -q "gnulinux-${HEALTHY_KERNEL}-advanced" "$MNT/boot/grub/grub.cfg" \
  && ok "GRUB default entry points at $HEALTHY_KERNEL"

say "SUCCESS — remove the USB and reboot. Ubuntu should boot into $HEALTHY_KERNEL."
echo "  After you're in the desktop, see README.md → 'Deep learning without breaking the system again'."
