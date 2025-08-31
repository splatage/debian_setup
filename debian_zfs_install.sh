#!/bin/bash

DISKS=$(lsblk -ndo NAME,SIZE,TYPE,MODEL | grep -v "loop" | grep -v "sr" | awk '{if ($3 == "disk") print $1}')

if [ -z "$DISKS" ]; then
    echo "Attempting alternative disk detection..." >&2
    DISKS=$(lsblk -ndo NAME | grep -v "loop" | grep -v "sr" | while read -r LINE; do
        if [[ "$LINE" =~ ^[shv]d[a-z]$ ]]; then
            echo "$LINE"
        fi
    done)
fi

if [ -z "$DISKS" ]; then
    echo "No physical hard drives found on the system."
    exit 1
fi

echo "---"
echo "Available disks:"

COUNTER=1
declare -A DISK_MAP
for DISK in $DISKS; do
    if [ -b "/dev/$DISK" ]; then
        DISK_INFO=$(lsblk -ndo NAME,SIZE,MODEL /dev/"$DISK")
        echo "$COUNTER) $DISK_INFO"
        DISK_MAP[$COUNTER]="/dev/$DISK"
        ((COUNTER++))
    fi
done

if [ ${#DISK_MAP[@]} -eq 0 ]; then
    echo "No valid disks found for selection."
    exit 1
fi

echo "---"
echo "Enter the numbers of the disks you want to select, separated by spaces (e.g., 1 3):"
read -r USER_SELECTION

SELECTED_DISKS=()
for NUM in $USER_SELECTION; do
    if [[ -v DISK_MAP[$NUM] ]]; then
        SELECTED_DISKS+=("${DISK_MAP[$NUM]}")
    else
        echo "Warning: Number '$NUM' is not valid and will be ignored." >&2
    fi
done

echo "---"
if [ ${#SELECTED_DISKS[@]} -eq 0 ]; then
    echo "No disks selected."
    exit 1
else
    echo "You have selected the following disks:"
    for DISK in "${SELECTED_DISKS[@]}"; do
        echo "- $DISK"
    done
fi
echo "---"

echo "**WARNING**: Subsequent operations on the selected disks are **destructive** and will erase all data."
read -rp "Are you sure you want to proceed? (y/N): " CONFIRMATION

CONFIRMATION=${CONFIRMATION,,}

if [[ "$CONFIRMATION" != "y" ]]; then
    echo "Operation canceled by the user. No disks have been modified."
    exit 0
fi

echo "Choose booting type:"
echo "1) BIOS (Legacy)"
echo "2) UEFI"
read -rp "Enter your choice (1 or 2): " BOOT_CHOICE
echo "---"

echo "Do you want to use an encrypted partition for the main pool (rpool)?"
read -rp "Enter 'y' for yes, 'n' for no (y/N): " ENCRYPT_CHOICE
ENCRYPT_CHOICE=${ENCRYPT_CHOICE,,}
echo "---"

RAID_TYPE=""
if [ ${#SELECTED_DISKS[@]} -gt 1 ]; then
    echo "You have selected multiple disks. How do you want to configure the ZFS pool?"
    echo "1) Simple Mirror (raid1)"
    echo "2) RAID10 (striped mirrors)"
    echo "3) RAIDZ1"
    echo "4) RAIDZ2"
    echo "5) RAIDZ3"
    read -rp "Enter your choice (1-5): " RAID_CHOICE

    case "$RAID_CHOICE" in
        1) RAID_TYPE="mirror" ;;
        2) RAID_TYPE="raid10" ;;
        3) RAID_TYPE="raidz1" ;;
        4) RAID_TYPE="raidz2" ;;
        5) RAID_TYPE="raidz3" ;;
        *)
            echo "Invalid RAID choice. Defaulting to simple mirror." >&2
            RAID_TYPE="mirror"
            ;;
    esac
fi
echo "---"

for disk_path in "${SELECTED_DISKS[@]}"; do
    echo "Processing disk: $disk_path"

    wipefs -a "$disk_path" || true
    blkdiscard -f "$disk_path" || true
    sgdisk --zap-all "$disk_path" || true
    dd if=/dev/zero of="$disk_path" count=100 bs=512 || true

    sgdisk -Z "$disk_path"

    case "$BOOT_CHOICE" in
        1)
            echo "Configuring for BIOS (Legacy) booting on $disk_path..."
            sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$disk_path" # BIOS Boot Partition
            ;;
        2)
            echo "Configuring for UEFI booting on $disk_path..."
            sgdisk -n2:1M:+512M -t2:EF00 "$disk_path" # EFI System Partition
            ;;
        *)
            echo "Invalid booting choice for $disk_path. No boot partition created." >&2
            continue
            ;;
    esac

    echo "Creating data partition (Linux ZFS for bpool) on $disk_path..."
    sgdisk -n3:0:+1G -t3:BF01 "$disk_path" # bpool partition (for /boot)

    echo "Creating data partition (Linux ZFS for rpool) on $disk_path..."
    sgdisk -n4:0:0 -t4:BF00 "$disk_path" # rpool partition (for /)

    echo "Partitioning on $disk_path completed."
done

BPOOL_DEVICES=""
RPOOL_DEVICES=""
BOOT_PARTITION_NUMBER=""
BPOOL_PARTITION_NUMBER=3
RPOOL_PARTITION_NUMBER=4
EFI_PARTITION_NUMBER=2

case "$BOOT_CHOICE" in
    1) BOOT_PARTITION_NUMBER=1 ;;
    2) BOOT_PARTITION_NUMBER=$EFI_PARTITION_NUMBER ;;
esac

if [ ${#SELECTED_DISKS[@]} -eq 1 ]; then
    BPOOL_DEVICES="${SELECTED_DISKS[0]}${BPOOL_PARTITION_NUMBER}"
    RPOOL_DEVICES="${SELECTED_DISKS[0]}${RPOOL_PARTITION_NUMBER}"
elif [ ${#SELECTED_DISKS[@]} -gt 1 ]; then
    case "$RAID_TYPE" in
        mirror)
            BPOOL_DEVICES="mirror"
            RPOOL_DEVICES="mirror"
            for disk_path in "${SELECTED_DISKS[@]}"; do
                BPOOL_DEVICES+=" ${disk_path}${BPOOL_PARTITION_NUMBER}"
                RPOOL_DEVICES+=" ${disk_path}${RPOOL_PARTITION_NUMBER}"
            done
            ;;
        raid10)
            if [ $(( ${#SELECTED_DISKS[@]} % 2 )) -ne 0 ]; then
                echo "Warning: For RAID10, an even number of disks is highly recommended. Proceeding with potentially unoptimized configuration." >&2
            fi
            local_bpool_devices=""
            local_rpool_devices=""
            for (( i=0; i<${#SELECTED_DISKS[@]}; i+=2 )); do
                DISK1_BPOOL="${SELECTED_DISKS[$i]}${BPOOL_PARTITION_NUMBER}"
                DISK1_RPOOL="${SELECTED_DISKS[$i]}${RPOOL_PARTITION_NUMBER}"

                if [ $(( i+1 )) -lt ${#SELECTED_DISKS[@]} ]; then
                    DISK2_BPOOL="${SELECTED_DISKS[$((i+1))]}${BPOOL_PARTITION_NUMBER}"
                    DISK2_RPOOL="${SELECTED_DISKS[$((i+1))]}${RPOOL_PARTITION_NUMBER}"
                    local_bpool_devices+=" mirror ${DISK1_BPOOL} ${DISK2_BPOOL}"
                    local_rpool_devices+=" mirror ${DISK1_RPOOL} ${DISK2_RPOOL}"
                else
                    echo "Warning: Disk ${SELECTED_DISKS[$i]} is a single disk in RAID10 configuration, this is not ideal." >&2
                    local_bpool_devices+=" ${DISK1_BPOOL}"
                    local_rpool_devices+=" ${DISK1_RPOOL}"
                fi
            done
            BPOOL_DEVICES=$(echo "$local_bpool_devices" | xargs) # Rimuove spazi extra iniziali/finali
            RPOOL_DEVICES=$(echo "$local_rpool_devices" | xargs) # Rimuove spazi extra iniziali/finali
            ;;
        raidz1|raidz2|raidz3)
            BPOOL_DEVICES="$RAID_TYPE"
            RPOOL_DEVICES="$RAID_TYPE"
            for disk_path in "${SELECTED_DISKS[@]}"; do
                BPOOL_DEVICES+=" ${disk_path}${BPOOL_PARTITION_NUMBER}"
                RPOOL_DEVICES+=" ${disk_path}${RPOOL_PARTITION_NUMBER}"
            done
            ;;
    esac
fi

echo "Creating bpool..."
echo "bpool command in execution: zpool create -f -o ashift=12 -o autotrim=on -o compatibility=grub2 -o cachefile=/etc/zfs/zpool.cache -O devices=off -O acltype=posixacl -O xattr=sa -O compression=lz4 -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/boot -R /mnt bpool ${BPOOL_DEVICES}"
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/boot -R /mnt \
    bpool ${BPOOL_DEVICES}

echo "---"
if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
    echo "Creating rpool (encrypted)..."
    echo "rpool (encrypted) command in execution: zpool create -f -o ashift=12 -o autotrim=on -O encryption=on -O keylocation=prompt -O keyformat=passphrase -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/ -R /mnt rpool ${RPOOL_DEVICES}"
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/ -R /mnt \
        rpool ${RPOOL_DEVICES}
else
    echo "Creating rpool (unencrypted)..."
    echo "rpool (unencrypted) command in execution: zpool create -f -o ashift=12 -o autotrim=on -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/ -R /mnt rpool ${RPOOL_DEVICES}"
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/ -R /mnt \
        rpool ${RPOOL_DEVICES}
fi

echo "---"
echo "ZFS operations completed."
echo "Exporting and re-importing bpool and rpool by ID..."
zpool export bpool
zpool export rpool

# Let udev finish creating /dev/disk/by-id symlinks
udevadm settle || sleep 1

zpool import -d /dev/disk/by-id -R /mnt bpool
zpool import -d /dev/disk/by-id -R /mnt rpool

echo "Starting Debian 12 (Bookworm) operating system installation phase..."

echo "Creating ZFS filesystems for root (rpool/ROOT) and boot (bpool/BOOT)..."
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

echo "Creating and mounting root filesystem (rpool/ROOT/debian)..."
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian

echo "Creating and mounting boot filesystem (bpool/BOOT/debian)..."
zfs create -o mountpoint=/boot bpool/BOOT/debian

echo "Preparing chroot environment in /mnt..."
mkdir -p /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock

echo "Starting debootstrap to install Debian Bookworm..."
debootstrap bookworm /mnt

echo "Copying zpool.cache file to /mnt/etc/zfs..."
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

echo "Base operating system installation phase completed."
echo "---"

echo "Starting system configuration phase..."

echo "Configuring hostname in /mnt/etc/hostname..."
echo "srv-deb12-ccc" > /mnt/etc/hostname

echo "Copying /etc/network/interfaces to /mnt/etc/network/interfaces..."
cp /etc/network/interfaces /mnt/etc/network/interfaces || echo "Warning: /etc/network/interfaces not found on the live system. It may need to be configured manually later."

echo "Configuring /mnt/etc/apt/sources.list..."
cat <<EOF_SOURCES > /mnt/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb-src http://deb.debian.org/debian bookworm main contrib non-free-firmware

deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
deb-src http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware

deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
EOF_SOURCES

echo "Mounting virtual directories for chroot environment..."
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

CHROOT_SCRIPT="/tmp/chroot_install_script.sh"
cat << 'CHROOT_EOF' > "/mnt${CHROOT_SCRIPT}"
#!/bin/bash

BOOT_CHOICE="$BOOT_CHOICE"
IFS=' ' read -r -a SELECTED_DISKS_ARRAY <<< "$SELECTED_DISKS_STR"
EFI_PARTITION_NUMBER="$EFI_PARTITION_NUMBER"

echo "Updating packages inside chroot..."
apt update

echo "Installing base packages (console-setup, locales) inside chroot..."
apt install --yes console-setup locales

echo "Reconfiguring locales, tzdata, keyboard-configuration, console-setup inside chroot..."
echo "en_NZ.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

echo "LANG=en_NZ.UTF-8" > /etc/default/locale
echo "LC_ALL=en_NZ.UTF-8" >> /etc/default/locale
update-locale LANG=en_NZ.UTF-8

# New Zealand timezone
echo "Pacific/Auckland" > /etc/timezone
ln -sf /usr/share/zoneinfo/Pacific/Auckland /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata


echo 'KEYMAP="us"' > /etc/vconsole.conf
dpkg-reconfigure --frontend noninteractive keyboard-configuration

dpkg-reconfigure --frontend noninteractive console-setup

echo "Installing ZFS packages (dpkg-dev, linux-headers-amd64, linux-image-amd64) inside chroot..."
apt install --yes dpkg-dev linux-headers-amd64 linux-image-amd64

echo "Installing zfs-initramfs inside chroot..."
apt install --yes zfs-initramfs

echo "Configuring DKMS for ZFS inside chroot..."
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

echo "Installing GRUB packages (grub-pc or grub-efi-amd64/shim-signed) inside chroot..."
if [[ "$BOOT_CHOICE" == "1" ]]; then
    apt install --yes grub-pc
elif [[ "$BOOT_CHOICE" == "2" ]]; then
    apt install --yes dosfstools grub-efi-amd64 shim-signed
fi

echo "Setting root password. You will be prompted for the password twice."
passwd

echo "Creating and enabling zfs-import-bpool.service..."
mkdir -p /etc/systemd/system/zfs-import.target.wants/
cat <<'EOF_BPOOL_SERVICE' > /etc/systemd/system/zfs-import-bpool.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
EOF_BPOOL_SERVICE
systemctl enable zfs-import-bpool.service

echo "Installing additional packages: apache2-utils aptitude bc curl curl ethtool fio git ifenslave ifupdown iperf3 ipmitool jq libnuma1 libnuma-dev man moreutils nmon ntp numactl numad numatop openssh-server pciutils redis redis-tools screen sysbench sysstat tmux wrk ..."
apt install --yes apache2-utils aptitude bc curl curl ethtool fio git ifenslave ifupdown iperf3 ipmitool jq libnuma1 libnuma-dev man moreutils nmon ntp numactl numad numatop openssh-server pciutils redis redis-tools screen sysbench sysstat tmux wrk
echo "Configuring root key-only SSH..."
# Ensure .ssh exists and install the provided pubkey
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF_KEY'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDuvy5rjZTWJjWmqm914KD/AKmjX/LEp04taj3aOpfGtbdc7i57d16EimGVsBaHx9xVoVxUNFBZGS4pqAwlyzI86Ttnw5+kl33V+Y71V0pUQ51h443c+ufZFe2lXI5PULboYR0FfRz3/hmCyLdj5XGR5QbTNyuKRd4VBa0OmmB7ODv1MdN+tmiDNDvcZ4wJ5WCay6x3bQJjPDdvYtCMtuQSCHSvZL1n2QW0jlUjUGcbfxyhvfXr7NN8xSz6zT3lj8azfWdMPyyfcX7b9Vu2S0vmjlRSpBKqXz/ifqTEwNEGAUcR7d9S24AqLQ8gHupxKYBTyypGDoNMFVZ5vlM6hzyllD936Tsva2/85sJECELkrN2FFi8EQPKNgFZ+pNavhwcHWNiLF6rk68GEc3BQDqZ12Ei9cqAEZ5sOhTTCYcoK6+paPa+j2+zsgJ/Ct70ZN82J3mETCHxntKvXx0VxxCWH/5M+jhRnJR/XpkJb4kadm3EKSCurwdMfmPLN6RP8NW0=
EOF_KEY
chmod 600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh

# Harden sshd via drop-in, do not edit main config
install -o root -g root -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-root-keyonly.conf <<'EOF_SSHD'
# Managed by installer
Port 22
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 20
MaxAuthTries 3
UseDNS no
AllowAgentForwarding no
PrintLastLog yes
EOF_SSHD

systemctl enable ssh
systemctl restart ssh || true

echo "Setting rpool/ROOT/debian as root filesystem..."
zfs set canmount=noauto rpool/ROOT/debian

echo "Mounting ZFS filesystems for GRUB and initramfs..."
zfs set canmount=on rpool/ROOT/debian
zfs mount rpool/ROOT/debian
zfs set canmount=on bpool/BOOT/debian
zfs mount bpool/BOOT/debian
zfs mount -a

echo "Configuring GRUB_CMDLINE_LINUX in /etc/default/grub for ZFS..."
sed -i 's|^GRUB_CMDLINE_LINUX=""|GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"|' /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX="[^"]*"|GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"|' /etc/default/grub

echo "Verifying ZFS recognition by grub-probe /boot..."
grub-probe /boot || echo "Warning: grub-probe /boot returned an error. There might be an issue with ZFS recognition."

echo "Refreshing initramfs..."
update-initramfs -c -k all

echo "Updating GRUB..."
update-grub

echo "Installing GRUB bootloader (configuring on disks)..."

if [[ "$BOOT_CHOICE" == "1" ]]; then
    for DISK_PATH_IN_CHROOT in "${SELECTED_DISKS_ARRAY[@]}"; do
        echo "Executing grub-install for BIOS on ${DISK_PATH_IN_CHROOT}..."
        grub-install "$DISK_PATH_IN_CHROOT"
    done

elif [[ "$BOOT_CHOICE" == "2" ]]; then
    echo "Creating /boot/efi directory..."
    mkdir -p /boot/efi

    for DISK_PATH_IN_CHROOT in "${SELECTED_DISKS_ARRAY[@]}"; do
        EFI_PART_IN_CHROOT="${DISK_PATH_IN_CHROOT}${EFI_PARTITION_NUMBER}"
        echo "Processing EFI partition: ${EFI_PART_IN_CHROOT}"

        if [ -b "${EFI_PART_IN_CHROOT}" ]; then
            if mountpoint -q /boot/efi; then
                umount /boot/efi
                echo "/boot/efi partition unmounted before remount."
            fi

            mkdosfs -F 32 -s 1 -n EFI "${EFI_PART_IN_CHROOT}"

            mount "${EFI_PART_IN_CHROOT}" /boot/efi
            echo "EFI partition ${EFI_PART_IN_CHROOT} mounted on /boot/efi."

            if ! grep -q "/boot/efi" /etc/fstab; then
                EFI_UUID=$(blkid -s UUID -o value "${EFI_PART_IN_CHROOT}")
                echo "UUID=${EFI_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
                echo "Added EFI entry to /etc/fstab: ${EFI_UUID}"
            else
                echo "/boot/efi already present in /etc/fstab."
            fi

            echo "Executing grub-install on ${DISK_PATH_IN_CHROOT}..."
            #grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --recheck "$DISK_PATH_IN_CHROOT"
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck "$DISK_PATH_IN_CHROOT"

            echo "GRUB-EFI installation completed for ${DISK_PATH_IN_CHROOT}."
        else
            echo "Warning: EFI partition ${EFI_PART_IN_CHROOT} not found or invalid. Skipping."
        fi
    done

    if mountpoint -q /boot/efi; then
        umount /boot/efi
        echo "/boot/efi partition unmounted."
    fi

else
    echo "Warning: Invalid booting choice. GRUB packages will not be automatically configured."
fi

echo "Configuring ZFS mount order..."
mkdir -p /etc/zfs/zfs-list.cache
zfs set cachefile=/etc/zfs/zpool.cache bpool
zfs set cachefile=/etc/zfs/zpool.cache rpool
zpool set cachefile=/etc/zfs/zpool.cache bpool
zpool set cachefile=/etc/zfs/zpool.cache rpool

zfs list -t filesystem -o name,mountpoint,canmount > /dev/null

echo "Removing '/mnt' from paths in zfs-list.cache files..."
if [ -n "$(find /etc/zfs/zfs-list.cache -type f 2>/dev/null)" ]; then
    sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
else
    echo "No files found in /etc/zfs/zfs-list.cache/ for modification."
fi

zfs set canmount=noauto rpool/ROOT/debian
zfs set canmount=noauto bpool/BOOT

rm "$CHROOT_SCRIPT"
CHROOT_EOF

chmod +x "/mnt${CHROOT_SCRIPT}"

echo "Entering chroot environment for final configuration..."
chroot /mnt /usr/bin/env \
    BOOT_CHOICE="$BOOT_CHOICE" \
    SELECTED_DISKS_STR="${SELECTED_DISKS[*]}" \
    EFI_PARTITION_NUMBER="$EFI_PARTITION_NUMBER" \
    bash "${CHROOT_SCRIPT}"

echo "Exiting chroot environment."
echo "---"

echo "Starting cleanup and finalization phase..."

echo "Operations inside chroot completed."

echo "Unmounting mounted directories..."
mount | grep -w /mnt | awk '{print $3}' | sort -r | xargs -r umount || true

echo "Unmounting all ZFS filesystems from mount points..."
zfs umount -a || true

echo "Exporting ZFS pools..."
grep [p]ool /proc/*/mounts | cut -d/ -f3 | uniq | xargs kill
zpool export -a

echo "---"
echo "Installation and configuration complete. You can now reboot the system."
echo "Remove the live installation medium before rebooting."
echo "---"
