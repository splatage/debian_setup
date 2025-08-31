#!/bin/bash
#
# tb-perf-tuning: Monolithic Installer
#
# This script combines the functionality of the tb-perf-tuning Debian package
# into a single script for performance tuning and optional SSH hardening.
# It is designed for Debian-based systems.
#

set -euo pipefail

# --- Pre-flight Checks & Setup ---
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo." >&2
    exit 1
  fi
}

check_dependencies() {
  local missing=0
  local deps="systemctl sysctl ethtool ip awk sed grep"
  echo "Checking for required dependencies..."
  for cmd in $deps; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "  - Missing dependency: $cmd" >&2
      missing=1
    fi
  done
  if [ $missing -eq 1 ]; then
    echo "Error: Please install the missing dependencies (e.g., using 'sudo apt-get install ethtool iproute2 procps')." >&2
    exit 1
  fi
  echo "All dependencies found."
}

# --- User Interaction ---
ask_questions() {
  echo "-------------------------------------"
  echo " Performance Profile Configuration"
  echo "-------------------------------------"
  echo "Choose how aggressively to tune the network and TCP stack:"
  echo "  1) auto:           Detect link speed and tune accordingly (BBR+fq)."
  echo "  2) lan_low_latency:  Lower NIC coalescing, smaller queues (CUBIC)."
  echo "  3) wan_throughput:   Larger queues/buffers (BBR)."
  echo "  4) datacenter_10g:   Aggressive 10G+ settings."

  local choice
  while true; do
    read -rp "Select performance profile [1-4, default: 1]: " choice
    choice=${choice:-1}
    case "$choice" in
      1) PROFILE="auto"; break ;;
      2) PROFILE="lan_low_latency"; break ;;
      3) PROFILE="wan_throughput"; break ;;
      4) PROFILE="datacenter_10g"; break ;;
      *) echo "Invalid selection. Please try again." ;;
    esac
  done
  echo "Selected profile: $PROFILE"
  echo ""

  echo "-------------------------------------"
  echo " SSH Hardening (Optional)"
  echo "-------------------------------------"
  read -rp "Enable SSH hardening and add a public key? [y/N]: " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    SSH_ON="true"

    # Get user for SSH key
    local users
    users=$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | tr '\n' ' ')
    echo "Select an existing user for the SSH key install, or create a new one."
    select SSH_USER in $users "Create new user"; do
      if [ -n "$SSH_USER" ]; then break; else echo "Invalid choice."; fi
    done

    if [ "$SSH_USER" = "Create new user" ]; then
      while true; do
        read -rp "Enter the new UNIX username to create: " NEW_USER
        if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
          SSH_USER="$NEW_USER"
          break
        else
          echo "Invalid username. Use letters, digits, '-', '_'."
        fi
      done
    fi

    # Get Public Key
    echo "Paste the single-line OpenSSH-formatted public key (e.g., ssh-ed25519 ...):"
    read -rp "SSH Public Key: " SSH_PUBKEY

    # Hardening options
    read -rp "Disable password authentication in sshd? [Y/n]: " choice
    [[ "$choice" =~ ^[Nn]$ ]] && SSH_DISABLE_PASSWORD="false" || SSH_DISABLE_PASSWORD="true"

    read -rp "Disable root SSH login? [Y/n]: " choice
    [[ "$choice" =~ ^[Nn]$ ]] && SSH_DISABLE_ROOT="false" || SSH_DISABLE_ROOT="true"

  else
    SSH_ON="false"
  fi
}


# --- File Creation Functions ---

create_limits_conf() {
  echo "Creating security limits file: /etc/security/limits.d/99-perf.conf"
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-perf.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF
}

create_sysctl_files() {
  echo "Creating sysctl config files in /etc/sysctl.d/"
  mkdir -p /etc/sysctl.d

  cat > /etc/sysctl.d/97-security-hardening.conf <<'EOF'
# Security hardening
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
fs.protected_fifos = 2
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
EOF

  cat > /etc/sysctl.d/99-perf-base.conf <<'EOF'
# Base performance hints
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_timestamps = 1
EOF

  cat > /etc/sysctl.d/99-perf-memory.conf <<'EOF'
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
EOF
}

create_tune_bond_defaults() {
  echo "Creating defaults file: /etc/default/tune-bond"
  mkdir -p /etc/default
  # PROFILE is from the user prompt
  cat > /etc/default/tune-bond <<EOF
# Default tunables for tb-perf-tuning (managed)
PROFILE="${PROFILE}"
ENABLE_NIC_TUNING="true"
BOND_IF="bond0"
BOND_FORCE_MTU="false"
BOND_DESIRED_MTU="1500"
RPS_CPUMASK="auto"
RPS_FLOWS_PER_QUEUE="4096"
RX_USECS=""
TX_USECS=""
TXQUEUELEN=""
VM_DIRTY_BACKGROUND_RATIO="5"
VM_DIRTY_RATIO="20"
TCP_CC_OVERRIDE=""
DISABLE_THP="true"
LOCAL_VER_TOKEN_TTL_MS="75"
EOF
}

create_systemd_units() {
  echo "Creating systemd units in /etc/systemd/system/"
  mkdir -p /etc/systemd/system

  cat > /etc/systemd/system/tune-bond.service <<'EOF'
[Unit]
Description=Apply tb-perf-tuning NIC/bond tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tune-bond

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/tune-sysctl.service <<'EOF'
[Unit]
Description=Apply tb-perf-tuning sysctl autoprofile
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tune-sysctl

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for p in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [ -w "$p" ] && echo never > "$p" || true; done'

[Install]
WantedBy=multi-user.target
EOF

  echo "Creating systemd override files for MariaDB and Redis..."
  mkdir -p /etc/systemd/system/mariadb.service.d
  cat > /etc/systemd/system/mariadb.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
IOSchedulingPriority=2
EOF

  mkdir -p /etc/systemd/system/redis-server.service.d
  cat > /etc/systemd/system/redis-server.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
IOWeight=1000
EOF
}


create_tuning_scripts() {
  echo "Creating tuning scripts in /usr/sbin/"
  mkdir -p /usr/sbin

  # --- tune-bond script ---
  cat > /usr/sbin/tune-bond <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DEF="/etc/default/tune-bond"
# Read key="value" without sourcing (robust to stray tokens)
read_kv() {
  local key="$1" defval="$2" val
  if [ -r "$DEF" ]; then
    val="$(awk -F= -v k="^${key}=" '
      $0 ~ k {
        sub(/^[^=]+= */,"",$0); gsub(/\r/,"",$0)
        if ($0 ~ /^".*"$/) { sub(/^"/,"",$0); sub(/"$/,"",$0) }
        print $0; exit 0
      }' "$DEF")"
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  fi
  printf '%s' "$defval"
}

PROFILE="$(read_kv PROFILE auto)"
ENABLE_NIC_TUNING="$(read_kv ENABLE_NIC_TUNING true)"
BOND_IF="$(read_kv BOND_IF bond0)"
BOND_FORCE_MTU="$(read_kv BOND_FORCE_MTU false)"
BOND_DESIRED_MTU="$(read_kv BOND_DESIRED_MTU 1500)"
RPS_CPUMASK="$(read_kv RPS_CPUMASK auto)"
RPS_FLOWS_PER_QUEUE="$(read_kv RPS_FLOWS_PER_QUEUE 4096)"
RX_USECS="$(read_kv RX_USECS "")"
TX_USECS="$(read_kv TX_USECS "")"
TXQUEUELEN="${TXQUEUELEN:-}"
log(){ echo "[tune-bond] $*"; }

cpu_mask_auto(){ # simple: use all online CPUs
  local cpus n=0 mask=0
  cpus=$(awk -F '[-,]' '/^processor/{n++} END{print n}' /proc/cpuinfo)
  [ -z "$cpus" ] && cpus=1
  # Use up to 32 CPUs for mask simplicity
  local use=$(( cpus > 32 ? 32 : cpus ))
  for ((i=0;i<use;i++)); do mask=$((mask | (1<<i))); done
  printf "0x%x" "$mask"
}

nic_list() {
  ls -1 /sys/class/net | grep -E '^(en|eth|bond)'
}

maybe_set_mtu(){
  local ifc="$1"
  if [ "$BOND_FORCE_MTU" = "true" ] && [ -n "$BOND_DESIRED_MTU" ]; then
    ip link set dev "$ifc" mtu "$BOND_DESIRED_MTU" || true
  fi
}

tune_one(){
  local ifc="$1"
  [ "$ENABLE_NIC_TUNING" = "true" ] || return 0
  command -v ethtool >/dev/null 2>&1 || { log "ethtool missing; skip"; return 0; }

  if [ -n "$RX_USECS" ]; then ethtool -C "$ifc" rx-usecs "$RX_USECS" || true; fi
  if [ -n "$TX_USECS" ]; then ethtool -C "$ifc" tx-usecs "$TX_USECS" || true; fi
  if [ -n "$TXQUEUELEN" ]; then ip link set dev "$ifc" txqueuelen "$TXQUEUELEN" || true; fi

  # RPS
  local mask="$RPS_CPUMASK"
  if [ "$mask" = "auto" ]; then mask="$(cpu_mask_auto)"; fi
  for q in /sys/class/net/"$ifc"/queues/rx-*; do
    [ -d "$q" ] || continue
    echo "$mask" > "$q/rps_cpus" 2>/dev/null || true
    [ -n "$RPS_FLOWS_PER_QUEUE" ] && echo "$RPS_FLOWS_PER_QUEUE" > "$q/rps_flow_cnt" 2>/dev/null || true
  done
  maybe_set_mtu "$ifc"
  log "tuned $ifc (mask=$mask)"
}

# If bond exists, operate on its slaves; else operate on active NICs
if ip link show "$BOND_IF" >/dev/null 2>&1; then
  # Tune bond slaves
  if [ -r "/sys/class/net/$BOND_IF/bonding/slaves" ]; then
    for s in $(cat "/sys/class/net/$BOND_IF/bonding/slaves"); do tune_one "$s"; done
  fi
  maybe_set_mtu "$BOND_IF"
else
  for n in $(nic_list); do
    # Skip loopback and docker/veth/etc
    case "$n" in lo|docker*|veth*|br*|virbr*|vlan*|vmnet* ) continue;; esac
    tune_one "$n"
  done
fi

exit 0
EOF

  # --- tune-sysctl script ---
  cat > /usr/sbin/tune-sysctl <<'EOF'
#!/bin/bash
set -euo pipefail

DEF="/etc/default/tune-bond"
OUT="/etc/sysctl.d/98-perf-autoprofile.conf"

# Read a key="value" from DEF robustly (no sourcing)
read_kv() {
  local key="$1" defval="$2" val
  if [ -r "$DEF" ]; then
    val="$(awk -F= -v k="^${key}=" '
      $0 ~ k {
        # join rest of the line
        sub(/^[^=]+= */,"",$0)
        # strip quotes and CR
        gsub(/\r/,"",$0)
        gsub(/^"/,"",$0); gsub(/"$/,"",$0)
        print $0; exit
      }' "$DEF")"
    [ -n "${val:-}" ] && { printf '%s\n' "$val"; return 0; }
  fi
  printf '%s\n' "$defval"
}

PROFILE="$(read_kv PROFILE auto)"
TCP_CC_OVERRIDE="$(read_kv TCP_CC_OVERRIDE "")"
QDISC_OVERRIDE="$(read_kv QDISC_OVERRIDE "")"

# Pick a supported CC from a preference list (first match wins)
pick_supported_cc() {
  local avail pref
  avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "cubic reno")"
  for pref in "$@"; do
    if printf '%s\n' "$avail" | tr ' ' '\n' | grep -qx "$pref"; then
      printf '%s\n' "$pref"
      return 0
    fi
  done
  # last resort
  printf '%s\n' cubic
}

# Base profile → default knobs (overrides win)
case "$PROFILE" in
  auto|perf|wan_throughput|datacenter_10g)
    base_cc="bbr";     base_qdisc="fq"
    ;;
  lan_low_latency|conservative)
    base_cc="cubic";   base_qdisc="fq_codel"
    ;;
  nic-only)
    base_cc="bbr";     base_qdisc="fq"
    ;;
  *)
    base_cc="bbr";     base_qdisc="fq"
    ;;
esac

# Apply overrides (if set), otherwise fall back to supported defaults
CC="$(pick_supported_cc ${TCP_CC_OVERRIDE:-$base_cc} "$base_cc" cubic reno)"
QDISC="${QDISC_OVERRIDE:-$base_qdisc}"


mkdir -p /etc/sysctl.d

cat >"$OUT" <<EOF
# Generated by tune-sysctl (tb-perf-tuning)
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}

# Moderate backlog/buffers
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Enable TCP fast open (server+client)
net.ipv4.tcp_fastopen = 3

# Increase somaxconn for busy accept loops
net.core.somaxconn = 16384

# Allow enough ephemeral ports
net.ipv4.ip_local_port_range = 2000 65535
EOF

# Apply just our file, then let the system aggregate
sysctl -q -p "$OUT" || true
EOF

  chmod +x /usr/sbin/tune-bond /usr/sbin/tune-sysctl
}

# --- Main Logic ---

apply_ssh_hardening() {
  if [ "$SSH_ON" = "false" ]; then
    return 0
  fi
  echo ""
  echo "Applying SSH Hardening..."

  # Create user if needed
  if ! id "$SSH_USER" >/dev/null 2>&1; then
    echo "Creating new user: $SSH_USER"
    adduser --disabled-password --gecos "" "$SSH_USER"
  fi

  # Add public key
  if [ -n "$SSH_PUBKEY" ]; then
    local home_dir
    home_dir=$(getent passwd "$SSH_USER" | cut -d: -f6)
    local auth_keys_file="$home_dir/.ssh/authorized_keys"

    echo "Adding SSH public key for user $SSH_USER"
    mkdir -p "$home_dir/.ssh"
    chmod 700 "$home_dir/.ssh"
    
    # Avoid duplicate keys
    if ! grep -qF "$SSH_PUBKEY" "$auth_keys_file" 2>/dev/null; then
        echo "$SSH_PUBKEY" >> "$auth_keys_file"
    fi
    
    chown -R "$SSH_USER:$SSH_USER" "$home_dir/.ssh"
    chmod 600 "$auth_keys_file"
  fi

  # Create sshd config drop-in
  echo "Creating sshd hardening config: /etc/ssh/sshd_config.d/99-hardening.conf"
  mkdir -p /etc/ssh/sshd_config.d
  
  local permit_root_login="prohibit-password"
  if [ "$SSH_DISABLE_ROOT" = "true" ]; then
    permit_root_login="no"
  fi

  local password_auth="yes"
  if [ "$SSH_DISABLE_PASSWORD" = "true" ]; then
    password_auth="no"
  fi

  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# Managed by tb-perf-tuning script
Protocol 2
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
PubkeyAuthentication yes
PasswordAuthentication $password_auth
PermitRootLogin $permit_root_login
EOF

  echo "Reloading SSH service..."
  if ! systemctl reload-or-restart ssh; then
    echo "Warning: Could not reload sshd. It may not be installed or running." >&2
  fi
}

# --- Main Execution ---
main() {
  check_root
  check_dependencies
  
  echo "Welcome to the Monolithic Performance Tuning & Hardening Script."
  echo ""

  ask_questions

  echo ""
  echo "Starting installation and configuration..."
  
  # 1. Create all necessary files
  create_limits_conf
  create_sysctl_files
  create_tune_bond_defaults
  create_tuning_scripts
  create_systemd_units

  # 2. Apply initial settings
  echo "Applying sysctl settings..."
  /usr/sbin/tune-sysctl
  sysctl --system

  # 3. Reload systemd and enable services
  echo "Reloading systemd and enabling services..."
  systemctl daemon-reload
  systemctl enable --now tune-bond.service
  systemctl enable --now tune-sysctl.service
  
  if grep -qs '^DISABLE_THP="true"' /etc/default/tune-bond; then
    echo "Enabling service to disable Transparent Huge Pages..."
    systemctl enable --now disable-thp.service
  fi

  # 4. SSH hardening
  apply_ssh_hardening

  echo ""
  echo "-------------------------------------"
  echo " Installation Complete"
  echo "-------------------------------------"
  echo "Tuning profiles and hardening settings have been applied."
  echo "Services are enabled to re-apply settings on every boot."
  echo "A system reboot is recommended to ensure all settings take effect."
}

main "$@"
