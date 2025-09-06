# Debian Setup Monorepo — Operational Guide

## Index
- [Overview](#overview)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Install Order (Quick Start)](#install-order-quick-start)
- [1) ZFS Root Installer (`debian_zfs_install.sh`)](#1-zfs-root-installer-debian_zfs_installsh)
- [2) MariaDB Cluster Controller (`mariadb_cluster_controller.sh`)](#2-mariadb-cluster-controller-mariadb_cluster_controllersh)
- [3) MariaDB Server Config (`mariadbconf`)](#3-mariadb-server-config-mariadbconf)
- [4) Performance Tuning & Hardening (`perf-tune-hardening.sh`)](#4-performance-tuning--hardening-perf-tune-hardeningsh)
- [5) Fan Control Service (`fan_temp_service.sh`)](#5-fan-control-service-fan_temp_servicesh)
- [Operations & Maintenance](#operations--maintenance)
- [Troubleshooting](#troubleshooting)
- [Scope & Progress](#scope--progress)
- [License](#license)

---

## Overview
This repository contains a small, focused toolchain to provision and operate Debian servers for ZFS-root installs, MariaDB primary/replica clusters, baseline performance tuning, and a simple fan-control service via IPMI. It reflects a single-file, self‑contained philosophy—no multi-file installers or undocumented behavior.

**What this README does:** documents how to use each script and config safely, in a sensible order, with copy/paste commands.  
**What it does not do:** invent new features, modify logic, or restructure code.

## Repository Layout
```
/debian_setup-main/
├─ README.md                              # legacy readme (kept for history; superseded by this guide)
├─ debian_zfs_install.sh                  # ZFS-root Debian installer
├─ mariadb_cluster_controller.sh          # MariaDB primary/replica controller (SSH-based)
├─ mariadb.conf                           # MariaDB server config (copy to target hosts)
├─ perf-tune-hardening.sh                 # System performance tuning & optional SSH hardening
└─ fan_temp_service.sh                    # Installs fan_control.sh + systemd service
```

> Note: `mariadb_setup.md` is **legacy** and can be ignored/removed. Its logic is superseded by `mariadb_cluster_controller.sh` (per user direction).

## Prerequisites
- **OS:** Debian Bookworm preferred (scripts target Debian-family).  
- **Privileges:** Run as `root` (or with `sudo`).  
- **Network:** Stable LAN, SSH reachability to all nodes.  
- **SSH:** Controller has key-based access to *all* database hosts as `root` (required by the cluster controller).  
- **Disks:** For ZFS-root, at least one disk visible via `lsblk` (NVMe/SATA/SAS).  
- **Firmware:** UEFI supported for ZFS boot; ensure BIOS is set appropriately.

## Install Order (Quick Start)
0. (Optional) Apply performance tuning **after** base OS is installed.
1. **Provision OS with ZFS root** on each node: run `debian_zfs_install.sh` locally on the target host (destructive to selected disks).
2. **Tune system** with `perf-tune-hardening.sh` (optional but recommended).
3. **Install MariaDB** on intended DB hosts; copy `mariadb.conf` onto each host (path below), then use `mariadb_cluster_controller.sh` from a controller to orchestrate primary/replicas.
4. **Install fan control service** on hardware that supports IPMI and coretemp sensors.

---

## 1) ZFS Root Installer (`debian_zfs_install.sh`)
**Purpose:** Interactive, destructive installer that prepares ZFS root and completes Debian base setup.

**Boot into a debian live installer. Run on the target machine (as root):**

To enable ssh access:
```sudo su -
password <add a temp root password>
apt update
apt install openssh-server
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
systemctl restart sshd
```

Either via ssh or the shell:

```
apt install curl
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/debian_zfs_install.sh
bash debian_zfs_install.sh 
```

**What it does (observed from script):**
- Updates apt sources and installs: `debootstrap`, `gdisk`, `zfsutils-linux`, `grub2`.
- Detects disks via `lsblk`; offers selection menu.
- Partitions selected disks, creates EFI partition, creates ZFS pools and datasets for root/boot.
- Bootstraps Debian into `/mnt`, writes a chroot helper, then chroots to complete configuration (GRUB, packages, users as defined by script prompts).
- Exits chroot and finishes.

**Important notes:**
- **Destructive:** Will repartition selected disks. Have backups.
- **UEFI/EFI partitioning:** Script provisions EFI partition and installs GRUB accordingly.
- If disk auto-detection fails, script attempts an alternate `lsblk` path.
- If you encounter shutdown hangs with EFI unmount: ensure EFI mount is not busy; check for open files and `systemd` mount units. (See Troubleshooting.)

**Post‑install sanity:**
```bash
zpool status
zfs list
lsblk -f
```

---

## 2) MariaDB Cluster Controller (`mariadb_cluster_controller.sh`)
**Purpose:** Orchestrates a primary with one or more replicas via SSH from a controller/bastion. Uses streaming backup/restore and replication reconfiguration.

**Run from a controller host that has key-based root SSH to all DB nodes:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/mariadb_cluster_controller.sh
bash mariadb_cluster_controller.sh
```

**Capabilities (from script review):**
- Provisions primary and replicas remotely via SSH as `root` (expects `mariadb` CLI on hosts).
- Streams a backup from primary directly into each replica via an SSH-to-SSH pipe (avoids controller disk temp usage).
- Configures replication (GTID mode enabled in the sample `mariadb.conf`).
- Supports promotion and re-pointing replicas after a failover (promote replica → reconfigure others to follow it).

**Expectations / Inputs:**
- Variables such as `PRIMARY_IP`, `REPLICA_IPS`, `SSH_USER` (if present) must be set *as per the script’s prompts or inline config*. Ensure DNS or `/etc/hosts` resolves all nodes.
- Root access via SSH is mandatory (passwordless).

**Operational flow (high level):**
1. Verify reachability to all nodes (primary/replicas).
2. Prepare MariaDB on each node (packages, service, directories).
3. On primary: ensure binary logging & GTID; take backup.
4. For each replica: stream restore, configure `CHANGE MASTER TO ...`, `START SLAVE`.
5. Validate `SHOW SLAVE STATUS\G` on each replica.

**Promotion scenario (observed logic):**
- Stop I/O/SQL threads on former primary.
- Promote a replica.
- Point other replicas at the promoted host; verify status.

> Tip: Keep production-safe values for durability (e.g., `innodb_flush_log_at_trx_commit=1` and `sync_binlog=1`) if you need crash-safety. The provided `mariadb.conf` is tuned for performance; adjust per risk tolerance.

---

## 3) MariaDB Server Config Template (`mariadb.conf`) 
> Already installed by the mariadb_cluster_controller.sh

**Purpose:** Baseline MariaDB tuning including GTID replication and InnoDB parameters. Adjust sizes to your RAM and workload.

**Install on each MariaDB host:**
```bash
# Example destination; confirm path matches your distro
install -m 0644 mariadb.conf /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb
```

**Highlights (from file):**
- `gtid_strict_mode=ON`, `binlog_format=ROW`, `binlog_row_image=FULL`
- `innodb_flush_log_at_trx_commit=2`, `sync_binlog=0` (performance-tilted; trade durability for speed)
- Large `innodb_log_file_size` (4G) and `innodb_buffer_pool_size` (set to 16G in the sample)
- Other InnoDB tunables: `innodb_io_capacity`, `innodb_lru_scan_depth`, etc.

**Adjustments you may consider:**
- `innodb_buffer_pool_size` to ~50–70% of system RAM for dedicated DB hosts and ideally larger than the dataset.
- Durability knobs (`innodb_flush_log_at_trx_commit`, `sync_binlog`) for crash safety vs throughput.

---

## 4) Performance Tuning & Hardening (`perf-tune-hardening.sh`)
**Purpose:** Applies system-level performance tuning and optional SSH hardening. Interactive and idempotent.

**Usage (from header):**
```bash
# Interactive install
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/perf-tune-hardening.sh
bash perf-tune-hardening.sh

**What it configures (per script body):**
- Writes defaults to `/etc/default/perf-tuning`
- Installs helper(s) under `/usr/local/sbin/` and systemd unit(s) as needed
- Tunes sysctl (TCP buffers, queueing), NIC/RPS, scheduler hints, and more
- Optional SSH hardening (keys, ciphers/MACs) when enabled

**Removal:**
```bash
sudo bash perf-tune-hardening.sh --uninstall
```

---

## 5) Fan Control Service (`fan_temp_service.sh`)
**Purpose:** Installs a minimal fan control script and a systemd service that reads CPU temps (via `coretemp` in `/sys`) and sets fan speeds via IPMI.

**Run (as root) on the target machine:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/fan_temp_service.sh
bash fan_temp_service.sh
```

**What it installs:**
- `/usr/local/sbin/fan_control.sh` — simple temp→duty algorithm (no smoothing)
- `/etc/default/fan-control` — thresholds and IPMI target hex codes (edit as needed)
- `/etc/systemd/system/fan-control.service` — service unit

**Manage:**
```bash
systemctl status fan-control
journalctl -u fan-control -e
```

**Notes:**
- Requires working `ipmitool` and accessible BMC.
- Only `coretemp` sensors are read; if sensors differ, extend the script (out of scope here).

---

## Operations & Maintenance
- **Backups:** Use your existing backup workflows; the cluster controller streams backups during provisioning. For periodic backups, use `mariadb-backup`/`xtrabackup` or logical dumps as appropriate.
- **Monitoring:** Track `SHOW SLAVE STATUS\G` on replicas; export metrics to your stack.
- **Upgrades:** Apply on replicas first where safe; validate, then failover and upgrade former primary if required.
- **ZFS:** Monitor `zpool status`, scrubs, and SMART for underlying devices.

## Troubleshooting
- **EFI partition couldn't be unmounted during shutdown (hang):**
  - Ensure no processes are holding files open under `/boot/efi` (e.g., shells, editors).
  - Check `systemd` mounts: `systemctl list-units --type=mount` and `journalctl -b -u systemd-umount`.
  - Verify `/etc/fstab` and that the EFI partition UUID matches.
- **Replication not starting:**
  - Confirm network reachability and MySQL user/permissions for replication.
  - Validate `gtid_strict_mode=ON` and `binlog_format=ROW` on primary; `SHOW VARIABLES LIKE 'gtid%';`
  - Inspect `SHOW SLAVE STATUS\G` on the replica for `Last_IO_Error` / `Last_SQL_Error`.
- **Fan control not changing speeds:**
  - Confirm `ipmitool raw` commands work manually.
  - Ensure BMC is not auto-overriding; some vendors need “manual” fan mode first.
- **ZFS install disk detection:**
  - Script falls back to alternate `lsblk` parsing; double-check device names (NVMe vs sdX).

## Scope & Progress
- **This README:** Complete coverage of current repo scripts/config with ordered flow and copy/paste commands.
- **Out of scope:** Code changes, new features, or behavioral modifications.
- **Next iteration ideas (discussion only):**
  - Add explicit `--help` handlers in scripts for self-documenting usage.
  - Ship sample systemd unit for MariaDB controller (if ever needed).

## License
If a license is present in the repo, it applies. Otherwise, all rights reserved by the repository owner.
