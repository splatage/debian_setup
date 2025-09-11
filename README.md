# Debian Setup Monorepo — Operational Guide

## Index
- [Overview](#overview)  
- [Repository Layout](#repository-layout)  
- [Prerequisites](#prerequisites)  
- [Install Order (Quick Start)](#install-order-quick-start)  
- [1) ZFS Root Installer (`debian_zfs_install.sh`)](#1-zfs-root-installer-debian_zfs_installsh)  
- [2) Network Bonding (`network_bonding`)](#2-network-bonding-network_bonding)  
- [3) MariaDB Cluster Controller (`mariadb_cluster_controller.sh`)](#3-mariadb-cluster-controller-mariadb_cluster_controllersh)  
- [4) MariaDB Server Config (`mariadb.conf`)](#4-mariadb-server-config-mariadbconf)  
- [5) Performance Tuning & Hardening (`perf-tune-hardening.sh`)](#5-performance-tuning--hardening-perf-tune-hardeningsh)  
- [6) Fan Control Service (`fan_temp_service.sh`)](#6-fan-control-service-fan_temp_servicesh)  
- [7) User Management (`users`)](#7-user-management-users)  
- [8) Prep Node.js Environment (`prep_node_env.sh`)](#8-prep-nodejs-environment-prep_node_envsh)  
- [9) Install PM2 Backend API Service (`install_pm2`)](#9-install-pm2-backend-api-service-install_pm2)  
- [10) Build Custom Kernel Image (`kernel`)](#10-build-custom-kernel-image-kernel)  
- [Operations & Maintenance](#operations--maintenance)  
- [Troubleshooting](#troubleshooting)  
- [Scope & Progress](#scope--progress)  
- [License](#license)  

---

## Overview
This repository contains a focused toolchain to provision and operate Debian servers for ZFS-root installs, MariaDB primary/replica clusters, baseline performance tuning, and a fan-control service via IPMI.  

- **This README documents** how to use each script/config in order, with copy/paste commands.  
- **It does not** invent new features, modify logic, or restructure code.  

---

## Repository Layout
```
/debian_setup-main/
├─ README.md                              # Legacy readme (superseded by this guide)
├─ debian_zfs_install.sh                  # ZFS-root Debian installer
├─ mariadb_cluster_controller.sh          # MariaDB primary/replica controller (SSH-based)
├─ mariadb.conf                           # MariaDB server config master (embedded in script)
├─ perf-tune-hardening.sh                 # System performance tuning & SSH hardening
├─ fan_temp_service.sh                    # Installs fan_control.sh + systemd service
```


---

## Prerequisites
- **OS:** Debian Bookworm preferred.  
- **Privileges:** Run as `root` (or with `sudo`).  
- **Network:** Stable LAN, SSH access to all nodes.  
- **SSH:** Controller has key-based access to DB hosts as `root`.  
- **Disks:** For ZFS root, at least one visible disk (`lsblk`).  
- **Firmware:** UEFI supported for ZFS boot.  

---

## Install Order (Quick Start)
0. (Optional) Apply performance tuning after base OS install.  
1. Provision OS with **ZFS root**: run `debian_zfs_install.sh` locally (destructive).  
2. Tune system with **perf-tune-hardening.sh**.  
3. Install **MariaDB** on DB hosts; copy `mariadb.conf`, then run `mariadb_cluster_controller.sh`.  
4. Install **fan control service** where supported.  
5. Set up **users**, **Node.js environment**, **PM2**, and optionally build a **custom kernel**.  

---

## 1) ZFS Root Installer (`debian_zfs_install.sh`)
**Purpose:** Interactive, destructive installer that prepares ZFS root and completes Debian base setup.

**Boot into a Debian live installer. Run on the target machine (as root):**

To enable ssh access:
```bash
sudo su -
passwd  # add a temp root password
apt update
apt install openssh-server
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
systemctl restart sshd
```

Either via ssh or the shell:
```bash
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

**Post-install sanity:**
```bash
zpool status
zfs list
lsblk -f
```

---

## 2) Network Bonding (`network_bonding`)
**Purpose:** To configure networking and network bonding.

Install required packages:
```bash
apt-get install ifenslave
```

Stop networking:
```bash
/etc/init.d/networking stop
```

Modify `/etc/network/interfaces`:
```bash
# /etc/network/interfaces
source /etc/network/interfaces.d/*

# Loopback
auto lo
iface lo inet loopback

# ===== Bond interface =====
auto bond0
iface bond0 inet static
    address [ip]
    netmask 255.255.255.0
    gateway 192.168.1.1
    mtu 1472
    bond-mode balance-alb
    bond-miimon 100
    bond-xmit-hash-policy layer3+4
    bond-slaves eno1 eno2 eno3 eno4

# ===== Physical slaves (no IP config) =====
allow-hotplug eno1
iface eno1 inet manual
    bond-master bond0

allow-hotplug eno2
iface eno2 inet manual
    bond-master bond0

allow-hotplug eno3
iface eno3 inet manual
    bond-master bond0

allow-hotplug eno4
iface eno4 inet manual
    bond-master bond0
```

**Edit `/etc/resolv.conf`:**
```bash
# /etc/resolv.conf
domain local.domain
search local.domain
nameserver <dns_server>
nameserver <dns_server>
```

---

## 3) MariaDB Cluster Controller (`mariadb_cluster_controller.sh`)
**Purpose:** Orchestrates a primary with one or more replicas via SSH from a controller. Uses streaming backup/restore and replication reconfiguration.

**Run from a controller host that has key-based root SSH to all DB nodes:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/mariadb_cluster_controller.sh
bash mariadb_cluster_controller.sh
```

**Capabilities:**
- Provisions primary and replicas remotely via SSH as `root` (expects `mariadb` CLI on hosts).
- Streams a backup from primary directly into each replica via an SSH-to-SSH pipe (avoids controller disk temp usage).
- Configures replication (GTID mode enabled).
- Supports promotion and re-pointing replicas after failover.

**Inputs/Expectations:**
- Variables such as `PRIMARY_IP`, `REPLICA_IPS`, `SSH_USER` must be set by prompts or inline config.
- Root SSH access is mandatory.

**Operational flow:**
1. Verify reachability to all nodes.
2. Prepare MariaDB on each node.
3. On primary: ensure binlog & GTID; take backup.
4. For each replica: stream restore, configure replication.
5. Validate replica status.

**Promotion scenario:**
- Stop I/O/SQL threads on old primary.
- Promote a replica.
- Re-point replicas to the new primary.

---

## 4) MariaDB Server Config (`mariadb.conf`) 
**Purpose:** Baseline MariaDB tuning including GTID replication and InnoDB parameters. Adjust sizes to your RAM and workload.

**Install on each MariaDB host:**
```bash
install -m 0644 mariadb.conf /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb
```

**Highlights:**
- `gtid_strict_mode=ON`, `binlog_format=ROW`, `binlog_row_image=FULL`
- `innodb_flush_log_at_trx_commit=2`, `sync_binlog=0`
- Large `innodb_log_file_size` (4G), `innodb_buffer_pool_size=16G`
- Other InnoDB tunables: `innodb_io_capacity`, `innodb_lru_scan_depth`

**Adjustments:**
- `innodb_buffer_pool_size` to 50–70% of RAM.
- Consider durability knobs for crash-safety vs speed.

---

## 5) Performance Tuning & Hardening (`perf-tune-hardening.sh`)
**Purpose:** Applies performance tuning and optional SSH hardening.

**Usage:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/perf-tune-hardening.sh
bash perf-tune-hardening.sh
```

**Configures:**
- `/etc/default/perf-tuning`
- sysctl tuning (TCP buffers, queues)
- NIC/RPS, scheduler hints
- Optional SSH hardening

**Removal:**
```bash
bash perf-tune-hardening.sh --uninstall
```

---

## 6) Fan Control Service (`fan_temp_service.sh`)
**Purpose:** Installs a fan control script and systemd service.

**Run on the target machine:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/fan_temp_service.sh
bash fan_temp_service.sh
```

**Installs:**
- `/usr/local/sbin/fan_control.sh`
- `/etc/default/fan-control`
- `/etc/systemd/system/fan-control.service`

**Manage:**
```bash
systemctl status fan-control
journalctl -u fan-control -e
```

---

## 7) User Management (`users`)
**Purpose:** To provision and enforce user key access.

```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/enforce-ssh-keys.sh
bash enforce-ssh-keys.sh
```

---

## 8) Prep Node.js Environment (`prep_node_env.sh`)
**Purpose:** Installs the Node.js environment in preparation for project deployment.

**Run:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/prep_node_env.sh
bash prep_node_env.sh --user tradebid
```

---

## 9) Install PM2 Backend API Service (`install_pm2`)
**Purpose:** Sets up PM2 cluster manager as a service.

**Run:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/pm2_service_install.sh
bash pm2_service_install.sh
```

---

## 10) Build Custom Kernel Image (`kernel`)
**Purpose:** Recompile the backports kernel for performance/security hardening.

```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/build_kernel.sh
bash build_kernel.sh
```

**Resulting packages:**
```bash
dpkg -i *.deb
update-grub
```

**Reboot and verify:**
```bash
uname -a
```

---

## Operations & Maintenance
- **Backups:** Use external backups; controller streams backups during provisioning.  
- **Monitoring:** Track replica status (`SHOW SLAVE STATUS\G`).  
- **Upgrades:** Apply on replicas first, then failover.  
- **ZFS:** Monitor `zpool status`, scrubs, and SMART.  

---

## Troubleshooting
- **EFI unmount hang:** Check open files, systemd mount units, fstab UUID.  
- **Replication not starting:** Confirm connectivity, MySQL permissions, GTID settings.  
- **Fan control not working:** Verify `ipmitool raw` commands; check BMC settings.  
- **ZFS disk detection:** Validate device names (NVMe vs sdX).  

---

## Scope & Progress
- **This README:** Complete coverage of repo scripts/config with ordered flow.  
- **Out of scope:** Code changes or new features.  
- **Ideas:** Add `--help` to scripts; systemd unit for MariaDB controller.  

---

## License
If a license is present in the repo, it applies. Otherwise, all rights reserved by the repository owner.
