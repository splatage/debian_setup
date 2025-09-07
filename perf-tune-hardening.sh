#!/bin/bash
#
# Monolithic Performance Tuning & SSH Hardening Script (v5)
# Optimized for ZFS-root systems with MariaDB, Redis, Node.js
#
# Features:
# - Performance profiles (auto, LAN, WAN, datacenter_10g)
# - sysctl tuning, NIC queue tuning, ARC limits
# - Optional SSH hardening and public key install
# - Disables IPv6 via sysctl + GRUB
# - Sets CPU governor to performance and I/O elevator to deadline
# - Optional RAM-based ARC sizing
# - Security hardening (anti-spoofing, martian logging)
# - Transparent hugepage and turbo boost toggles (optional)
# - systemd services to persist changes

set -euo pipefail

check_root() {
    [ "$(id -u)" -eq 0 ] || { echo "Must be run as root."; exit 1; }
}

check_dependencies() {
    for bin in ethtool ip awk; do
        command -v "$bin" >/dev/null || {
            echo "Installing $bin..."; apt-get update; apt-get install -y "$bin"
        }
    done
}

# Optional toggles
ENABLE_HUGEPAGES=true
ENABLE_TURBO=true
DYNAMIC_ARC=true

set_profile_auto() {
    export TCP_CC="bbr"
    export QDISC="fq"
    export SYSCTL_SETTINGS=(
        "net.core.netdev_max_backlog=32768"
        "net.core.somaxconn=16384"
        "net.ipv4.tcp_mtu_probing=1"
    )
}

# (Other profile setters unchanged...)

apply_sysctl() {
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-perf-base.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_bytes=67108864
vm.dirty_bytes=536870912
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500
vm.max_map_count=262144
fs.file-max=2097152

# IPv6 disable
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1

# Kernel hardening
kernel.kptr_restrict=2
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
EOF

    echo "# Profile: $PROFILE" > /etc/sysctl.d/98-perf-profile.conf
    echo "net.core.default_qdisc = $QDISC" >> /etc/sysctl.d/98-perf-profile.conf
    echo "net.ipv4.tcp_congestion_control = $TCP_CC" >> /etc/sysctl.d/98-perf-profile.conf
    for s in "${SYSCTL_SETTINGS[@]}"; do echo "$s"; done >> /etc/sysctl.d/98-perf-profile.conf

    sysctl --system
}

apply_zfs_arc_limits() {
    echo "Setting ZFS ARC limits..."
    mkdir -p /etc/modprobe.d
    local arc_max arc_min

    if [ "$DYNAMIC_ARC" = true ]; then
        total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        arc_max=$(( total_kb * 60 / 100 * 1024 ))
        arc_min=$(( total_kb * 20 / 100 * 1024 ))
    else
        arc_max=6442450944
        arc_min=2147483648
    fi

    cat > /etc/modprobe.d/zfs-tuning.conf <<EOF
options zfs zfs_arc_max=$arc_max
options zfs zfs_arc_min=$arc_min
EOF
    update-initramfs -u
}

apply_io_and_cpu_sched() {
    echo "Applying I/O and CPU tuning..."
    cat > /etc/systemd/system/io-tuning.service <<EOF
[Unit]
Description=I/O and CPU scheduler tuning
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
for dev in /sys/block/*/queue/scheduler; do echo deadline > "$dev" 2>/dev/null; done
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f" 2>/dev/null; done
[ "$ENABLE_TURBO" = true ] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
[ "$ENABLE_HUGEPAGES" = true ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable --now io-tuning.service
}

# Main execution (updated)
main() {
    check_root
    check_dependencies
    ask_questions

    apply_sysctl
    apply_zfs_arc_limits
    apply_nic_tuning
    apply_io_and_cpu_sched
    apply_limits

    [[ "${DO_SSH_HARDEN:-}" =~ ^[Yy]$ ]] && apply_ssh_hardening

    echo "Disabling IPv6 in GRUB (non-destructive append)..."
    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="/&ipv6.disable=1 /' /etc/default/grub
        update-grub
    fi

    echo "✅ Complete. Reboot recommended."
}
