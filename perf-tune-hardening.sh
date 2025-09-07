#!/bin/bash
#
# Monolithic Performance Tuning & SSH Hardening Script for Debian-based Systems
# Version: v5-confirm (final candidate)
#

set -euo pipefail

# --- Utilities ---

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo." >&2
    exit 1
  fi
}

check_dependencies() {
  if ! command -v ethtool >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    echo "Missing: ethtool or iproute2."
    read -rp "Install them via apt? [Y/n]: " choice
    if [[ ! "$choice" =~ ^[Nn]$ ]]; then
      apt-get update
      apt-get install -y ethtool iproute2
    else
      echo "Cannot proceed without dependencies." >&2
      exit 1
    fi
  fi
}

confirm() {
  read -rp "$1 [y/N]: " response
  [[ "$response" =~ ^[Yy]$ ]]
}

# --- Profiles ---

set_profile_auto() {
  export PROFILE="auto"
  export TCP_CC="bbr"
  export QDISC="fq"
  export SYSCTL_SETTINGS=(
    "net.core.netdev_max_backlog=32768"
    "net.core.somaxconn=16384"
    "net.ipv4.tcp_mtu_probing=1"
  )
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
}

select_profile() {
  echo "Select a performance profile:"
  select choice in "auto" "lan_low_latency" "wan_throughput" "datacenter_10g"; do
    case $choice in
      auto) set_profile_auto; break ;;
      lan_low_latency) set_profile_lan_low_latency; break ;;
      wan_throughput) set_profile_wan_throughput; break ;;
      datacenter_10g) set_profile_datacenter_10g; break ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

# --- Step Functions ---

apply_sysctl() {
  echo "Applying sysctl..."
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-perf-base.conf <<'EOF'
vm.swappiness=10
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
}

apply_zfs_arc_limits() {
  echo "Setting ZFS ARC limits..."
  mkdir -p /etc/modprobe.d
  cat > /etc/modprobe.d/zfs-tuning.conf <<'EOF'
options zfs zfs_arc_max=6442450944
options zfs zfs_arc_min=2147483648
EOF
  update-initramfs -u
}

apply_nic_tuning() {
  echo "Configuring NIC tuning..."
  mkdir -p /usr/local/sbin /etc/default
  echo "PROFILE=${PROFILE}" > /etc/default/perf-tuning

  cat > /usr/local/sbin/tune-nic.sh <<'EOF'
#!/bin/bash
set -eu
[ -f /etc/default/perf-tuning ] && source /etc/default/perf-tuning
PROFILE=${PROFILE:-auto}
declare -A PROFILES
PROFILES["lan_low_latency"]="adaptive-rx off;adaptive-tx off;rx-usecs 50;tx-usecs 50"
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
    [ "$rx" ] && ethtool -G "$ifc" rx "$rx" tx "$tx" 2>/dev/null || true
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
}

apply_io_and_cpu_sched() {
  echo "Setting IO elevator and CPU governor..."
  cat > /etc/systemd/system/io-cpu-tuning.service <<'EOF'
[Unit]
Description=IO elevator + CPU governor
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for d in /sys/block/*/queue/scheduler; do echo deadline > "$d" 2>/dev/null || true; done; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null || true; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now io-cpu-tuning.service
}

apply_limits() {
  echo "Setting ulimit values..."
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-perf.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
}

apply_ssh_hardening() {
  echo "Applying SSH hardening..."
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
Protocol 2
PasswordAuthentication no
PermitRootLogin prohibit-password
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF
  if sshd -t; then systemctl reload ssh; fi
}

set_grub_ipv6_disable() {
  echo "Setting ipv6.disable=1 in GRUB..."
  if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 ipv6.disable=1"/' /etc/default/grub
    update-grub
  fi
}

# --- Main ---

main() {
  check_root
  check_dependencies
  select_profile

  echo ""
  echo "==== Confirm Each Step ===="

  if confirm "Apply sysctl profile settings?"; then apply_sysctl; fi
  if confirm "Apply ZFS ARC memory limits?"; then apply_zfs_arc_limits; fi
  if confirm "Apply NIC coalescing and ring tuning?"; then apply_nic_tuning; fi
  if confirm "Apply IO elevator + CPU governor tuning?"; then apply_io_and_cpu_sched; fi
  if confirm "Apply ulimit increases?"; then apply_limits; fi
  if confirm "Apply SSH hardening?"; then apply_ssh_hardening; fi
  if confirm "Disable IPv6 via GRUB?"; then set_grub_ipv6_disable; fi

  echo -e "\n✅ All selected changes applied. Reboot recommended."
}

main
