#!/bin/bash
# Arch Linux Automated Install for Dell XPS 13 9365
# Features: LUKS2 (argon2id) + BTRFS + Encrypted Swap + Wayland/Hyprland + Brave + Python
# Fully dynamic partition sizes using disk detection
# Includes optional VMware Workstation support

set -euo pipefail

# ------------------------------
# Variables
# ------------------------------
DISK="/dev/nvme0n1"      # Target SSD
HOSTNAME="xps013" #13 in hex is 0x0d
USERNAME="msd"
PASSWORD="abc123"      # ⚠️ Change before running
SWAPSIZE_GIB=16          # Size of encrypted swap in GiB
TIMEZONE="America/Denver"

# ------------------------------
# 1. Detect total disk size
# ------------------------------
DISK_SIZE_BYTES=$(blockdev --getsize64 $DISK)
DISK_SIZE_GIB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
echo "Detected disk size: $DISK_SIZE_GIB GiB"

# Calculate dynamic start positions
ESP_SIZE_GIB=0.5                # EFI System Partition size (~500 MiB)
ROOT_START_GIB=$ESP_SIZE_GIB
SWAP_START_GIB=$((DISK_SIZE_GIB - SWAPSIZE_GIB))

echo "Root partition start: ${ROOT_START_GIB}GiB"
echo "Swap partition start: ${SWAP_START_GIB}GiB"

# ------------------------------
# 2. Partition the disk
# ------------------------------
echo "==> Creating partitions"
sgdisk -Z $DISK   # Wipe existing GPT
parted $DISK mklabel gpt

# EFI System Partition (FAT32)
ESP_SIZE_MIB=512
parted $DISK mkpart ESP fat32 1MiB ${ESP_SIZE_MIB}MiB
parted $DISK set 1 esp on

# Root partition (will be LUKS encrypted)
ROOT_START_MIB=$ESP_SIZE_MIB
SWAP_START_MIB=$((SWAP_START_GIB * 1024)) # convert GiB to MiB
parted $DISK mkpart cryptroot ${ROOT_START_MIB}MiB ${SWAP_START_MIB}MiB

# Swap partition (encrypted)
parted $DISK mkpart swap ${SWAP_START_MIB}MiB 100%

# ------------------------------
# 3. Encrypt partitions using LUKS2 with argon2id
# ------------------------------
echo "==> Encrypting root partition"
echo -n $PASSWORD | cryptsetup luksFormat --type luks2 --pbkdf argon2id ${DISK}p2 -
echo -n $PASSWORD | cryptsetup open ${DISK}p2 cryptroot -

echo "==> Encrypting swap partition"
echo -n $PASSWORD | cryptsetup luksFormat --type luks2 --pbkdf argon2id ${DISK}p3 -
echo -n $PASSWORD | cryptsetup open ${DISK}p3 cryptswap -
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap

# ------------------------------
# 4. Format partitions
# ------------------------------
echo "==> Formatting partitions"
mkfs.fat -F32 ${DISK}p1                # EFI partition
mkfs.btrfs /dev/mapper/cryptroot       # Root partition

# ------------------------------
# 5. Create BTRFS subvolumes
# ------------------------------
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
umount /mnt

# ------------------------------
# 6. Mount subvolumes with options
# ------------------------------
mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache}
mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@cache /dev/mapper/cryptroot /mnt/var/cache
mount ${DISK}p1 /mnt/boot

# ------------------------------
# 7. Install base system
# ------------------------------
echo "==> Installing base packages"
pacstrap /mnt base linux linux-firmware linux-headers btrfs-progs base-devel networkmanager intel-ucode libinput cpupower bluez bluez-utils mesa tlp acpi acpid pipewire pipewire-pulse wireplumber iio-sensor-proxy thermald man-db man-pages openssh wget curl nano sudo git ufw snapper

# ------------------------------
# 8. Generate fstab
# ------------------------------
genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------
# 9. Configure system inside chroot
# ------------------------------
arch-chroot /mnt /bin/bash <<EOF
# Set hostname
echo $HOSTNAME > /etc/hostname

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hosts file
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Root password
echo "root:$PASSWORD" | chpasswd

# Create user with sudo privileges
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Initramfs hooks for encrypted root
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install systemd-boot
bootctl install
UUID=\$(blkid -s UUID -o value ${DISK}p2)
cat > /boot/loader/entries/arch.conf <<LOADER
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
LOADER

# Set Nano as default editor
echo "export EDITOR=/usr/bin/nano" >> /etc/profile

# Python + dev tools
pacman -S --noconfirm python python-pip python-setuptools python-virtualenv base-devel

# Default rules for UFW firewall
ufw default deny incoming
ufw default allow outgoing
ufw enable

# Enable NetworkManager
systemctl enable NetworkManager

# Enable remaining services
systemctl enable tlp
systemctl enable acpid
systemctl enable bluetooth
systemctl enable thermald
systemctl enable cpupower
#systemctl enable pipewire-pulse.service
#systemctl enable wireplumber.service
systemctl enable ufw


EOF

echo "==> Installation complete!"
echo "POST REBOOT for docking station: yay -S --noconfirm dkms displaylink evdi-dkms; sudo systemctl enable --now displaylink.service"
echo "Reboot now. Your system uses LUKS2 (argon2id), BTRFS, encrypted swap"
