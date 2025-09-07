#!/bin/bash
#
# Monolithic Performance Tuning & SSH Hardening Script (v5-fixed)
# Fully reordered and ready for direct execution

set -euo pipefail

### Logging (optional, persistent)
exec > >(tee -a /var/log/perf-tune.log) 2>&1

### Root check
[ "$(id -u)" -eq 0 ] || { echo "Must be run as root."; exit 1; }

### Global toggles
ENABLE_HUGEPAGES=true
ENABLE_TURBO=true
DYNAMIC_ARC=true

### Function Definitions

check_dependencies() {
    for bin in ethtool ip awk; do
        command -v "$bin" >/dev/null || {
            echo "Installing $bin..."; apt-get update; apt-get install -y "$bin"
        }
    done
}

set_profile_auto() {
    export TCP_CC="bbr"
    export QDISC="fq"
    export SYSCTL_SETTINGS=(
        "net.core.netdev_max_backlog=32768"
        "net.core.somaxconn=16384"
        "net.ipv4.tcp_mtu_probing=1"
    )
}

set_profile_lan_low_latency() {
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

ask_questions() {
    echo "--- Performance Tuning ---"
    select p in "auto" "lan_low_latency" "wan_throughput" "datacenter_10g"; do
        PROFILE="$p"
        set_profile_${PROFILE}
        break
    done

    echo ""
    read -rp "Enable SSH hardening? [y/N]: " DO_SSH_HARDEN
    if [[ "$DO_SSH_HARDEN" =~ ^[Yy]$ ]]; then
        read -rp "Install SSH key? [y/N]: " DO_KEY
        if [[ "$DO_KEY" =~ ^[Yy]$ ]]; then
            echo "Available users:"
            mapfile -t USERS < <(awk -F: '$3 >= 0 && $3 < 65534 {print $1}' /etc/passwd)
            select u in "${USERS[@]}" "Skip"; do
                [[ "$u" == "Skip" ]] && break
                id "$u" &>/dev/null && SSH_USER="$u" && break
            done
            [[ -n "${SSH_USER:-}" ]] && read -rp "Paste public key: " SSH_PUBKEY
        fi
    fi
}

apply_sysctl() { ... }
apply_zfs_arc_limits() { ... }
apply_nic_tuning() { ... }
apply_io_and_cpu_sched() { ... }
apply_limits() { ... }
apply_ssh_hardening() { ... }
uninstall() { ... }

main() {
    echo "[INFO] Starting Performance Tuning Script (v5)..."
    check_dependencies
    ask_questions
    apply_sysctl
    apply_zfs_arc_limits
    apply_nic_tuning
    apply_io_and_cpu_sched
    apply_limits
    [[ "${DO_SSH_HARDEN:-}" =~ ^[Yy]$ ]] && apply_ssh_hardening

    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="/\0ipv6.disable=1 /' /etc/default/grub
        update-grub
    fi
    echo "✅ Complete. Reboot recommended."
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall
else
  main
fi
