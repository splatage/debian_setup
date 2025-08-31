#!/bin/bash
set -euo pipefail

echo "=================================================================="
echo "🔧 Post-Boot Performance Hardening (from tb-perf-tuning)"
echo "=================================================================="
echo "Stage: 2.1 — Integrated installer aligned with original repo semantics."
echo

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root."; exit 1
fi

# --- prompt helper (works with 'curl | bash') ---
prompt_tty() {
  local var="$1" prompt="$2" def="$3"
  local inp=""
  if [[ -n "${!var:-}" ]]; then
    printf -v "$var" '%s' "${!var}"
    return 0
  fi
  if [[ -e /dev/tty ]]; then
    read -r -p "$prompt" inp < /dev/tty || true
  else
    read -r -p "$prompt" inp || true
  fi
  inp="${inp:-$def}"
  printf -v "$var" '%s' "$inp"
}

# --- Profile selection consistent with original repo ---
# Original /etc/default/tune-bond uses PROFILE="auto" by default.
PROFILE_NAME="${PROFILE_NAME:-}"
if [[ -z "${PROFILE_NAME}" && -z "${TUNE_NONINTERACTIVE:-}" ]]; then
  echo "Set profile value for /etc/default/tune-bond (original default: auto)"
  echo "  - Enter 'auto' to use repo defaults"
  echo "  - Enter any custom string to mark your own profile name"
  echo "  - Leave blank to accept 'auto'"
  prompt_tty PROFILE_NAME "PROFILE [auto]: " "auto"
fi
PROFILE_NAME="${PROFILE_NAME:-auto}"
echo "✅ PROFILE will be set to: $PROFILE_NAME"
echo

# --- Write /etc/default/tune-bond with injected PROFILE ---
echo "📄 Installing /etc/default/tune-bond..."
install -d -m 0755 -o root -g root /etc/default
install -m 0644 -o root -g root /dev/stdin /etc/default/tune-bond <<'__EOF_DEFAULT__'
# Default tunables for tb-perf-tuning (edited by installer)
PROFILE="auto"
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

__EOF_DEFAULT__

# Replace or append PROFILE= in-place to avoid divergence
if grep -q '^PROFILE=' /etc/default/tune-bond; then
  sed -i -E 's|^PROFILE=.*$|PROFILE="{PROFILE_NAME}"|' /etc/default/tune-bond
else
  printf '\nPROFILE="{PROFILE_NAME}"\n' >> /etc/default/tune-bond
fi
sed -i "s/{PROFILE_NAME}/${PROFILE_NAME}/g" /etc/default/tune-bond || true

# --- Sysctl & limits from repo ---
echo "📄 Writing sysctl + limits configs..."
install -d -m 0755 -o root -g root /etc/sysctl.d
install -m 0644 -o root -g root /dev/stdin /etc/sysctl.d/97-security-hardening.conf <<'__EOF_SHARD__'
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

__EOF_SHARD__

install -m 0644 -o root -g root /dev/stdin /etc/sysctl.d/99-perf-base.conf <<'__EOF_SBASE__'
# Base performance hints
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_timestamps = 1

__EOF_SBASE__

install -m 0644 -o root -g root /dev/stdin /etc/sysctl.d/99-perf-memory.conf <<'__EOF_SMEM__'
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20

__EOF_SMEM__

install -d -m 0755 -o root -g root /etc/security/limits.d
install -m 0644 -o root -g root /dev/stdin /etc/security/limits.d/99-perf.conf <<'__EOF_LIM__'
* soft nofile 1048576
* hard nofile 1048576

__EOF_LIM__

# --- Install scripts from repo ---
echo "📄 Installing tune scripts..."
install -d -m 0755 -o root -g root /usr/sbin
install -m 0755 -o root -g root /dev/stdin /usr/sbin/tune-bond <<'__EOF_TB__'
#!/usr/bin/env bash
set -euo pipefail

DEF="/etc/default/tune-bond"DEF="/etc/default/tune-bond"
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

__EOF_TB__

install -m 0755 -o root -g root /dev/stdin /usr/sbin/tune-sysctl <<'__EOF_TS__'
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
  auto|perf)
    base_cc="bbr";     base_qdisc="fq"
    ;;
  conservative)
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

__EOF_TS__

# --- Systemd units + overrides from repo ---
echo "📄 Installing systemd units + overrides..."
install -m 0644 -o root -g root /dev/stdin /etc/systemd/system/disable-thp.service <<'__EOF_THP__'
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

__EOF_THP__

install -m 0644 -o root -g root /dev/stdin /etc/systemd/system/tune-bond.service <<'__EOF_SVCB__'
[Unit]
Description=Apply tb-perf-tuning NIC/bond tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tune-bond

[Install]
WantedBy=multi-user.target

__EOF_SVCB__

install -m 0644 -o root -g root /dev/stdin /etc/systemd/system/tune-sysctl.service <<'__EOF_SVCS__'
[Unit]
Description=Apply tb-perf-tuning sysctl autoprofile
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tune-sysctl

[Install]
WantedBy=multi-user.target

__EOF_SVCS__

install -d -m 0755 -o root -g root /etc/systemd/system/redis-server.service.d
install -m 0644 -o root -g root /dev/stdin /etc/systemd/system/redis-server.service.d/override.conf <<'__EOF_R_OVR__'
[Service]
LimitNOFILE=1048576
IOWeight=1000

__EOF_R_OVR__

install -d -m 0755 -o root -g root /etc/systemd/system/mariadb.service.d
install -m 0644 -o root -g root /dev/stdin /etc/systemd/system/mariadb.service.d/override.conf <<'__EOF_M_OVR__'
[Service]
LimitNOFILE=1048576
IOSchedulingPriority=2

__EOF_M_OVR__

# --- Reload and enable ---
echo "🔄 Reloading systemd and enabling services..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable disable-thp.service
systemctl enable tune-sysctl.service
systemctl enable tune-bond.service

echo
echo "✅ Stage 2.1 done: repo-aligned installer written."
echo "   PROFILE="${PROFILE_NAME}" in /etc/default/tune-bond"
echo "   You can start services now or reboot."
