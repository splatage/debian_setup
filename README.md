# Debian ZFS Root Bootstrap

This script automates the installation of **Debian 12 (Bookworm)** with **ZFS on root**, supporting:

- UEFI and BIOS boot
- Encrypted or unencrypted `rpool`
- Mirror, RAIDZ1/2/3, and RAID10 layouts
- Hardened root SSH login (key-only)
- Preinstalled benchmarking and server tools

> **Warning**: This script is **destructive**. It will wipe all selected disks. Use with extreme caution.

---

## 🌀 Quick Start (Live Debian Shell)

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/zfs-debian-bootstrap/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

> Replace `YOUR_USERNAME` and branch name if different.

---

## ✅ Features

- Full disk wipe and GPT setup
- UEFI or BIOS boot partitioning
- ZFS pool creation:
  - `bpool` (boot pool)
  - `rpool` (root pool)
- Optional LUKS-style ZFS native encryption
- Debootstrap of Debian 12
- Custom systemd `zfs-import-bpool.service`
- Hardened SSH drop-in for root key-only login
- Installs: `zfs-initramfs`, `grub`, `fio`, `wrk`, `iperf3`, `tmux`, `redis`, etc.

---

## 🛡️ Security Defaults

- Root SSH access:
  - 🔐 Key-only login
  - 🔐 No password or interactive auth
- SSH daemon hardened via `/etc/ssh/sshd_config.d/`
- UFW not installed by default (manual)

---

## 🔧 Requirements

- A live Debian or rescue environment with:
  - `zfsutils-linux`
  - `debootstrap`
  - `gdisk`, `sgdisk`, `curl`, `wget`
- Internet access
- At least one block device (for single or mirrored install)

---

## 🔗 Related Files

All files are stored flat for easy `curl`-based access or embedded in heredocs:

- `bootstrap.sh` — Main installer (entrypoint)
- `root_authorized_keys` — SSH key used for root login
- `zfs-import-bpool.service` — systemd drop-in for bpool import
- `sshd_config_dropin.conf` — SSH hardening config

---

## ⚠️ Disclaimer

Use at your own risk. This script **destroys data** on selected drives and performs low-level configuration. Validate disk selection and backups before proceeding.

---

## 🧪 Development Notes

If extending the script:
- Keep structure **monolithic** for early-boot usage
- Preserve `#!/bin/bash` and strict `set -u -o pipefail`
- Avoid external dependencies beyond `coreutils`, `zfs`, `debootstrap`, and `grub`

---

## 📄 License

MIT (c) Your Name
