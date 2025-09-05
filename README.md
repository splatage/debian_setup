## Initial Bootstrap (Debian + ZFS on Root)

This script installs Debian 12 (Bookworm) directly onto ZFS with support for BIOS or UEFI boot, optional native encryption, and multiple RAID layouts.

Run it from a live Debian environment:

    curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/debian_zfs_install.sh
    bash debian_zfs_install.sh

### Features

- Full disk wipe and GPT partitioning
- Supports BIOS or UEFI boot
- Creates ZFS pools:
  - bpool (boot pool)
  - rpool (root pool)
- Optional ZFS native encryption for rpool
- Installs Debian 12 using debootstrap
- Configures systemd units for ZFS import
- Hardened SSH key-only root login
- Preinstalls useful tools (fio, wrk, iperf3, tmux, redis, etc.)

### When to run it

Run this script from a Debian live ISO or recovery environment.  
At the end, the system will be fully installed and ready to reboot into your new Debian + ZFS root environment.

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
## Post-Boot Performance Hardening

After the base system has been installed with `debian_zfs_install.sh` and the machine reboots for the first time, you can apply system-wide performance and hardening settings.

Run:

    curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/perf-tune-hardening.sh
    bash perf-tune-hardening.sh

### What this does

- Prompts for a network performance profile:
  - balanced – safe defaults
  - high-throughput – maximum RPS/XPS, larger queues
  - low-latency – reduced buffering, minimal queuing
  - custom – uses your existing /etc/default/tune-bond
- Configures sysctl tunables for networking, memory, and kernel limits
- Installs /usr/sbin/tune-bond and /usr/sbin/tune-sysctl
- Sets process limits in /etc/security/limits.d/99-perf.conf
- Deploys systemd services:
  - disable-thp.service – disables Transparent Huge Pages
  - tune-sysctl.service – ensures sysctl settings are applied
  - tune-bond.service – applies NIC bonding, RPS, and IRQ tuning
- Adds systemd overrides for:
  - redis-server.service
  - mariadb.service

### When to run it

Run this script once after the first boot on a freshly provisioned Debian system.  
It will configure and enable services to apply these settings automatically at every boot.

---

## Temp Fan Control

Server fan often react badly to non OEM hardware. This installs a service to put monitor temps and adjust fan speeds

    curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/fan_temp_service.sh
    bash fan_temp_service.sh

---

## 🧪 Development Notes

If extending the script:
- Keep structure **monolithic** for early-boot usage
- Preserve `#!/bin/bash` and strict `set -u -o pipefail`
- Avoid external dependencies beyond `coreutils`, `zfs`, `debootstrap`, and `grub`

---

## 📄 License

MIT (c) Your Name
