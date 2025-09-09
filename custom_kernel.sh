#!/usr/bin/env bash
set -euo pipefail

# kernel-tool.sh — Pristine, hardened/pruned Xeon (R720/E5-2697 v2) kernel builder
# - Starts from allnoconfig (no host seeding)
# - Applies locked fragment (embedded) + MGLRU + Clang ThinLTO
# - Auto-resolves latest LTS kernel series and latest stable OpenZFS 2.2.x
# - Builds Debian packages, can install locally, verify, and package prebuilt ZFS modules
#
# Quickstart:
#   sudo ./kernel-tool.sh plan
#   sudo ./kernel-tool.sh fetch
#   sudo ./kernel-tool.sh config
#   sudo ./kernel-tool.sh build
#   sudo ./kernel-tool.sh install
#   sudo ./kernel-tool.sh verify
#   sudo ./kernel-tool.sh package-zfs   # prebuilt ZFS modules (no DKMS)
#
# Environment overrides (optional):
#   KERNEL_SERIES=auto|6.6         # default: auto (latest longterm)
#   WORKDIR=~/kernel-build         # default: ~/kernel-build
#   LOCALVER=-r720srv              # kernel localversion suffix
#   BUILDJOBS=$(nproc)             # parallel jobs
#   ZFS_VERSION=auto|2.2.4         # default: auto (latest 2.2.x)
#   ZFS_SRC=https://github.com/openzfs/zfs
#   ZFS_WORKDIR=~/zfs-build

KERNEL_SERIES="${KERNEL_SERIES:-auto}"
WORKDIR="${WORKDIR:-$HOME/kernel-build}"
BUILDJOBS="${BUILDJOBS:-$(nproc)}"
LOCALVER="${LOCALVER:--r720srv}"

ZFS_VERSION="${ZFS_VERSION:-auto}"
ZFS_SRC="${ZFS_SRC:-https://github.com/openzfs/zfs}"
ZFS_WORKDIR="${ZFS_WORKDIR:-$HOME/zfs-build}"

FRAGMENT_CONTENT='__FRAGMENT_BELOW__'

usage() {
  cat <<EOF
Usage: sudo $0 <subcommand>

Subcommands:
  plan         Show the locked scope & feature set
  fetch        Clone/sync linux-stable (auto LTS) into \${WORKDIR}
  config       Start from allnoconfig, apply fragment, enable MGLRU, lock ThinLTO
  build        Build Debian packages with Clang ThinLTO
  install      Install built image+headers locally & update-grub
  verify       Non-interactive smoke test on the running kernel

  zfs-dkms     Install OpenZFS via DKMS and update initramfs (simple path)
  package-zfs  Build a PREBUILT OpenZFS modules .deb matched to the kernel (no DKMS)

  variant      Build a passthrough-IOMMU kernel variant (suffix: -r720srv-pt)
  patch-apply  Cherry-pick upstream commits (args: <sha> [sha ...]) then build
  clean        Remove build tree (keeps installed kernels)

Examples:
  sudo $0 fetch && sudo $0 config && sudo $0 build && sudo $0 install
  sudo $0 package-zfs
EOF
}

need_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }; }

ensure_deps() {
  apt-get update -y
  apt-get install -y --no-install-recommends \
    clang lld llvm make gcc bc bison flex libssl-dev libelf-dev \
    dwarves pahole libncurses-dev ccache fakeroot rsync \
    git ca-certificates curl zstd python3 kmod dkms \
    build-essential autoconf automake libtool gawk \
    libblkid-dev uuid-dev zlib1g-dev libzstd-dev libudev-dev
}

resolve_kernel_series() {
  # Returns a branch name like "6.6" (latest longterm) or a safe fallback.
  local series
  if [ "${KERNEL_SERIES}" != "auto" ]; then
    echo "${KERNEL_SERIES}"; return
  fi
  series="$(
    curl -fsSL https://www.kernel.org/releases.json 2>/dev/null \
      | tr -d '\n' \
      | sed 's/"/\n/g' \
      | awk '/longterm/ {getline; print; exit}'
  )"
  case "$series" in
    ''|*[!0-9.]* ) series="6.6" ;;
  esac
  echo "$series"
}

resolve_zfs_version() {
  # Returns an OpenZFS tag like "2.2.4" (latest 2.2.x) or a safe fallback.
  local ver
  if [ "${ZFS_VERSION}" != "auto" ]; then
    echo "${ZFS_VERSION}"; return
  fi
  ver="$(
    curl -fsSL https://api.github.com/repos/openzfs/zfs/tags 2>/dev/null \
      | grep -Eo '"name":\s*"zfs-[0-9]+\.[0-9]+\.[0-9]+"' \
      | head -n 30 \
      | sed -E 's/.*"zfs-([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
      | sort -Vr \
      | awk -F. '$1==2 && $2==2 {print; exit}'
  )"
  [ -n "$ver" ] || ver="2.2.4"
  echo "$ver"
}

plan() {
  cat <<'EOF'
Scope (locked):
- Pristine config: allnoconfig baseline, no host seeding
- Xeon E5-v2 NUMA, PREEMPT_NONE, NO_HZ_IDLE, HZ=250
- NVMe + SAS (megaraid_sas JBOD) + AHCI; SES enclosure; async scan; sg
- Broadcom BCM5720 (tg3 only), bonding built-in; VLAN_8021Q; IPv4/IPv6; AF_PACKET/UNIX
- Filesystems: ext4 (covers ext3), vfat + NLS; EFI/EFIVAR; ZFS out-of-tree
- Security: KASLR, PTI, SMEP/SMAP, STRICT_KERNEL_RWX, fortify, usercopy, refcount
- IOMMU strict default; passthrough via boot args or variant build
- eBPF JIT hardened, unprivileged BPF OFF; kTLS ULP ON (no device offload)
- USB basics (EHCI, storage, HID); framebuffer console; mgag200
- RAS: EDAC SBridge, MCE, PCIe AER/ECRC, Dell SMBIOS/RBU, watchdog, thermals/hwmon
- Essentials: PROC, SYSFS, TMPFS, KMOD, partitions, FW loader, HPET, HW RNG
- MGLRU enabled
- Toolchain: Clang + LLD, ThinLTO; CFI OFF; INIT_STACK_ALL_ZERO OFF
- Auto-LTS kernel series; auto OpenZFS 2.2.x
EOF
}

fetch() {
  need_root
  ensure_deps
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"
  local series
  series="$(resolve_kernel_series)"
  if [ ! -d linux ]; then
    echo "Cloning linux-stable v${series} (longterm) ..."
    git clone --depth=1 --branch "v${series}" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
  fi
  cd linux
  git fetch --depth=1 origin "v${series}"
  git checkout -f "v${series}"
  git reset --hard
  git clean -fdx
  git rev-parse HEAD > ../kernel.commit
  echo "Fetched linux-stable $(cat ../kernel.commit)"
}

write_fragment() {
  cd "$WORKDIR/linux"
  printf "%s\n" "$FRAGMENT_CONTENT" | sed -n '/^__FRAGMENT_BELOW__$/,$p' | sed '1d' > ../KCONFIG.fragment
  echo "Fragment written to $WORKDIR/KCONFIG.fragment"
}

config() {
  need_root
  [ -d "$WORKDIR/linux" ] || { echo "Run fetch first"; exit 1; }
  write_fragment
  cd "$WORKDIR/linux"
  make mrproper
  make allnoconfig
  # Merge hardened fragment
  scripts/kconfig/merge_config.sh -m .config "$WORKDIR/KCONFIG.fragment"
  # Lock ThinLTO & explicitly disable CFI
  scripts/config --enable LTO_CLANG --enable LTO_CLANG_THIN
  scripts/config --disable CFI_CLANG
  # Resolve deps (no host seeding)
  yes "" | make olddefconfig
  # Catch any new prompts in future -stable bumps
  yes "" | make listnewconfig || true
  cp .config ../config.final
  echo "Final .config saved to $WORKDIR/config.final"
}

build() {
  need_root
  [ -f "$WORKDIR/config.final" ] || { echo "Run config first"; exit 1; }
  cd "$WORKDIR/linux"
  cp ../config.final .config
  export LLVM=1 CC=clang HOSTCC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  export KDEB_CHANGELOG_DIST="$(
    . /etc/os-release 2>/dev/null || true
    echo "${VERSION_CODENAME:-stable}"
  )"
  make -j"${BUILDJOBS}" bindeb-pkg LOCALVERSION="${LOCALVER}" DBUILD_VERBOSE=1
  echo "Artifacts:"
  ls -1 ../linux-image-*${LOCALVER}_*.deb ../linux-headers-*${LOCALVER}_*.deb
}

install_pkg() {
  need_root
  local img hdr
  img=$(ls -1 "$WORKDIR"/../linux-image-*${LOCALVER}_*.deb | tail -n1)
  hdr=$(ls -1 "$WORKDIR"/../linux-headers-*${LOCALVER}_*.deb | tail -n1)
  [ -n "${img:-}" ] || { echo "Image package not found"; exit 1; }
  dpkg -i "$img" ${hdr:+$hdr}
  update-grub || true
  echo "Installed. Reboot when ready."
}

verify() {
  echo "Kernel: $(uname -r)"
  echo "NUMA:"; (numactl --hardware 2>/dev/null || true) | sed 's/^/  /'
  echo "Mitigations:"; dmesg | egrep -i "pti|spectre|mds|retbleed|smep|smap" | tail -n5 | sed 's/^/  /'
  echo "IOMMU:"; dmesg | egrep -i "DMAR|IOMMU" | tail -n5 | sed 's/^/  /'
  echo "Storage:"; lsblk -d -o NAME,ROTA,SIZE,MODEL | sed 's/^/  /'
  echo "NIC drivers:"; for i in $(ls /sys/class/net 2>/dev/null | grep -v lo); do ethtool -i "$i" 2>/dev/null | sed "s/^/  [$i] /"; done
  echo "USB basics loaded:"; lsmod | egrep 'usb_storage|usbhid' || true
  echo "Framebuffer:"; dmesg | egrep -i "mgag200|simplefb|framebuffer" | tail -n5 | sed 's/^/  /'
  echo "EDAC:"; dmesg | egrep -i "edac|mce" | tail -n5 | sed 's/^/  /'
  echo "MGLRU:"; if [ -r /sys/kernel/mm/lru_gen/enabled ]; then cat /sys/kernel/mm/lru_gen/enabled; else echo "  (sysfs not present)"; fi
}

zfs_dkms() {
  need_root
  apt-get update -y
  apt-get install -y dkms zfs-dkms zfsutils-linux zfs-initramfs
  update-initramfs -u -k "$(uname -r)"
  echo "ZFS DKMS installed and initramfs updated."
}

package_zfs() {
  need_root
  # Determine target kernel version from installed image or running kernel
  local kver
  kver="$(dpkg -l | awk '/^ii\s+linux-image-.*'"${LOCALVER//-/\\.}"'/{print $2}' | sed 's/linux-image-//' | tail -n1)"
  if [ -z "$kver" ]; then
    kver="$(uname -r)"
    echo "No installed image with ${LOCALVER}; defaulting to running kernel: $kver"
  else
    echo "Target kernel for ZFS modules: $kver"
  fi

  mkdir -p "$ZFS_WORKDIR"
  cd "$ZFS_WORKDIR"

  local zver
  zver="$(resolve_zfs_version)"

  if [ ! -d zfs ]; then
    echo "Cloning OpenZFS ${zver} ..."
    git clone --depth=1 --branch "zfs-${zver}" "$ZFS_SRC" zfs
  else
    cd zfs
    git fetch --depth=1 origin "zfs-${zver}" || true
    git checkout -f "zfs-${zver}" || git checkout -f "zfs-${zver#v}"
    git reset --hard
    git clean -fdx
    cd ..
  fi

  cd zfs
  sh autogen.sh
  ./configure --with-config=kernel \
              --with-linux="/lib/modules/${kver}/build" \
              --with-linux-obj="/lib/modules/${kver}/build"
  make -j"$(nproc)"

  local pkgdir pkgname ver arch
  arch="$(dpkg --print-architecture)"
  ver="${zver}"
  pkgname="zfs-modules-${kver}-${LOCALVER#-}"
  pkgdir="$ZFS_WORKDIR/${pkgname}"
  rm -rf "$pkgdir"
  mkdir -p "$pkgdir/DEBIAN" "$pkgdir/lib/modules/${kver}/extra/zfs"

  find module -maxdepth 1 -name '*.ko' -print -exec install -m0644 {} "$pkgdir/lib/modules/${kver}/extra/zfs/" \;

  cat > "$pkgdir/DEBIAN/control" <<CTRL
Package: ${pkgname}
Version: ${ver}
Section: kernel
Priority: optional
Architecture: ${arch}
Depends: linux-image-${kver} | linux-image, initramfs-tools
Provides: zfs-modules
Maintainer: local
Description: Prebuilt OpenZFS kernel modules for ${kver} (${LOCALVER})
 This package installs OpenZFS kernel modules under /lib/modules/${kver}/extra/zfs
CTRL

  cat > "$pkgdir/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
# Determine kernel version from package name:
pkg="$DPKG_MAINTSCRIPT_PACKAGE"
kver="$(echo "$pkg" | sed 's/^zfs-modules-//; s/-[^-]*$//')"
depmod -a "$kver" || true
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k "$kver" || true
fi
exit 0
POSTINST
  chmod 0755 "$pkgdir/DEBIAN/postinst"

  dpkg-deb --build "$pkgdir"
  echo "Built: ${pkgdir}.deb"
  echo
  echo "Install with:"
  echo "  sudo dpkg -i ${pkgdir}.deb"
  echo "  sudo apt-get install -y zfsutils-linux   # userspace tools only (no DKMS)"
  echo
  echo "Note: If Secure Boot is enabled, unsigned modules may not load (use MOK signing or disable SB)."
}

variant() {
  need_root
  [ -f "$WORKDIR/config.final" ] || { echo "Run config first"; exit 1; }
  cd "$WORKDIR/linux"
  cp ../config.final .config
  scripts/config --disable IOMMU_DEFAULT_DMA_STRICT
  scripts/config --enable IOMMU_DEFAULT_PASSTHROUGH
  yes "" | make olddefconfig
  export LLVM=1 CC=clang HOSTCC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  make -j"${BUILDJOBS}" bindeb-pkg LOCALVERSION="${LOCALVER}-pt" DBUILD_VERBOSE=1
  echo "Passthrough variant built:"
  ls -1 ../linux-image-*${LOCALVER}-pt_*.deb ../linux-headers-*${LOCALVER}-pt_*.deb
}

patch_apply() {
  need_root
  [ $# -ge 1 ] || { echo "Usage: $0 patch-apply <sha> [sha ...]"; exit 1; }
  cd "$WORKDIR/linux"
  for sha in "$@"; do
    echo "Cherry-picking $sha ..."
    git cherry-pick -x "$sha"
  done
  export LLVM=1 CC=clang HOSTCC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  make -j"${BUILDJOBS}" bindeb-pkg LOCALVERSION="${LOCALVER}-p$(git rev-parse --short HEAD)" DBUILD_VERBOSE=1
  echo "Patched build complete."
}

clean_build() {
  need_root
  rm -rf "$WORKDIR/linux"
  echo "Cleaned $WORKDIR/linux"
}

case "${1:-}" in
  plan)         plan ;;
  fetch)        fetch ;;
  config)       config ;;
  build)        build ;;
  install)      install_pkg ;;
  verify)       verify ;;
  zfs-dkms)     zfs_dkms ;;
  package-zfs)  package_zfs ;;
  variant)      variant ;;
  patch-apply)  shift; patch_apply "$@" ;;
  clean)        clean_build ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown subcommand: $1"; usage; exit 1 ;;
esac

exit 0

__FRAGMENT_BELOW__
# ===== Core plumbing =====
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_KMOD=y
CONFIG_MODULES=y
CONFIG_KALLSYMS=y

# ===== Partitions / Firmware loader =====
CONFIG_PARTITION_ADVANCED=y
CONFIG_MSDOS_PARTITION=y
CONFIG_FW_LOADER=y
# CONFIG_FW_LOADER_USER_HELPER is not set

# ===== CPU / Topology / Scheduler =====
CONFIG_X86_64=y
CONFIG_GENERIC_CPU2=y
# CONFIG_GENERIC_CPU3 is not set
CONFIG_X86_X2APIC=y
CONFIG_NUMA=y
CONFIG_X86_64_ACPI_NUMA=y
CONFIG_NUMA_BALANCING=y
CONFIG_SCHED_SMT=y
CONFIG_SCHED_MC=y
CONFIG_PREEMPT_NONE=y
# CONFIG_PREEMPT_VOLUNTARY is not set
CONFIG_NO_HZ_IDLE=y
CONFIG_HZ_250=y
# CONFIG_HZ_100 is not set

# ===== Memory / VM hardening =====
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
# CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS is not set
CONFIG_HUGETLBFS=y
CONFIG_HUGETLB_PAGE=y
CONFIG_COMPACTION=y
CONFIG_KSM=y
CONFIG_SLAB_FREELIST_HARDENED=y
CONFIG_SLAB_FREELIST_RANDOM=y
CONFIG_SHUFFLE_PAGE_ALLOCATOR=y
# MGLRU
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
# CONFIG_INIT_ON_ALLOC_DEFAULT_ON is not set
# CONFIG_INIT_ON_FREE_DEFAULT_ON is not set

# ===== Toolchain / LTO (Clang ThinLTO) =====
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_CFI_CLANG is not set
# CONFIG_INIT_STACK_ALL_ZERO is not set

# ===== Security / KSPP =====
CONFIG_SPECULATION_MITIGATIONS=y
CONFIG_PAGE_TABLE_ISOLATION=y
CONFIG_X86_SMEP=y
CONFIG_X86_SMAP=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_REFCOUNT_FULL=y
CONFIG_SECURITY=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
# CONFIG_AUDIT is not set
# CONFIG_KEXEC is not set
# CONFIG_KEXEC_FILE is not set

# ===== IOMMU / DMA =====
CONFIG_IOMMU_SUPPORT=y
CONFIG_INTEL_IOMMU=y
CONFIG_IOMMU_DEFAULT_DMA_STRICT=y
# CONFIG_PCI_IOV is not set

# ===== RAS / Platform =====
CONFIG_X86_MCE=y
CONFIG_X86_MCE_INTEL=y
CONFIG_EDAC=y
CONFIG_EDAC_GHES=y
CONFIG_EDAC_SBRIDGE=y
CONFIG_PCIEPORTBUS=y
CONFIG_PCIEAER=y
CONFIG_PCIE_ECRC=y
CONFIG_DELL_SMBIOS=m
CONFIG_DELL_RBU=m
CONFIG_WATCHDOG=y
CONFIG_ITCO_WDT=m
CONFIG_HWMON=y
CONFIG_X86_PKG_TEMP_THERMAL=m
CONFIG_SENSORS_CORETEMP=m

# ===== Storage / Block / SAS & NVMe (JBOD) =====
CONFIG_BLK_DEV_INITRD=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_BLK_DEV_NVME=y
# CONFIG_NVME_MULTIPATH is not set
CONFIG_SCSI=y
CONFIG_SCSI_SAS_LIBSAS=y
CONFIG_SCSI_SAS_ATA=y
CONFIG_SCSI_SCAN_ASYNC=y
CONFIG_BLK_DEV_SD=y
CONFIG_CHR_DEV_SG=m
CONFIG_ENCLOSURE_SERVICES=m
CONFIG_SCSI_ENCLOSURE=m
CONFIG_SCSI_MEGARAID_SAS=m
CONFIG_ATA=y
CONFIG_SATA_AHCI=y
# RAID layers pruned
# CONFIG_MD is not set
# CONFIG_BLK_DEV_MD is not set
# CONFIG_DM is not set
# CONFIG_DM_RAID is not set
# CONFIG_DM_MIRROR is not set
# CONFIG_DM_ZERO is not set

# ===== Networking (core + Broadcom tg3 only) =====
CONFIG_NET=y
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_NET_SCHED=y
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_CLS_BPF=y
CONFIG_CLS_U32=y
CONFIG_NETFILTER=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=m
CONFIG_NETFILTER_XT_MATCH_BPF=m
CONFIG_NETFILTER_XT_TARGET_TPROXY=m
CONFIG_ETHERNET=y
CONFIG_BONDING=y
CONFIG_VLAN_8021Q=m
CONFIG_TCP_CONG_CUBIC=y
CONFIG_DEFAULT_CUBIC=y
CONFIG_TCP_CONG_BBR=m
# CONFIG_DEFAULT_RENO is not set
CONFIG_BPF=y
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_BPF_JIT_HARDEN=y
CONFIG_BPF_UNPRIV_DEFAULT_OFF=y
CONFIG_TLS=y
# CONFIG_TLS_DEVICE is not set
CONFIG_NET_VENDOR_BROADCOM=y
CONFIG_TG3=m
# CONFIG_NET_VENDOR_INTEL is not set
# CONFIG_NET_VENDOR_REALTEK is not set
# CONFIG_NET_VENDOR_MELLANOX is not set
# ... others off

# ===== USB / Input / Console / Video =====
CONFIG_USB=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_EHCI_PCI=y
CONFIG_USB_UHCI_HCD=y
# CONFIG_USB_XHCI_HCD is not set
# CONFIG_USB_UAS is not set
CONFIG_USB_STORAGE=m
CONFIG_HID=y
CONFIG_HID_GENERIC=m
CONFIG_USB_HID=m
CONFIG_INPUT_KEYBOARD=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_VT=y
CONFIG_VGA_CONSOLE=y
CONFIG_EARLY_PRINTK=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_DRM=y
CONFIG_DRM_MGAG200=m
# CONFIG_DRM_AMDGPU is not set
# CONFIG_DRM_I915 is not set
CONFIG_FB_SIMPLE=y

# ===== Filesystems / Boot =====
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_MSDOS_FS=m
CONFIG_VFAT_FS=m
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_EFI_PARTITION=y
CONFIG_EFIVAR_FS=y
# Only vfat + ext4 + ZFS (OO-tree)
# CONFIG_XFS_FS is not set
# CONFIG_BTRFS_FS is not set
# CONFIG_F2FS_FS is not set
# Compression
CONFIG_KERNEL_ZSTD=y
CONFIG_RD_ZSTD=y
CONFIG_INITRAMFS_COMPRESSION_ZSTD=y

# ===== NLS for FAT =====
CONFIG_NLS=y
CONFIG_NLS_CODEPAGE_437=m
CONFIG_NLS_ISO8859_1=m

# ===== Timers / RNG =====
CONFIG_HPET_TIMER=y
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_INTEL=m
