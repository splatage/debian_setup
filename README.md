# Debian Setup Monorepo — Operational Guide

## Index
- [Overview](#overview)  
- [Repository Layout](#repository-layout)  
- [Prerequisites](#prerequisites)  
- [Install Order (Quick Start)](#install-order-quick-start)  
- [1) ZFS Root Installer (`debian_zfs_install.sh`)](#1-zfs-root-installer-debian_zfs_installsh)  
- [2) Network Bonding (`network_bonding`)](#2-network-bonding-network_bonding)  
- [3) MariaDB Cluster Controller (`mariadb_cluster_controller.sh`)](#3-mariadb-cluster-controller-mariadb_cluster_controllersh)  
- [4) Performance Tuning & Hardening (`perf-tune-hardening.sh`)](#4-performance-tuning--hardening-perf-tune-hardeningsh)  
- [5) Fan Control Service (`fan_temp_service.sh`)](#5-fan-control-service-fan_temp_servicesh)  
- [6) User Management (`enforce-ssh-keys.sh` + `users.keys`)](#6-user-management-enforce-ssh-keyssh--userskeys)  
- [7) Prep Node.js Environment (`prep_node_env.sh`)](#7-prep-nodejs-environment-prep_node_envsh)  
- [8) Install PM2 Backend API Service (`pm2_service_install.sh`)](#8-install-pm2-backend-api-service-pm2_service)  
- [9) Build Custom Kernel Image (`build_kernel.sh`)](#9-build-custom-kernel-image-build_kernelsh)  
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
├─ README.md
├─ debian_zfs_install.sh
├─ mariadb_cluster_controller.sh
├─ perf-tune-hardening.sh
├─ fan_temp_service.sh
├─ enforce-ssh-keys.sh
├─ users.keys
├─ prep_node_env.sh
├─ pm2_service_install.sh
└─ build_kernel.sh
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
3. Install **MariaDB** on DB hosts, then run `mariadb_cluster_controller.sh`.  
4. Install **fan control service** where supported.  
5. Set up **user keys**, **Node.js environment**, **PM2**, and optionally build a **custom kernel**.  

---

## 1) ZFS Root Installer (`debian_zfs_install.sh`)

### Details
- **Flow:** prompts for hostname → enables backports → installs `debootstrap`, `gdisk`, `grub2`, and `zfsutils-linux` (from backports) → interactive disk selection via `lsblk` → partitions with `sgdisk` (EFI or BIOS), creates **bpool** (/boot) and **rpool** (root) → creates ZFS pools with `ashift=12`, `autotrim=on`, compression `lz4`, `xattr=sa`, etc. → debootstrap into `/mnt` → chroot stage completes base config, GRUB, and users.
- **Encryption:** when selected, `rpool` is created with `-O encryption=on -O keylocation=prompt -O keyformat=passphrase` (interactive).
- **Datasets & mounts:** creates `bpool/BOOT/debian` and `rpool/ROOT/debian` (sets `canmount` appropriately) and mounts them for GRUB/initramfs steps.
- **Chroot stage highlights:** enables backports inside chroot; installs base packages (`console-setup`, `locales`), sets locale (adds `en_NZ.UTF-8`), configures SSH (`PermitRootLogin yes` in this bootstrap context), and sets GRUB `root=ZFS=rpool/ROOT/debian`.
- **GRUB & EFI:** supports BIOS or UEFI partitioning; verifies `grub-probe /boot` for ZFS.
- **Cleanup:** unmounts bind-mounts and ZFS, exports pools before exit.
- **Destructive action:** selected disks are **wiped** (`dd` and `sgdisk -Z`). Ensure backups.

**Writes/Touches:** `/etc/apt/sources.list*`, `/etc/apt/sources.list.d/debian-12-backports.list`, ZFS pools `bpool`, `rpool`, `/mnt` chroot tree, `/etc/default/grub` (inside chroot).

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

**What it does:**
- Updates apt sources and installs: `debootstrap`, `gdisk`, `zfsutils-linux`, `grub2`.
- Detects disks via `lsblk`; offers selection menu.
- Partitions selected disks, creates EFI partition, creates ZFS pools and datasets for root/boot.
- Bootstraps Debian into `/mnt`, writes a chroot helper, then chroots to complete configuration (GRUB, packages, users as defined by script prompts).
- Exits chroot and finishes.

**Important notes:**
- **Destructive:** Will repartition selected disks. Have backups.
- **UEFI/EFI partitioning:** Script provisions EFI partition and installs GRUB accordingly.
- If disk auto-detection fails, script attempts an alternate `lsblk` path.
- If you encounter shutdown hangs with EFI unmount: ensure EFI mount is not busy; check for open files and `systemd` mount units.

**Post-install sanity:**
```bash
zpool status
zfs list
lsblk -f
```

---

## 2) Network Bonding (`network_bonding`)

### Details
- This section is a **manual recipe** (no script in the repo). It installs **ifenslave** and shows an `/etc/network/interfaces` example for `bond0` in **balance-alb** mode with slaves `eno1..eno4`.
- Adjust interface names (`eno*`) to match your hardware (`ip a` / `ls /sys/class/net`).
- The example also shows a basic `/etc/resolv.conf`. Replace placeholders (`[ip]`, `<dns_server>`) with your environment.

**Purpose:** Configure networking and network bonding.

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

### Details
- **Topology:** one **Primary** + N **Replicas**, coordinated from a controller host via SSH (default `SSH_USER=root`). IPs are defined at the top of the script (`PRIMARY_IP`, `REPLICA_IP_LIST`).
- **Config templating:** The controller **generates** `/etc/mysql/mariadb.conf.d/50-server.cnf` on each node using an inline template with placeholders for role, `server-id`, and `bind-address`. Primary and Replica blocks are selectively uncommented.
- **ZFS layout on DB nodes:** The script creates (or re-creates) a pool `${ZFS_POOL_NAME}` on `${ZFS_DEVICE}` and mounts it at `${MARIADB_BASE_DIR}` (defaults: device `/dev/nvme0n1`, pool `mariadb_data`, base dir `/var/lib/mysql`). Datasets for `data` and `log` are created with sensible options (`recordsize=16k`, `compression=lz4`, `atime=off`, `logbias=throughput`). ⚠️ If a pool of that name already exists, it may be **destroyed and recreated** to ensure a clean state.
- **Packages:** installs `mariadb-server` and `mariadb-backup` (MariaDB 11.4 via `mariadb_repo_setup`).
- **Seeding & GTID:** takes a prepared backup on Primary with `mariabackup`, streams it over **ssh→ssh** tar pipe to each replica, applies `CHANGE MASTER TO ...`, and starts replication with **GTID**. Reads `mariadb_backup_binlog_info` to capture GTID.
- **Promotion:** includes a promotion flow: catch-up replicas, set old primary read-only and locked, `RESET MASTER` on promoted replica, then repoint others. Script echoes when to repoint clients.
- **Health/Status:** prints summary per node (role, threads, max connections, Seconds_Behind_Master, GTID positions).
- **Replication user:** `REPL_USER` is defined in the script; password is prompted at runtime.

**Writes/Touches (remote nodes):** `/etc/mysql/mariadb.conf.d/50-server.cnf`, ZFS pool `${ZFS_POOL_NAME}` at `${MARIADB_BASE_DIR}`, systemd `mariadb` service state during configure/seed.

**Purpose:** Orchestrates a primary with one or more replicas via SSH from a controller. Uses streaming backup/restore and replication reconfiguration.

**Run from a controller host that has key-based root SSH to all DB nodes:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/mariadb_cluster_controller.sh
bash mariadb_cluster_controller.sh
```

**Capabilities:**
- Provisions primary and replicas remotely via SSH as `root`.
- Streams a backup from primary directly into each replica via an SSH-to-SSH pipe.
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

## 4) Performance Tuning & Hardening (`perf-tune-hardening.sh`)

### Details
- **Interactive & idempotent:** asks for confirmation before each change; writes config under `/etc/` and installs simple services/units where needed.
- **Profiles:** `auto` (BBR + `fq`), `lan_low_latency`, `wan_throughput`, `datacenter_10g` — selecting congestion control and `qdisc`, and setting additive sysctls per profile.
- **Base sysctls:** writes `/etc/sysctl.d/99-perf-base.conf` and profile file `/etc/sysctl.d/98-perf-profile.conf`; reloads them explicitly.
- **NIC coalescing & rings:** optional `ethtool -C/-G` tuning via a small service; profiles control RX/TX coalescing and ring sizes when supported.
- **I/O scheduler & CPU governor:** optional udev rule for scheduler and a `cpu-governor.service` to set the desired governor.
- **Transparent Huge Pages:** runtime disable + a `thp-toggle.service` to persist across reboots.
- **NUMA basics & numad:** disables auto-balancing, sets safe sysctls, optional `numad` enablement.
- **ZFS awareness:** optional ARC/prefetch tuning helpers (paths-only; applies only if ZFS present).
- **Limits & hardening:** raises `nofile` via `/etc/security/limits.d`, optional SSH hardening (ciphers/MACs), kernel/network hardening sysctls, optional IPv6 disable via GRUB.
- **Other toggles:** irqbalance ensure/start; TCP keepalives; `/tmp` as tmpfs; journald volatile (RAM).

**Writes/Touches:** `/etc/default/perf-tuning`, `/etc/sysctl.d/98-perf-profile.conf`, `/etc/sysctl.d/99-perf-base.conf`, `/etc/systemd/system/*` (cpu-governor, thp-toggle, nic tuning), `/etc/udev/rules.d/*`, `/etc/security/limits.d/*`.

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

## 5) Fan Control Service (`fan_temp_service.sh`)

### Details
- **What it installs:** `/usr/local/sbin/fan_control.sh`, `/etc/default/fan-control`, and a systemd unit `fan-control.service`.
- **Sensors:** reads the **hottest** CPU package temperature from `/sys/class/hwmon/*` with `coretemp` (no `sensors` dependency).
- **Vendors:** `VENDOR=ibm` or `VENDOR=dell` (set in `/etc/default/fan-control`). IBM path writes per-bank using `ipmitool raw`; Dell switches to manual then sets global %. No auto-detect.
- **Control loop:** single-instance lock; computes desired duty using `BASELINE_C`, `DEADBAND_C`, `UP_GAIN`, `DOWN_GAIN`; clamps to `[MIN_PCT, MAX_PCT]`; interval via `INTERVAL` seconds.
- **Config keys (defaults file):** `INTERVAL`, `BASELINE_C`, `DEADBAND_C`, `UP_GAIN`, `DOWN_GAIN`, `MIN_PCT`, `MAX_PCT`, `VENDOR`, plus IBM-specific `IBM_BANKS` and `IBM_CODEMAP`.
- **Logs:** `journalctl -u fan-control -e` will show per-iteration temps and applied %.

**Writes/Touches:** `/usr/local/sbin/fan_control.sh`, `/etc/default/fan-control`, `/etc/systemd/system/fan-control.service`.

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

## 6) User Management (`enforce-ssh-keys.sh` + `users.keys`)

### Details
- **Source of truth:** downloads `users.keys` from the repo URL (INI-like). Sections are `[default]` and user-specific sections (e.g., `[minecraft]`). Keys under `[default]` apply to **all** users.
- **Key types accepted:** validated by regex, supports `ssh-ed25519`, `ssh-rsa`, `ecdsa`, `sk-*`, etc.
- **Behavior:** creates Linux user if missing; ensures `~/.ssh` (700) and `authorized_keys` (600); **compares** current keys vs expected and only updates on drift (prints added/removed lines with provenance).
- **Idempotent:** re-running with the same `users.keys` makes no changes (“✓ Keys already up to date”).

**Key file example:** the repo’s `users.keys` includes `[default]` and named users; only `[minecraft]` currently has an explicit ed25519 key.

**Purpose:** Enforces user SSH key access using a script and a central key file.

**Run:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/enforce-ssh-keys.sh
bash enforce-ssh-keys.sh
```

**Key file format (`users.keys`):**
```
[default]
ssh-rsa AAAAB3Nza... user@example
```

- The `[default]` section applies to all users unless overridden.  
- Place one or more public keys under each section.  
- The script provisions `authorized_keys` on the system according to this file.

---

## 7) Prep Node.js Environment (`prep_node_env.sh`)

### Details
- **Flags:** `--user <name>` (required), `--node <version>` (default `lts/*`), `--quiet`, `--help`.
- **What it does:** installs **NVM** for the target user (latest installer URL), appends a guarded profile snippet to `~/.bashrc` (marker: `<<< node-env: nvm loader >>>`), installs Node.js version requested, sets it as default, and installs `pm2` globally for that user.
- **Dependencies:** ensures `curl` (installs via `apt-get` if missing). Runs all NVM/Node steps as the target user.
- **Verification:** prints `node -v`, `npm -v`, `pm2 -v` at the end (non-fatal).

**No app deploy:** this script **does not** clone your repo or register services; it only prepares the toolchain for a given user.

**Purpose:** Installs the Node.js environment for project deployment.

**Run:**
```bash
curl -O https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/prep_node_env.sh
bash prep_node_env.sh
```

---

## 8) Install PM2 Backend API Service (`pm2_service`)

### Running the TradeBidder backend with PM2 + systemd

The backend is supervised by [PM2](https://pm2.keymetrics.io/) with a generated systemd unit for the `tradebid` user.

---

**i. Start the ecosystem (as `tradebid`)**

```bash
pm2 start ecosystem.config.cjs
pm2 startup
```

PM2 will print a command like:

```bash
sudo env PATH=$PATH:/home/tradebid/.nvm/versions/node/v22.19.0/bin \
  /home/tradebid/.nvm/versions/node/v22.19.0/lib/node_modules/pm2/bin/pm2 \
  startup systemd -u tradebid --hp /home/tradebid
```

---

**ii. Register the systemd service (as `root`)**

Run the printed command exactly, e.g.:

```bash
env PATH=$PATH:/home/tradebid/.nvm/versions/node/v22.19.0/bin \
  /home/tradebid/.nvm/versions/node/v22.19.0/lib/node_modules/pm2/bin/pm2 \
  startup systemd -u tradebid --hp /home/tradebid
```

This creates `/etc/systemd/system/pm2-tradebid.service`.

---

**iii. Save process list (as `tradebid`)**

```bash
pm2 save
```

This ensures your ecosystem restarts automatically on boot.

---

**iv. Manage the service (as `root`)**

```bash
# Check service status
systemctl status pm2-tradebid

# Follow logs in real time
journalctl -u pm2-tradebid -f
```

---

## 9) Build Custom Kernel Image (`build_kernel.sh`)

### Details
- **Kernel version marker:** `VERSION=6.12` (used for expectations; the script assumes kernel sources are available).
- **Config baseline:** writes `/usr/src/answers.cfg` with an explicit Kconfig profile emphasizing: `PREEMPT_NONE`, NUMA + sched SMT/MC, security hardening (PTI/SMEP/SMAP/KASLR/STACKPROTECTOR_STRONG/STRICT_KERNEL_RWX/etc.), IOMMU (INTEL), PCIe AER/ECRC, THP (`madvise`/HugeTLB), allocator hardening (freelist random/shuffle), LRU_GEN, NVMe/SCSI/AHCI, net stack with BPF JIT always-on/unpriv off, and EFI/EXT4.
- **Build steps:** disables debug info, ensures modules are on, runs `make olddefconfig KCONFIG_ALLCONFIG=/usr/src/answers.cfg`, then builds Debian packages via `bindeb-pkg` with a local version tag (`+tb`) and a time-based package version (`1~tbYYYYMMDD-HHMM`).
- **Artifacts:** resulting `*.deb` packages are produced in the kernel build tree (typical for `bindeb-pkg`).

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
