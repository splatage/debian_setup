#!/usr/bin/env bash
set -euo pipefail

# kernel-tool.sh v3 — Hardened R720 (Xeon E5-v2) kernel builder
# - Pristine config from allnoconfig (no host seeding)
# - Hardened/pruned fragment embedded below
# - Non-interactive Kconfig: pins LTO/SECCOMP/compat_time/stack offset/EXPERT/EMBEDDED/JUMP_LABEL
# - Auto LTS kernel discovery + auto OpenZFS 2.2.x (safe fallbacks)
# - Clang + LLD + ThinLTO; amd64 packaging enforced
# - Full verify harness, patch-apply, IOMMU passthrough variant
# - Prebuilt ZFS modules .deb (no DKMS) or DKMS path
# - Provenance: config snapshots + build-meta.json
#
# Environment overrides:
#   KERNEL_SERIES=auto|6.6      (default: auto → latest longterm)
#   WORKDIR=~/kernel-build      (default: ~/kernel-build)
#   LOCALVER=-r720srv           (kernel localversion suffix)
#   BUILDJOBS=$(nproc)          (parallel jobs)
#   ZFS_VERSION=auto|2.2.4      (default: auto → latest 2.2.x)
#   ZFS_SRC=https://github.com/openzfs/zfs
#   ZFS_WORKDIR=~/zfs-build
#   EXTRA_KCFLAGS="..."         (optional, appended to kernel CFLAGS; defaults empty)
#
# NOTE on compiler flags:
# - Kernel already uses -O2, frame pointers, etc. We set CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y.
# - ThinLTO is enabled; you can pass EXTRA_KCFLAGS for **expert-only** tuning.
#   Example (use with care): EXTRA_KCFLAGS="-mllvm -inline-threshold=600"

KERNEL_SERIES="${KERNEL_SERIES:-auto}"
WORKDIR="${WORKDIR:-$HOME/kernel-build}"
BUILDJOBS="${BUILDJOBS:-$(nproc)}"
LOCALVER="${LOCALVER:--r720srv}"

ZFS_VERSION="${ZFS_VERSION:-auto}"
ZFS_SRC="${ZFS_SRC:-https://github.com/openzfs/zfs}"
ZFS_WORKDIR="${ZFS_WORKDIR:-$HOME/zfs-build}"

EXTRA_KCFLAGS="${EXTRA_KCFLAGS:-}"

FRAGMENT_CONTENT='__FRAGMENT_BELOW__'

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }

usage() {
  cat <<EOF
Usage: sudo $0 <subcommand>

Subcommands:
  plan         Show locked scope & resolved LTS/ZFS versions
  fetch        Clone/sync linux-stable (auto LTS) into \$WORKDIR
  config       Pristine .config (non-interactive), snapshots + listnewconfig
  build        Build Debian packages (amd64, Clang+LLD, ThinLTO)
  install      Install image+headers, update-grub
  verify       Smoke-test running kernel & drivers/hardening
  zfs-dkms     Install OpenZFS via DKMS (simple path)
  package-zfs  Build prebuilt OpenZFS modules .deb (no DKMS)
  variant      Build IOMMU passthrough variant (suffix: -pt)
  patch-apply  Cherry-pick upstream commits then build (-p<sha>)
  clean        Remove build tree (keeps installed kernels)

Env (optional):
  KERNEL_SERIES WORKDIR LOCALVER BUILDJOBS ZFS_VERSION ZFS_SRC ZFS_WORKDIR EXTRA_KCFLAGS
EOF
}

need_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }; }

ensure_deps() {
  log "Installing build & packaging deps..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    build-essential fakeroot devscripts debhelper quilt \
    clang lld llvm make gcc bc bison flex libssl-dev libelf-dev \
    dwarves pahole libncurses-dev libncurses5-dev ccache rsync \
    git ca-certificates curl zstd python3 kmod dkms \
    autoconf automake libtool gawk \
    libblkid-dev uuid-dev zlib1g-dev libzstd-dev libudev-dev
}

resolve_kernel_series() {
  if [ "${KERNEL_SERIES}" != "auto" ]; then echo "${KERNEL_SERIES}"; return; fi
  local series
  series="$(
    curl -fsSL https://www.kernel.org/releases.json 2>/dev/null \
      | tr -d '\n' | sed 's/"/\n/g' \
      | awk '/longterm/ {getline; print; exit}'
  )"
  case "$series" in ''|*[!0-9.]* ) series="6.6";; esac
  echo "$series"
}

resolve_zfs_version() {
  if [ "${ZFS_VERSION}" != "auto" ]; then echo "${ZFS_VERSION}"; return; }
  local ver
  ver="$(
    curl -fsSL https://api.github.com/repos/openzfs/zfs/tags 2>/dev/null \
      | grep -Eo '"name":\s*"zfs-[0-9]+\.[0-9]+\.[0-9]+"' \
      | sed -E 's/.*"zfs-([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
      | sort -Vr | awk -F. '$1==2 && $2==2 {print; exit}'
  )"
  [ -n "$ver" ] || ver="2.2.4"
  echo "$ver"
}

plan() {
  local series zver
  series="$(resolve_kernel_series)"
  zver="$(resolve_zfs_version)"
  cat <<EOF
=== Plan ===
Kernel series (LTS): v${series}
OpenZFS version:     ${zver}
Workdir:             ${WORKDIR}
Localversion:        ${LOCALVER}
Jobs:                ${BUILDJOBS}
ThinLTO:             enabled (Clang/LLD)
EXTRA_KCFLAGS:       '${EXTRA_KCFLAGS}'
EOF
  cat <<'SCOPE'
Scope (locked):
- Xeon E5-v2 NUMA, HZ=250, PREEMPT_NONE, NO_HZ_IDLE
- NVMe + SAS (megaraid_sas JBOD) + AHCI; SES enclosure; sg; async scan
- NIC: Broadcom BCM5720 (tg3), bonding built-in; VLAN
- FS: ext4, vfat + NLS; EFI/EFIVAR; ZFS out-of-tree (DKMS or prebuilt)
- Security: SMEP/SMAP, PTI, KASLR, STRICT_KERNEL_RWX, FORTIFY, usercopy, refcount
- eBPF JIT hardened (unpriv off); kTLS ULP (no device offload)
- IOMMU strict default; passthrough variant available
- USB basics (EHCI, storage, HID); framebuffer console; mgag200
- RAS: EDAC SBridge, MCE, PCIe AER/ECRC, Dell SMBIOS/RBU, itco_wdt, thermals
- Essentials: proc, sysfs, tmpfs, kmod, partitions, firmware loader, HPET, RNG
- MGLRU enabled, CC optimize for performance
SCOPE
}

fetch() {
  need_root; ensure_deps
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  local series; series="$(resolve_kernel_series)"
  if [ ! -d linux ]; then
    log "Cloning linux-stable v${series} (LTS)..."
    git clone --depth=1 --branch "v${series}" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
  fi
  cd linux
  log "Syncing linux-stable v${series}..."
  git fetch --depth=1 origin "v${series}"
  git checkout -f "v${series}"
  git reset --hard; git clean -fdx
  git rev-parse HEAD > ../kernel.commit
  log "Kernel commit: $(cat ../kernel.commit)"
}

write_fragment() {
  cd "$WORKDIR/linux"
  printf "%s\n" "$FRAGMENT_CONTENT" | sed -n '/^__FRAGMENT_BELOW__$/,$p' | sed '1d' > ../KCONFIG.fragment
  log "Fragment written: $WORKDIR/KCONFIG.fragment"
}

config() {
  need_root; [ -d "$WORKDIR/linux" ] || { echo "Run fetch first"; exit 1; }
  write_fragment
  cd "$WORKDIR/linux"
  log "Resetting tree and starting from allnoconfig..."
  make mrproper
  make allnoconfig

  log "Merging hardened fragment..."
  scripts/kconfig/merge_config.sh -m .config "$WORKDIR/KCONFIG.fragment"

  # --- Hard pins to avoid prompts and enforce posture ---
  # Allow deep pruning and expert toggles:
  scripts/config --enable EXPERT
  scripts/config --enable EMBEDDED

  # Critical infra/security:
  scripts/config --enable JUMP_LABEL
  scripts/config --enable SECCOMP
  scripts/config --enable SECCOMP_FILTER

  # ThinLTO choice (no prompt):
  scripts/config --enable LTO_CLANG
  scripts/config --enable LTO_CLANG_THIN
  scripts/config --disable LTO_CLANG_FULL
  scripts/config --disable LTO_NONE

  # Newer symbols that prompted you:
  scripts/config --disable COMPAT_32BIT_TIME
  scripts/config --enable RANDOMIZE_KSTACK_OFFSET
  scripts/config --disable RANDOMIZE_KSTACK_OFFSET_DEFAULT

  # Prefer performance (vs size):
  scripts/config --enable CC_OPTIMIZE_FOR_PERFORMANCE
  scripts/config --disable CC_OPTIMIZE_FOR_SIZE

  # Finalize defaults (twice) and report new options if any
  yes "" | make olddefconfig
  yes "" | make olddefconfig
  yes "" | make listnewconfig || true

  # Provenance snapshots
  cp -f .config ../config.final
  make savedefconfig >/dev/null 2>&1 || true
  [ -f defconfig ] && cp -f defconfig ../config.savedefconfig || true
  sha256sum ../config.final | awk '{print $1}' > ../config.sha256
  log "Config ready: $WORKDIR/config.final (SHA256: $(cat ../config.sha256))"
}

build() {
  need_root; cd "$WORKDIR/linux"
  [ -f ../config.final ] && cp -f ../config.final .config || true

  # Toolchain: Clang + LLD + ThinLTO; enforce amd64 packaging
  export LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang LD=ld.lld \
         AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  # Optional expert-only extra flags
  if [ -n "${EXTRA_KCFLAGS}" ]; then
    export KCFLAGS="${EXTRA_KCFLAGS}"
    log "Using EXTRA_KCFLAGS='${EXTRA_KCFLAGS}'"
  fi

  log "Building Debian packages (amd64)…"
  make -j"${BUILDJOBS}" bindeb-pkg \
       LOCALVERSION="${LOCALVER}" DBUILD_VERBOSE=1 \
       ARCH=x86_64 DEB_BUILD_ARCH=amd64 DEB_BUILD_OPTIONS=parallel=${BUILDJOBS}

  log "Artifacts:"
  ls -1 ../linux-image-*${LOCALVER}_*.deb ../linux-headers-*${LOCALVER}_*.deb

  # Provenance (toolchain + commit)
  {
    echo "{"
    echo "  \"timestamp\": \"$(ts)\","
    echo "  \"kernel_commit\": \"$(cat ../kernel.commit 2>/dev/null || echo unknown)\","
    echo "  \"config_sha256\": \"$(cat ../config.sha256 2>/dev/null || echo unknown)\","
    echo "  \"localversion\": \"${LOCALVER}\","
    echo "  \"arch\": \"amd64\","
    echo "  \"clang\": \"$(clang --version | head -n1 | sed 's/\"/\\\"/g')\","
    echo "  \"lld\": \"$(ld.lld --version | head -n1 | sed 's/\"/\\\"/g')\""
    echo "}"
  } > ../build-meta.json
  log "Wrote: $WORKDIR/build-meta.json"
}

install_pkg() {
  need_root
  local img hdr
  img=$(ls -1 "$WORKDIR"/../linux-image-*${LOCALVER}_*.deb | tail -n1 || true)
  hdr=$(ls -1 "$WORKDIR"/../linux-headers-*${LOCALVER}_*.deb | tail -n1 || true)
  [ -n "${img:-}" ] || { echo "Image package not found"; exit 1; }
  log "Installing: $(basename "$img") $(basename "${hdr:-}")"
  dpkg -i "$img" ${hdr:+$hdr}
  update-grub || true
  log "Installed. Reboot when ready."
}

verify() {
  log "Kernel: $(uname -r)"
  echo "NUMA:"; (numactl --hardware 2>/dev/null || true) | sed 's/^/  /'
  echo "Mitigations:"; dmesg | egrep -i "pti|spectre|mds|retbleed|smep|smap" | tail -n10 | sed 's/^/  /'
  echo "IOMMU:"; dmesg | egrep -i "DMAR|IOMMU|VT-d" | tail -n10 | sed 's/^/  /'
  echo "PCIe AER:"; dmesg | egrep -i "AER:|pcieport" | tail -n10 | sed 's/^/  /'
  echo "Storage:"; lsblk -d -o NAME,ROTA,SIZE,MODEL,TRAN | sed 's/^/  /'
  echo "tg3 driver:"; for i in $(ls /sys/class/net 2>/dev/null | grep -v lo); do ethtool -i "$i" 2>/dev/null | sed "s/^/  [$i] /"; done
  echo "Bonding:"; for b in /proc/net/bonding/*; do [ -f "$b" ] && { echo "  === $(basename "$b") ==="; cat "$b" | sed 's/^/  /'; }; done
  echo "USB basics:"; lsmod | egrep 'usb_storage|usbhid' || echo "  (usb_storage/usbhid not loaded)"
  echo "Framebuffer:"; dmesg | egrep -i "mgag200|simplefb|framebuffer" | tail -n10 | sed 's/^/  /'
  echo "EDAC/MCE:"; dmesg | egrep -i "edac|mce" | tail -n10 | sed 's/^/  /'
  echo "MGLRU:"; [ -r /sys/kernel/mm/lru_gen/enabled ] && cat /sys/kernel/mm/lru_gen/enabled || echo "  (no lru_gen sysfs)"
  echo "eBPF posture:"; sysctl kernel.unprivileged_bpf_disabled 2>/dev/null || echo "  (sysctl not present; unpriv BPF disabled via Kconfig)"
  echo "ZFS:"; modinfo zfs 2>/dev/null | head -n3 || echo "  (zfs module not installed/loaded)"
}

zfs_dkms() {
  need_root
  log "Installing OpenZFS via DKMS..."
  apt-get update -y
  apt-get install -y zfs-dkms zfsutils-linux zfs-initramfs
  update-initramfs -u -k "$(uname -r)"
  log "ZFS DKMS installed & initramfs updated."
}

package_zfs() {
  need_root
  # Determine target kernel version
  local kver
  kver="$(dpkg -l | awk '/^ii\s+linux-image-.*'"${LOCALVER//-/\\.}"'/{print $2}' | sed 's/linux-image-//' | tail -n1)"
  if [ -z "$kver" ]; then
    kver="$(uname -r)"
    log "No installed image with ${LOCALVER}; using running kernel: $kver"
  else
    log "Target kernel for ZFS modules: $kver"
  fi

  # Get OpenZFS
  mkdir -p "$ZFS_WORKDIR"; cd "$ZFS_WORKDIR"
  local zver; zver="$(resolve_zfs_version)"
  if [ ! -d zfs ]; then
    log "Cloning OpenZFS ${zver}..."
    git clone --depth=1 --branch "zfs-${zver}" "$ZFS_SRC" zfs
  else
    cd zfs
    git fetch --depth=1 origin "zfs-${zver}" || true
    git checkout -f "zfs-${zver}" || git checkout -f "zfs-${zver#v}"
    git reset --hard; git clean -fdx
    cd ..
  fi

  cd zfs
  log "Configuring OpenZFS (kernel modules only)…"
  sh autogen.sh
  ./configure --with-config=kernel \
              --with-linux="/lib/modules/${kver}/build" \
              --with-linux-obj="/lib/modules/${kver}/build"
  log "Building OpenZFS modules…"
  make -j"${BUILDJOBS}"

  # Stage into a proper .deb
  local arch ver pkgname pkgdir deb
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
pkg="$DPKG_MAINTSCRIPT_PACKAGE"
# Extract kver from package name: zfs-modules-<kver>-<suffix>
kver="$(echo "$pkg" | sed 's/^zfs-modules-//; s/-[^-]*$//')"
depmod -a "$kver" || true
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k "$kver" || true
fi
exit 0
POSTINST
  chmod 0755 "$pkgdir/DEBIAN/postinst"

  cat > "$pkgdir/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
# Best-effort cleanup
depmod -a >/dev/null 2>&1 || true
exit 0
POSTRM
  chmod 0755 "$pkgdir/DEBIAN/postrm"

  deb="${pkgdir}.deb"
  dpkg-deb --build "$pkgdir" >/dev/null
  log "Built: ${deb}"
  echo
  echo "Install with:"
  echo "  sudo dpkg -i ${deb}"
  echo "  sudo apt-get install -y zfsutils-linux   # userspace (no DKMS)"
  echo
  echo "Secure Boot note: unsigned modules may not load; use MOK signing or disable SB."
}

variant() {
  need_root
  [ -f "$WORKDIR/config.final" ] || { echo "Run config first"; exit 1; }
  cd "$WORKDIR/linux"
  cp -f ../config.final .config
  log "Building passthrough IOMMU variant (-pt)…"
  scripts/config --disable IOMMU_DEFAULT_DMA_STRICT
  scripts/config --enable IOMMU_DEFAULT_PASSTHROUGH
  yes "" | make olddefconfig

  export LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang LD=ld.lld \
         AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  make -j"${BUILDJOBS}" bindeb-pkg \
       LOCALVERSION="${LOCALVER}-pt" DBUILD_VERBOSE=1 \
       ARCH=x86_64 DEB_BUILD_ARCH=amd64 DEB_BUILD_OPTIONS=parallel=${BUILDJOBS}
  log "Passthrough variant artifacts:"
  ls -1 ../linux-image-*${LOCALVER}-pt_*.deb ../linux-headers-*${LOCALVER}-pt_*.deb
}

patch_apply() {
  need_root
  [ $# -ge 1 ] || { echo "Usage: $0 patch-apply <sha> [sha ...]"; exit 1; }
  cd "$WORKDIR/linux"
  log "Cherry-picking: $*"
  set +e
  git cherry-pick -x "$@"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "Cherry-pick failed. Resolve conflicts or abort: git cherry-pick --abort"
    exit 1
  fi
  export LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang LD=ld.lld \
         AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  make -j"${BUILDJOBS}" bindeb-pkg \
       LOCALVERSION="${LOCALVER}-p$(git rev-parse --short HEAD)" DBUILD_VERBOSE=1 \
       ARCH=x86_64 DEB_BUILD_ARCH=amd64 DEB_BUILD_OPTIONS=parallel=${BUILDJOBS}
  log "Patched build complete."
}

clean_build() {
  need_root
  rm -rf "$WORKDIR/linux"
  log "Cleaned $WORKDIR/linux"
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
CONFIG_EXPERT=y
CONFIG_EMBEDDED=y
CONFIG_JUMP_LABEL=y

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
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
# CONFIG_CC_OPTIMIZE_FOR_SIZE is not set
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_CLANG_FULL is not set
# CONFIG_LTO_NONE is not set
# CONFIG_CFI_CLANG is not set
# CONFIG_INIT_STACK_ALL_ZERO is not set

# ===== Security / KSPP =====
CONFIG_SPECULATION_MITIGATIONS=y
CONFIG_PAGE_TABLE_ISOLATION=y
CONFIG_X86_SMEP=y
CONFIG_X86_SMAP=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_KSTACK_OFFSET=y
# CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT is not set
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT is not set
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=n
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=n
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=n
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=n
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=n
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
# CONFIG_COMPAT_32BIT_TIME is not set

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
# Prune other NIC vendors
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
