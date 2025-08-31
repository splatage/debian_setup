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
curl https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/debian_zfs_install.sh | bash
```

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
