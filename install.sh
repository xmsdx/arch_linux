#!/bin/bash
#
# Arch Linux Installation Script for Dell XPS 13 9365 (NVMe SSD)
#
# This script automates the installation of a minimal Arch Linux system
# using BTRFS with subvolumes, GRUB as the bootloader, and Snapper for
# snapshot management.
#
# IMPORTANT: RUN THIS SCRIPT ONLY AFTER BOOTING THE ARCH LIVE ISO.
# This script assumes the NVMe SSD is identified as /dev/nvme0n1.
# Running this script will ERASE ALL DATA on the target disk!
#

# --- 1. CONFIGURATION VARIABLES ---
# -----------------------------------------------------------------------------

# Primary Disk (Adjust if necessary, e.g., sda)
DISK="/dev/nvme0n1"

# Hostname
HOSTNAME="xps013"

# User Details
USER_NAME="msd"
USER_PASS="abc123" # WARNING: Change this password immediately after rebooting!

# Locale/Timezone
TIMEZONE="America/Denver" # Adjust to your local timezone
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Packages - Minimal base + BTRFS, GRUB, Snapper, Network, Sudo, Git, Nano
PACKAGES=(
    base
    linux
    linux-firmware
    btrfs-progs
    grub
    efibootmgr
    snapper
    dhcpcd
    sudo
    git
    nano
)

# --- 2. PRE-INSTALLATION CHECKS (Live Environment) ---
# -----------------------------------------------------------------------------

echo "--- Pre-installation Checks ---"

# Verify target disk exists
if [ ! -b "$DISK" ]; then
    echo "ERROR: Disk $DISK not found. Exiting."
    exit 1
fi

# Verify essential tools for the live environment
if ! command -v pacstrap &> /dev/null || ! command -v fdisk &> /dev/null || ! command -v git &> /dev/null; then
    echo "ERROR: Required utilities (pacstrap, fdisk, git) not found. Did you install 'git' in the live environment?"
    exit 1
fi

# Attempt to ensure network connectivity using dhcpcd (Wired/Default Arch ISO method)
echo "Ensuring network connectivity via dhcpcd..."
dhcpcd || echo "WARNING: dhcpcd failed. Please ensure your network connection (wired or wireless) is active before proceeding."

# Final confirmation before proceeding to wipe the disk
echo "Target disk: $DISK"
read -r -p "This will wipe all data on $DISK. Are you sure? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "Aborted by user."
    exit 0
fi

# --- 3. PARTITIONING (GPT) ---
# -----------------------------------------------------------------------------

echo "--- Partitioning $DISK (GPT) ---"

# Clear existing partition table and create a new GPT table
echo "Clearing partition table..."
sgdisk --zap-all "$DISK"

# 1. EFI System Partition (512 MiB, required for UEFI boot)
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI System Partition" "$DISK"

# 2. Linux Root Partition (Rest of the disk, BTRFS) - Dynamic Sizing
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux Root BTRFS" "$DISK"

# Refresh partition table
partprobe "$DISK"
sleep 2

# Define partition variables
EFI_PART="${DISK}p1"
BTRFS_PART="${DISK}p2"

echo "Partitions created:"
echo "  $EFI_PART (EFI)"
echo "  $BTRFS_PART (BTRFS Root)"

# --- 4. FILESYSTEM FORMATTING ---
# -----------------------------------------------------------------------------

echo "--- Formatting Filesystems ---"

# Format EFI Partition (FAT32)
mkfs.fat -F 32 "$EFI_PART"

# Format BTRFS Partition
# 'f' forces overwrite, 'L' sets a label
mkfs.btrfs -f -L arch_root "$BTRFS_PART"

# --- 5. BTRFS SUBVOLUME CREATION AND MOUNTING ---
# -----------------------------------------------------------------------------

echo "--- Creating and Mounting BTRFS Subvolumes ---"

# Set mount point for the temporary BTRFS root
BTRFS_MOUNT="/mnt/btrfs_temp"
mkdir -p "$BTRFS_MOUNT"

# Mount the main BTRFS partition temporarily
mount -o defaults,noatime "$BTRFS_PART" "$BTRFS_MOUNT"

# Create essential subvolumes
# @: Root filesystem
# @home: User home directories (excluded from root snapshots)
# @snapshots: Default location for Snapper (holds snapshots of @)
# @var_log: For system logs (excluded from snapshots to reduce writes/size)
btrfs subvolume create "$BTRFS_MOUNT"/@
btrfs subvolume create "$BTRFS_MOUNT"/@home
btrfs subvolume create "$BTRFS_MOUNT"/@snapshots
btrfs subvolume create "$BTRFS_MOUNT"/@var_log

# Unmount the temporary root
umount "$BTRFS_MOUNT"

# Create the final mounting structure
mkdir -p /mnt
# Mount root subvolume
mount -o defaults,noatime,compress=zstd:3,discard=async,subvol=@ "$BTRFS_PART" /mnt
mkdir -p /mnt/{boot/efi,home,.snapshots,var/log}

# Mount remaining subvolumes
mount -o defaults,noatime,compress=zstd:3,discard=async,subvol=@home "$BTRFS_PART" /mnt/home
mount -o defaults,noatime,compress=zstd:3,discard=async,subvol=@snapshots "$BTRFS_PART" /mnt/.snapshots
mount -o defaults,noatime,compress=zstd:3,discard=async,subvol=@var_log "$BTRFS_PART" /mnt/var/log

# Mount the EFI partition
mount "$EFI_PART" /mnt/boot/efi

# Set permissions for Snapper's default mount point
chmod 750 /mnt/.snapshots

# --- 6. BASE SYSTEM INSTALLATION ---
# -----------------------------------------------------------------------------

echo "--- Installing Base System and Packages ---"

# Set parallel downloads for faster pacstrap
sed -i 's/^#Para/#Para/' /etc/pacman.conf

# Install base system, kernel, firmware, and selected utilities
pacstrap /mnt "${PACKAGES[@]}"

# --- 7. SYSTEM CONFIGURATION (Chroot Prep) ---
# -----------------------------------------------------------------------------

echo "--- Generating fstab ---"

# Generate fstab. Ensure non-disk partitions (USB, tmpfs) are filtered out.
genfstab -U -p /mnt | grep -v 'swap' | grep -v 'tmpfs' > /mnt/etc/fstab

# Add tmpfs for /tmp (best practice for Arch)
echo 'tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0' >> /mnt/etc/fstab

# Add BTRFS mount options to fstab for SSD optimization and compression
sed -i 's/defaults/defaults,noatime,compress=zstd:3,discard=async/' /mnt/etc/fstab
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab # Remove subvolid, rely only on subvol name

cat /mnt/etc/fstab
echo "fstab generated. Reviewing for correctness..."

# --- 8. POST-INSTALLATION SCRIPT (Executed via arch-chroot) ---
# -----------------------------------------------------------------------------

echo "--- Entering arch-chroot for final configuration ---"

# Define the chroot script content
cat << EOF > /mnt/arch_chroot_setup.sh
#!/bin/bash
#
# CHROOT Configuration Script
#

# 8.1 Timezone and Hardware Clock
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# 8.2 Localization
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# 8.3 Network Configuration
echo "${HOSTNAME}" > /etc/hostname
# Enable DHCP client
systemctl enable dhcpcd

# 8.4 Root Password (Optional, setting it just in case)
echo "root:abc123" | chpasswd

# 8.5 GRUB Bootloader Installation (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchLinux --recheck --no-floppy

# Generate GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg

# 8.6 mkinitcpio (Default kernel images are fine)
mkinitcpio -P

# 8.7 Snapper Setup
echo "Creating Snapper configuration for root..."
snapper -c root create-config /

# Modify Snapper config to use BTRFS root subvolume location
sed -i 's/SUBVOLUME="\/mnt\//SUBVOLUME="\//' /etc/snapper/configs/root

# Enable Snapper services for timeline and cleanup
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# 8.8 User Configuration
# Create the sudo user with bash shell
useradd -m -g users -G wheel -s /bin/bash ${USER_NAME}
echo "${USER_NAME}:${USER_PASS}" | chpasswd

# Enable 'wheel' group to use sudo without a password prompt
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# 8.9 Default Editor Setup (for the new user)
# Set VISO/EDITOR for root
echo "VISUAL=nano" >> /etc/environment
echo "EDITOR=nano" >> /etc/environment

# 8.10 User Profile Logic
# Create the .profile for the new user
cat << EOPROFILE > /home/${USER_NAME}/.profile
# .profile: executed by the command interpreter for login shells.
# This file is not read by bash when ~/.bash_profile or ~/.bash_login exists.

# Set default editor globally for the user
export EDITOR=nano

if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Define path for git downloads
export PATH="\$HOME/bin:\$PATH"
EOPROFILE

chown -R ${USER_NAME}:users /home/${USER_NAME}

# Remove the temporary setup script
rm /arch_chroot_setup.sh

echo "CHROOT configuration complete. System ready to reboot."

EOF

# Execute the chroot script
arch-chroot /mnt /bin/bash /arch_chroot_setup.sh

# --- 9. FINAL STEPS ---
# -----------------------------------------------------------------------------

echo "--- Finalizing Installation ---"

# Unmount all file systems
umount -R /mnt

echo "Installation complete. The system is ready to be rebooted."
echo "Please type 'reboot' now. The initial user is '${USER_NAME}' with password '${USER_PASS}'."
echo "Remember to run 'git clone <repo>' after logging in to download additional files."

# End of script
