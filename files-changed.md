# Files changed by the fix

All changes are made **inside the installed system** (mounted at `/mnt/root` from the Live USB during `chroot`).
Paths below are shown relative to the installed system's root (`/`).

The specific case documented here:

| Item | Value |
|---|---|
| Ubuntu version | 22.04.5 LTS (Jammy) |
| Broken kernel (default) | `6.8.0-124-generic` — pulled in by `nvidia-driver-595`, **missing `linux-modules-extra`** (1011 modules) |
| Healthy kernel (target) | `6.8.0-40-generic` — complete (6471 modules), initrd already contains `vmd` |
| Root partition / UUID | `/dev/nvme0n1p7` / `e1ca9466-6def-487b-9304-4696f72093b7` |
| EFI partition | `/dev/nvme0n1p1` |
| Storage topology | NVMe **behind Intel VMD** (PCI domain `10000:`) |
| Missing module | `vmd.ko` (`kernel/drivers/pci/controller/vmd.ko`) |

> Replace the kernel versions, partitions, and UUID with **your own** values (the scripts detect most of these for you).

---

## 1. `/etc/initramfs-tools/modules` — appended

Force the storage modules into every initramfs build. **Before** (default, all comments):

```
# List of modules that you want to include in your initramfs.
# ...
```

**After** (appended at the end):

```
# --- Fix boot: NVMe SSD behind Intel VMD (added during repair) ---
vmd
nvme
nvme_core
```

## 2. `/etc/default/grub` — modified

A backup is saved to `/etc/default/grub.bak-repair` first.

| Key | Before | After |
|---|---|---|
| `GRUB_DEFAULT` | `0` | `"gnulinux-advanced-<UUID>>gnulinux-<HEALTHY_KERNEL>-advanced-<UUID>"` |
| `GRUB_TIMEOUT_STYLE` | `hidden` | `menu` (show the menu as a safety net) |
| `GRUB_TIMEOUT` | `10` | `10` (unchanged) |

Concrete example used here:

```
GRUB_DEFAULT="gnulinux-advanced-e1ca9466-6def-487b-9304-4696f72093b7>gnulinux-6.8.0-40-generic-advanced-e1ca9466-6def-487b-9304-4696f72093b7"
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=10
```

The exact `menuentry_id_option` chain (`submenu-id>kernel-id`) is read from the generated `grub.cfg`.

## 3. Regenerated automatically (not hand-edited)

These are rebuilt by `update-initramfs` / `update-grub` after the edits above:

- `/boot/initrd.img-6.8.0-124-generic` and `/boot/initrd.img-6.8.0-40-generic` — rebuilt to include `vmd`
- `/boot/grub/grub.cfg` — regenerated so the new default takes effect
- GRUB env `recordfail` flag — cleared (`grub-editenv - unset recordfail`) so boot doesn't hang on the menu

## 4. New file created by the fix

- `/etc/default/grub.bak-repair` — backup of the original `/etc/default/grub`

---

## How to undo

Restore GRUB config and rebuild:

```bash
sudo cp /etc/default/grub.bak-repair /etc/default/grub
sudo update-grub
```

The lines appended to `/etc/initramfs-tools/modules` are harmless to keep, but if you want them gone, delete the
`vmd / nvme / nvme_core` block and run `sudo update-initramfs -u -k all`.
