#!/bin/bash
#
# Monolithic Performance Tuning & SSH Hardening Script for Debian-based Systems
# Version: v5-confirm (verbose + sshd dep locked + THP runtime + udevadm path + CPU gov select + extras)
#

set -euo pipefail

# -------- Logging --------
_ts() { date '+%F %T'; }
log()   { printf '[%s] [%s] %s\n' "$(_ts)" "$1" "$2"; }
info()  { log "INFO" "$*"; }
warn()  { log "WARN" "$*" >&2; }
ok()    { log "OK"   "$*"; }
fail()  { log "ERR"  "$*" >&2; }

trap 'rc=$?; fail "Script aborted (exit $rc) at: ${BASH_COMMAND}"; exit $rc' ERR

confirm() {
  read -rp "$1 [y/N]: " response
  [[ "$response" =~ ^[Yy]$ ]]
}

# Resolve udevadm path (Debian/Ubuntu: /usr/bin/udevadm)
UDEVADM_BIN="$(command -v udevadm 2>/dev/null || echo /usr/bin/udevadm)"

# -------- Pre-flight --------

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run as root. Please use sudo."
    exit 1
  fi
  ok "Running as root"
}

check_dependencies() {
  info "Checking dependencies (ethtool, iproute2, openssh-server, udevadm)..."
  missing_pkgs=()
  if ! command -v ethtool >/dev/null 2>&1; then
    missing_pkgs+=("ethtool"); warn "Missing: ethtool"
  fi
  if ! command -v ip >/dev/null 2>&1; then
    missing_pkgs+=("iproute2"); warn "Missing: iproute2"
  fi
  if ! command -v sshd >/dev/null 2>&1; then
    missing_pkgs+=("openssh-server"); warn "Missing: openssh-server (sshd)"
  fi
  if ! command -v udevadm >/dev/null 2>&1; then
    warn "udevadm not found in PATH; assuming ${UDEVADM_BIN}"
  else
    ok "udevadm: $(command -v udevadm)"
  fi
  if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    info "Packages required: ${missing_pkgs[*]}"
    read -rp "Install required packages via apt now? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      info "Installing: ${missing_pkgs[*]}"
      apt-get update
      apt-get install -y "${missing_pkgs[@]}"
      ok "Dependencies installed"
    else
      fail "Cannot proceed without required packages."
      exit 1
    fi
  else
    ok "All dependencies present"
  fi
}

# -------- Profiles --------

set_profile_auto() {
  export PROFILE="auto"
  export TCP_CC="bbr"
  export QDISC="fq"
  export SYSCTL_SETTINGS=(
    "net.core.netdev_max_backlog=32768"
    "net.core.somaxconn=16384"
    "net.ipv4.tcp_mtu_probing=1"
  )
  ok "Profile set: auto (BBR/fq)"
}

set_profile_lan_low_latency() {
  export PROFILE="lan_low_latency"
  export TCP_CC="cubic"
  export QDISC="fq_codel"
  export SYSCTL_SETTINGS=(
    "net.ipv4.tcp_low_latency=1"
    "net.ipv4.tcp_wmem=4096 16384 4194304"
    "net.ipv4.tcp_rmem=4096 87380 6291456"
    "net.core.netdev_max_backlog=16384"
    "net.core.somaxconn=8192"
  )
  ok "Profile set: lan_low_latency (cubic/fq_codel)"
}

set_profile_wan_throughput() {
  export PROFILE="wan_throughput"
  export TCP_CC="bbr"
  export QDISC="fq"
  export SYSCTL_SETTINGS=(
    "net.core.rmem_max=16777216"
    "net.core.wmem_max=16777216"
    "net.ipv4.tcp_rmem=4096 131072 16777216"
    "net.ipv4.tcp_wmem=4096 16384 16777216"
    "net.ipv4.tcp_mtu_probing=1"
    "net.core.netdev_max_backlog=32768"
    "net.core.somaxconn=16384"
  )
  ok "Profile set: wan_throughput (BBR/fq)"
}

set_profile_datacenter_10g() {
  export PROFILE="datacenter_10g"
  export TCP_CC="bbr"
  export QDISC="fq"
  export SYSCTL_SETTINGS=(
    "net.core.rmem_max=33554432"
    "net.core.wmem_max=33554432"
    "net.ipv4.tcp_rmem=4096 262144 33554432"
    "net.ipv4.tcp_wmem=4096 32768 33554432"
    "net.core.netdev_max_backlog=65536"
    "net.core.somaxconn=65536"
    "net.ipv4.tcp_timestamps=1"
    "net.ipv4.tcp_fastopen=3"
  )
  ok "Profile set: datacenter_10g (BBR/fq)"
}

select_profile() {
  echo "Select a performance profile:"
  select choice in "auto" "lan_low_latency" "wan_throughput" "datacenter_10g"; do
    case $choice in
      auto) set_profile_auto; break ;;
      lan_low_latency) set_profile_lan_low_latency; break ;;
      wan_throughput) set_profile_wan_throughput; break ;;
      datacenter_10g) set_profile_datacenter_10g; break ;;
      *) warn "Invalid choice."; continue ;;
    esac
  done
  info "Selected profile: ${PROFILE} (qdisc=$QDISC, cc=$TCP_CC)"
}

# -------- Storage readahead profile (SSD/NVMe) --------

choose_storage_ra_profile() {
  echo "Select storage readahead profile (SSD/NVMe):"
  PS3="Choose: "
  select ra in "OLTP (16K)" "Mixed (32K)" "Bulk (64K)"; do
    case "$ra" in
      "OLTP (16K)") export SSD_RA_KB=16  NVME_RA_KB=16;  ok "Storage RA: OLTP (16K)"; break ;;
      "Mixed (32K)") export SSD_RA_KB=32 NVME_RA_KB=32; ok "Storage RA: Mixed (32K)"; break ;;
      "Bulk (64K)") export SSD_RA_KB=64  NVME_RA_KB=64;  ok "Storage RA: Bulk (64K)"; break ;;
      *) warn "Invalid choice."; continue ;;
    esac
  done
}

# -------- CPU governor selection --------

choose_cpu_governor() {
  local govfile="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
  local govs=""
  if [ -r "$govfile" ]; then
    read -r govs < "$govfile"
  else
    govs="performance powersave schedutil ondemand conservative"
    warn "Could not read $govfile; falling back to common governors: $govs"
  fi

  echo "Available CPU governors: $govs"
  IFS=' ' read -r -a GOV_ARRAY <<< "$govs"
  PS3="Select CPU governor: "
  select g in "${GOV_ARRAY[@]}"; do
    if [[ -n "${g:-}" ]]; then
      export CPU_GOV="$g"
      ok "CPU governor selected: $CPU_GOV"
      break
    else
      warn "Invalid choice."
    fi
  done
}

# -------- Steps --------

apply_sysctl() {
  info "Applying sysctl..."
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-perf-base.conf <<'EOF'
vm.swappiness=1
vm.overcommit_memory=1
kernel.kptr_restrict=2
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
vm.vfs_cache_pressure=50
vm.dirty_background_bytes=67108864
vm.dirty_bytes=536870912
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500
vm.max_map_count=262144
fs.file-max=2097152
kernel.sched_autogroup_enabled=0
kernel.sched_migration_cost_ns=5000000
EOF

  CONF_FILE="/etc/sysctl.d/98-perf-profile.conf"
  {
    echo "# Profile: $PROFILE"
    echo "net.core.default_qdisc = $QDISC"
    echo "net.ipv4.tcp_congestion_control = $TCP_CC"
    for s in "${SYSCTL_SETTINGS[@]}"; do echo "$s"; done
  } > "$CONF_FILE"

  sysctl --system > /dev/null
  ok "Sysctl applied"
}

apply_zfs_arc_limits() {
  info "ZFS tuning wizard (ARC size optional + prefetch disable)"
  mkdir -p /etc/modprobe.d

  echo "Choose ARC limit mode:"
  echo "  1) No ARC limits (only disable prefetch)"
  echo "  2) Set ARC max only (recommended for OLTP/Redis)"
  echo "  3) Set ARC min & max"
  echo "  4) Pin ARC (min = max)  [advanced]"
  local mode
  while true; do
    read -rp "Select 1-4 [default 2]: " mode
    mode="${mode:-2}"
    [[ "$mode" =~ ^[1-4]$ ]] && break
    warn "Invalid selection. Enter 1, 2, 3, or 4."
  done

  # Defaults you used previously
  local MAX_GB=6
  local MIN_GB=2

  case "$mode" in
    1)
      info "ARC limits will NOT be set; only prefetch will be disabled."
      unset ARC_MAX_B ARC_MIN_B
      ;;
    2)
      read -rp "ARC max (GiB) [default ${MAX_GB}]: " ans
      MAX_GB="${ans:-$MAX_GB}"
      ARC_MAX_B=$((MAX_GB*1024*1024*1024))
      unset ARC_MIN_B
      info "Selected: ARC max only (${MAX_GB} GiB)"
      ;;
    3)
      read -rp "ARC max (GiB) [default ${MAX_GB}]: " ans
      MAX_GB="${ans:-$MAX_GB}"
      read -rp "ARC min (GiB) [default ${MIN_GB}]: " ans2
      MIN_GB="${ans2:-$MIN_GB}"
      ARC_MAX_B=$((MAX_GB*1024*1024*1024))
      ARC_MIN_B=$((MIN_GB*1024*1024*1024))
      info "Selected: ARC min=${MIN_GB} GiB, max=${MAX_GB} GiB"
      ;;
    4)
      read -rp "Fixed ARC size (GiB) to pin (min=max) [default ${MAX_GB}]: " ans
      MAX_GB="${ans:-$MAX_GB}"
      ARC_MAX_B=$((MAX_GB*1024*1024*1024))
      ARC_MIN_B=$ARC_MAX_B
      warn "Pinning ARC at ${MAX_GB} GiB (min=max). Ensure memory headroom for MySQL/Redis!"
      ;;
  esac

  # Write module options
  local conf="/etc/modprobe.d/zfs-tuning.conf"
  {
    echo "options zfs zfs_prefetch_disable=1"
    if [ -n "${ARC_MAX_B:-}" ]; then
      echo "options zfs zfs_arc_max=${ARC_MAX_B}"
    fi
    if [ -n "${ARC_MIN_B:-}" ]; then
      echo "options zfs zfs_arc_min=${ARC_MIN_B}"
    fi
  } > "$conf"

  ok "Wrote ${conf}"
  update-initramfs -u
  ok "Initramfs updated (reboot to apply module options)"

  # Helpful summary
  if [ -n "${ARC_MAX_B:-}" ]; then
    info "ARC max set to $((ARC_MAX_B/1024/1024/1024)) GiB"
  else
    info "ARC max: not set (kernel default/auto)"
  fi
  if [ -n "${ARC_MIN_B:-}" ]; then
    info "ARC min set to $((ARC_MIN_B/1024/1024/1024)) GiB"
  else
    info "ARC min: not set (will float low)"
  fi

  info "Tip: you can also adjust at runtime (until reboot) via:"
  info "  echo <bytes> > /sys/module/zfs/parameters/zfs_arc_max"
  info "  echo <bytes> > /sys/module/zfs/parameters/zfs_arc_min"
}


apply_nic_tuning() {
  info "Configuring NIC coalescing (service-driven)..."
  mkdir -p /usr/local/sbin /etc/default
  echo "PROFILE=${PROFILE}" > /etc/default/perf-tuning

  cat > /usr/local/sbin/tune-nic.sh <<'EOF'
#!/bin/bash
set -eu
[ -f /etc/default/perf-tuning ] && source /etc/default/perf-tuning
PROFILE=${PROFILE:-auto}
declare -A PROFILES
PROFILES["lan_low_latency"]="adaptive-rx off;adaptive-tx off;rx-usecs 25;tx-usecs 25"
PROFILES["datacenter_10g"]="adaptive-rx on;adaptive-tx on"
PROFILES["auto"]="adaptive-rx on;adaptive-tx on"
PROFILES["wan_throughput"]="adaptive-rx on;adaptive-tx on"
tune_one() {
  local ifc="$1"
  local settings="${PROFILES[$PROFILE]}"
  IFS=';' read -ra pairs <<< "$settings"
  for pair in "${pairs[@]}"; do ethtool -C "$ifc" $pair 2>/dev/null || true; done
  if [ "$PROFILE" = "datacenter_10g" ]; then
    read -r rx tx < <(ethtool -g "$ifc" | awk '/^RX:/{r=$2} /^TX:/{print r, $2}')
    [ "${rx:-}" ] && ethtool -G "$ifc" rx "$rx" tx "$tx" 2>/dev/null || true
  fi
}
for i in $(ls /sys/class/net | grep -E '^(en|eth)'); do
  [ "$(cat /sys/class/net/$i/operstate)" = "up" ] && tune_one "$i"
done
EOF
  chmod +x /usr/local/sbin/tune-nic.sh

  cat > /etc/systemd/system/tune-nic.service <<'EOF'
[Unit]
Description=Apply NIC Tuning
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tune-nic.sh
[Install]
WantedBy=multi-user.target
EOF

  /usr/local/sbin/tune-nic.sh
  ok "NIC coalescing applied (and service installed)"
}

# Persistent udev I/O + NIC rules, CPU governor oneshot
apply_io_and_cpu_sched() {
  info "Configuring I/O scheduler & read-ahead (udev), NIC txqueuelen (udev), and CPU governor..."

  SSD_RA_KB=${SSD_RA_KB:-16}
  NVME_RA_KB=${NVME_RA_KB:-16}
  CPU_GOV=${CPU_GOV:-performance}
  info "Storage readahead: SSD=${SSD_RA_KB} KB, NVMe=${NVME_RA_KB} KB; CPU governor=${CPU_GOV}"

  # Storage udev rules
  : > /etc/udev/rules.d/60-ssd-scheduler.rules
  echo 'ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"' >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo "ACTION==\"add|change\", KERNEL==\"sd[a-z]\", ATTR{queue/rotational}==\"0\", ATTR{bdi/read_ahead_kb}=\"${SSD_RA_KB}\"" >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo 'ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"' >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo 'ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/add_random}="0"' >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo 'ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{bdi/read_ahead_kb}="512", ATTR{queue/scheduler}="mq-deadline"' >> /etc/udev/rules.d/60-ssd-scheduler.rules

  echo 'ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"' >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo "ACTION==\"add|change\", KERNEL==\"nvme[0-9]n[0-9]\", ATTR{bdi/read_ahead_kb}=\"${NVME_RA_KB}\"" >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo 'ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rq_affinity}="2"' >> /etc/udev/rules.d/60-ssd-scheduler.rules
  echo 'ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/add_random}="0"' >> /etc/udev/rules.d/60-ssd-scheduler.rules
  ok "Wrote /etc/udev/rules.d/60-ssd-scheduler.rules"

  # NIC udev rules (txqueuelen only; no global MTU)
  : > /etc/udev/rules.d/99-nic-tuning.rules
  while IFS= read -r DEV; do
    DEVRANGE="$(echo "$DEV" | sed 's/[0-9]/[0-9]/g')"
    echo "KERNEL==\"$DEVRANGE\", RUN+=\"/sbin/ip link set %k txqueuelen 256\"" >> /etc/udev/rules.d/99-nic-tuning.rules
  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|veth)')
  echo 'KERNEL=="tun[0-9]*", RUN+="/sbin/ip link set %k txqueuelen 256"' >> /etc/udev/rules.d/99-nic-tuning.rules
  echo '# KERNEL=="ppp[0-9]*", RUN+="/sbin/ip link set %k mtu 1492"' >> /etc/udev/rules.d/99-nic-tuning.rules
  ok "Wrote /etc/udev/rules.d/99-nic-tuning.rules"

  # Apply udev changes now
  "$UDEVADM_BIN" control --reload-rules
  "$UDEVADM_BIN" trigger
  ok "udev rules reloaded and triggered"

  # CPU governor now + persist via oneshot
  info "Setting CPU governor to ${CPU_GOV} (now and via systemd)..."
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "${CPU_GOV}" > "$g" 2>/dev/null || true
  done
  cat > /etc/systemd/system/cpu-governor.service <<EOF
[Unit]
Description=Set CPU governor to ${CPU_GOV}

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo ${CPU_GOV} > "$g" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cpu-governor.service
  ok "CPU governor service installed and executed (governor=${CPU_GOV})"
}

# Transparent Huge Pages runtime toggle (no GRUB edit)
apply_thp_runtime() {
  info "Setting Transparent Huge Pages to 'never' (runtime + persistent service)..."
  if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  else
    warn "THP 'enabled' path not writable or missing"
  fi
  if [ -w /sys/kernel/mm/transparent_hugepage/defrag ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  else
    warn "THP 'defrag' path not writable or missing"
  fi
  cat > /etc/systemd/system/thp-toggle.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (runtime)

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
  [ -w /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true;
  [ -w /sys/kernel/mm/transparent_hugepage/defrag ] && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true;
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thp-toggle.service
  ok "THP disabled at runtime and persisted via systemd (no GRUB edit)"
}

apply_limits() {
  info "Setting ulimit values..."
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-perf.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  ok "nofile limits configured"
}

apply_ssh_hardening() {
  info "Applying SSH hardening..."
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
Protocol 2
PasswordAuthentication no
PermitRootLogin prohibit-password
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF
  if sshd -t; then
    systemctl reload ssh
    ok "sshd config validated and reloaded"
  else
    warn "sshd -t failed; not reloading to avoid lockout"
  fi
}

set_grub_ipv6_disable() {
  info "Ensuring ipv6.disable=1 in GRUB..."
  if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 ipv6.disable=1"/' /etc/default/grub
    update-grub
    ok "GRUB updated to disable IPv6"
  else
    ok "GRUB already disables IPv6"
  fi
}

# -------- NEW: Minimal-complexity extras --------

apply_energy_perf_bias() {
  info "Setting Energy-Performance Bias to 'performance' (0) across CPUs..."
  local count=0
  for f in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
    [ -e "$f" ] || continue
    echo 0 > "$f" 2>/dev/null || true
    count=$((count+1))
  done
  if [ "$count" -eq 0 ]; then
    warn "energy_perf_bias not exposed on this platform (Intel-only typically); skipping runtime set"
  else
    ok "Set energy_perf_bias=0 on $count CPUs"
  fi

  # Persist via oneshot service (best effort)
  cat > /etc/systemd/system/energy-perf-bias.service <<'EOF'
[Unit]
Description=Set CPU energy_performance_bias to performance (0)

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
count=0
for f in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
  [ -e "$f" ] || continue
  echo 0 > "$f" 2>/dev/null || true
  count=$((count+1))
done
echo "Set energy_perf_bias=0 on $count CPU(s)"
'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now energy-perf-bias.service 2>/dev/null || true
  ok "Energy-Perf-Bias oneshot installed (best effort)"
}

apply_keepalives() {
  info "Applying TCP keepalive sysctls..."
  cat > /etc/sysctl.d/95-keepalives.conf <<'EOF'
# Conservative TCP keepalive defaults for long-lived app/db connections
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF
  sysctl --system >/dev/null
  ok "TCP keepalives applied"
}

apply_tmp_tmpfs() {
  info "Configuring /tmp as tmpfs via systemd tmp.mount..."
  read -rp "Enter size for /tmp (e.g., 2G, 4G) [default: 2G]: " TMP_SIZE
  TMP_SIZE="${TMP_SIZE:-2G}"
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/tmp.mount <<EOF
[Unit]
Description=Temporary Directory (/tmp)
Documentation=man:hier(7)
Before=local-fs.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,size=${TMP_SIZE}

[Install]
WantedBy=local-fs.target
EOF
  systemctl daemon-reload
  systemctl enable --now tmp.mount
  ok "/tmp mounted as tmpfs (size=${TMP_SIZE})"
}

apply_journald_volatile() {
  info "Configuring systemd-journald to use RAM (volatile storage)..."
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=256M
RuntimeKeepFree=64M
# Feel free to adjust the above caps to your environment.
EOF
  systemctl restart systemd-journald
  ok "journald set to RAM (volatile). Logs won't persist across reboot."
}

# -------- Main --------

main() {
  check_root
  check_dependencies
  select_profile
  choose_storage_ra_profile
  choose_cpu_governor

  echo ""
  echo "==== Confirm Each Step ===="

  if confirm "Apply sysctl profile settings?"; then apply_sysctl; else info "Sysctl: skipped"; fi
  if confirm "Apply ZFS ARC + prefetch tuning?"; then apply_zfs_arc_limits; else info "ZFS: skipped"; fi
  if confirm "Apply NIC coalescing and ring tuning (service)?"; then apply_nic_tuning; else info "NIC coalescing: skipped"; fi
  if confirm "Apply IO scheduler (udev) + CPU governor tuning?"; then apply_io_and_cpu_sched; else info "I/O + CPU: skipped"; fi
  if confirm "Disable Transparent Huge Pages (runtime + persistent service)?"; then apply_thp_runtime; else info "THP: skipped"; fi
  if confirm "Apply ulimit increases?"; then apply_limits; else info "Limits: skipped"; fi
  if confirm "Apply SSH hardening?"; then apply_ssh_hardening; else info "SSH hardening: skipped"; fi
  if confirm "Disable IPv6 via GRUB?"; then set_grub_ipv6_disable; else info "GRUB IPv6: skipped"; fi

  # ---- New minimal-complexity extras ----
  if confirm "Set CPU Energy-Performance Bias to performance (0) now and on boot?"; then apply_energy_perf_bias; else info "Energy-Perf-Bias: skipped"; fi
  if confirm "Apply TCP keepalives (time=300s, intvl=30s, probes=5)?"; then apply_keepalives; else info "Keepalives: skipped"; fi
  if confirm "Mount /tmp as tmpfs (RAM) via systemd?"; then apply_tmp_tmpfs; else info "/tmp tmpfs: skipped"; fi
  if confirm "Make journald use RAM (volatile) with a 256M cap?"; then apply_journald_volatile; else info "journald RAM: skipped"; fi

  echo ""
  ok "All selected changes applied. Reboot recommended for mount/grub/kernel settings."
}

main
