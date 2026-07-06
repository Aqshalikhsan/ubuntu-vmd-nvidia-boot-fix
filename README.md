<div align="center">

```
██████╗  ██████╗  ██████╗ ████████╗    ██████╗ ███████╗███████╗ ██████╗██╗   ██╗███████╗
██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██╔════╝██║   ██║██╔════╝
██████╔╝██║   ██║██║   ██║   ██║       ██████╔╝█████╗  ███████╗██║     ██║   ██║█████╗
██╔══██╗██║   ██║██║   ██║   ██║       ██╔══██╗██╔══╝  ╚════██║██║     ██║   ██║██╔══╝
██████╔╝╚██████╔╝╚██████╔╝   ██║       ██║  ██║███████╗███████║╚██████╗╚██████╔╝███████╗
╚═════╝  ╚═════╝  ╚═════╝    ╚═╝       ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚══════╝
```

# Ubuntu Won't Boot After NVIDIA Install

### `UUID does not exist` → BusyBox `(initramfs)` — the Intel VMD trap

*A new HWE kernel sneaks in without its `linux-modules-extra`, the `vmd` module vanishes,*
*and your NVMe SSD becomes invisible at boot. Here's the diagnosis and the fix.*

<br>

![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Fix](https://img.shields.io/badge/status-fixed-2ea44f?style=for-the-badge&logo=checkmarx&logoColor=white)
![Shell](https://img.shields.io/badge/scripts-bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)

`Intel VMD`  ·  `NVMe`  ·  `initramfs`  ·  `chroot`  ·  `Live USB recovery`

</div>

<div align="center">

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

</div>

---

> [!WARNING]
> **TL;DR:** After `sudo ubuntu-drivers autoinstall`, Ubuntu drops to **BusyBox `(initramfs)`** with
> `Gave up waiting for root file system device` and `ALERT! UUID=... does not exist`.
> The culprit is **not** the NVIDIA driver itself — it's the **new HWE kernel** that got pulled in
> **without its `linux-modules-extra` package**, so the **`vmd`** module went missing. Because the NVMe SSD
> sits behind **Intel VMD**, without `vmd` the drive is invisible at boot → boot fails.
>
> **Fix:** boot a Live USB → `chroot` → add `vmd` to the initramfs & boot the healthy older kernel.

---

## Symptom

After rebooting, the screen stops at:

```
Gave up waiting for root file system device. Common problems:
 - Boot args (cat /proc/cmdline)
 - Check rootdelay= (did the system wait long enough?)
 - Missing modules (cat /proc/modules; ls /dev)
ALERT!  UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx does not exist. Dropping to a shell!

BusyBox v1.30.1 (Ubuntu 1:1.30.1-7ubuntu9.1) built-in shell (ash)
(initramfs)
```

- Windows (dual-boot) **still boots fine** → the **hardware & SSD are healthy**; this is purely a Linux software issue.
- It happens **after** running `sudo ubuntu-drivers autoinstall` (or otherwise installing an NVIDIA driver) and rebooting.

## Root cause

| Step | Result |
|---|---|
| `ubuntu-drivers autoinstall` installed `nvidia-driver-595` **+ a new HWE kernel** (e.g. `6.8.0-124`) | the kernel changed without you noticing |
| The matching **`linux-modules-extra-<version>`** package for the new kernel **was not installed** | the new kernel lost thousands of modules, **including `vmd`** |
| The NVMe SSD sits behind **Intel VMD** (Volume Management Device) | without the `vmd` module, the storage controller is **not recognized** |
| The new kernel became the GRUB default and booted without `vmd` | `/dev/nvme0n1pX` **never appears** → `UUID does not exist` → BusyBox |

**How to confirm your SSD is behind VMD** (from the Live USB): its sysfs device path contains a `10000:` PCI domain, e.g.:
```
/sys/devices/pci0000:00/0000:00:0e.0/pci10000:e0/10000:e0:06.2/10000:e1:00.0/nvme/nvme0/nvme0n1
                                     ^^^^^^^^^^ Intel VMD signature
```
and `lsmod | grep vmd` shows the `vmd` module loaded.

**How to confirm the new kernel's modules are incomplete:**
```bash
# compare module count: broken kernel vs healthy kernel
find /lib/modules/6.8.0-124-generic -name '*.ko*' | wc -l   # e.g. 1011  (BROKEN / incomplete)
find /lib/modules/6.8.0-40-generic  -name '*.ko*' | wc -l   # e.g. 6471  (complete)
```
A drastic difference = the `linux-modules-extra` package for that kernel is not installed.

## The fix (overview)

1. **Create an Ubuntu Live USB** (same series, e.g. 22.04) → boot **"Try Ubuntu"**.
2. Run **[`scripts/diagnose.sh`](scripts/diagnose.sh)** to confirm the diagnosis.
3. Run **[`scripts/fix-boot.sh`](scripts/fix-boot.sh)** to repair:
   - `chroot` into the installed system,
   - add `vmd`, `nvme`, `nvme_core` to `/etc/initramfs-tools/modules`,
   - `update-initramfs -u -k all`,
   - set the **GRUB default to the healthy older kernel** (whose modules are complete and whose initrd already contains `vmd`),
   - `update-grub`.
4. **Reboot**, remove the USB → normal desktop.

Details of every file changed: see **[files-changed.md](files-changed.md)**.

## After it boots — how to prevent this from happening again

- **Golden rule:** after installing a driver/kernel, **do NOT reboot** until you verify the new kernel's initrd contains `vmd`:
  ```bash
  lsinitramfs /boot/initrd.img-<new-kernel-version> | grep vmd   # must print vmd.ko
  ```
- Always install `linux-modules-extra-$(uname -r)` together with GPU drivers.
- **Permanent safeguard:** keeping `vmd` in `/etc/initramfs-tools/modules` (this fix does that) forces every future
  initramfs rebuild to include it — as long as the module actually exists for that kernel (i.e. `-extra` is installed).

## Deep learning without breaking the system again

- Install a **stable** system driver (e.g. `nvidia-driver-550`), not the newest/most aggressive one, and always with
  `linux-modules-extra`:
  ```bash
  sudo apt install nvidia-driver-550 linux-modules-extra-$(uname -r)
  ```
- Get **CUDA per-project via conda/pip**, not a system-wide CUDA toolkit — cleaner and conflict-free:
  ```bash
  python3 -m venv ~/dl-env && source ~/dl-env/bin/activate
  pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
  python3 -c "import torch; print(torch.cuda.is_available())"   # expect: True
  ```
- **Before rebooting** after any of the above, run the golden-rule `vmd` check.

---

## Keywords (for search / SEO)

`ubuntu gave up waiting for root file system device` · `ALERT UUID does not exist busybox` ·
`nvidia driver broke ubuntu boot` · `intel vmd nvme not detected initramfs` · `ubuntu-drivers autoinstall busybox` ·
`linux-modules-extra missing vmd` · `ubuntu 22.04 hwe kernel nvme not found` · `dropping to initramfs shell nvme ssd`

## License
[MIT](LICENSE) — free to use, modify, and share.
