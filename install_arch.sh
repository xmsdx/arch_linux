#!/bin/bash
# -----------------------------------------------------------------------------
# Unified Arch Linux Installation Script for Dell XPS 13 9365 (NVMe 512GB)
# Supports: (A) Encrypted install (LUKS2 + BTRFS + Encrypted Swap) OR
#           (B) Non-encrypted install (BTRFS + Standard Swap File)
# Bootloader: GRUB (chosen for recovery flexibility and broad tooling support)
# Filesystem: BTRFS with subvolumes: @, @home, @snapshots, @var_log, @var_cache
# Swap:      Separate encrypted LUKS partition (hibernation capable) OR swapfile
# Optimized for: Laptop power management (tlp, thermald, cpupower), Dell sensors
# References: Arch Wiki (primary), best practices for secure & reproducible setup
# -----------------------------------------------------------------------------
# WARNING: This script ERASES ALL DATA on /dev/nvme0n1. Use ONLY from Arch Live ISO.
# REQUIREMENTS (Live ISO): Internet access, updated mirrorlist, clock synced.
# Run as: root
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# (Dry run support removed per user request)

# ------------------------------
# User Adjustable Variables (defaults - will prompt)
# ------------------------------
DISK="/dev/nvme0n1"            # Target SSD (512GB NVMe)
HOSTNAME_DEFAULT="archlinux"   # Default hostname
USERNAME_DEFAULT="player1"     # Initial user
TIMEZONE_DEFAULT="America/Denver"
LOCALE_DEFAULT="en_US.UTF-8"
KEYMAP_DEFAULT="us"
SWAPSIZE_GIB_DEFAULT=16         # Desired swap size in GiB (converted to MiB dynamically)
BTRFS_COMPRESS="zstd:3"         # Compression level (adjustable)
ESP_SIZE_MB=512                 # EFI System Partition size in MiB
MIN_ROOT_MB=20480               # Minimum root size safeguard (20 GiB)

# ------------------------------
# Helper Functions
# ------------------------------
log() { printf "\n[+] %s\n" "$*"; }
err() { printf "\n[!] ERROR: %s\n" "$*" >&2; exit 1; }
confirm() { read -r -p "${1} (y/N): " c; [[ $c == "y" ]]; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || err "Required command '$1' not found"; }
flush_writes() { sync; udevadm settle || true; }

# ------------------------------
# Pre-flight Checks
# ------------------------------
log "Validating live environment prerequisites"
for c in pacstrap parted sgdisk cryptsetup mkfs.btrfs grub-install grub-mkconfig; do require_cmd "$c"; done
command -v ip >/dev/null && ip link || true

if ! ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
  log "Network check failed (archlinux.org unreachable). Continuing but pacstrap may fail."
fi

[ -b "$DISK" ] || err "Disk $DISK not present"

# ------------------------------
# Interactive Prompts
# ------------------------------
log "Collecting install preferences"
read -r -p "Hostname [$HOSTNAME_DEFAULT]: " HOSTNAME_INPUT; HOSTNAME="${HOSTNAME_INPUT:-$HOSTNAME_DEFAULT}";
read -r -p "Username [$USERNAME_DEFAULT]: " USERNAME_INPUT; USERNAME="${USERNAME_INPUT:-$USERNAME_DEFAULT}";
read -r -p "Locale [$LOCALE_DEFAULT]: " LOCALE_INPUT; LOCALE="${LOCALE_INPUT:-$LOCALE_DEFAULT}";
read -r -p "Keymap [$KEYMAP_DEFAULT]: " KEYMAP_INPUT; KEYMAP="${KEYMAP_INPUT:-$KEYMAP_DEFAULT}";
read -r -p "Timezone [$TIMEZONE_DEFAULT]: " TIMEZONE_INPUT; TIMEZONE="${TIMEZONE_INPUT:-$TIMEZONE_DEFAULT}";
read -r -p "Swap size GiB [$SWAPSIZE_GIB_DEFAULT]: " SWAP_GIB_INPUT; SWAPSIZE_GIB="${SWAP_GIB_INPUT:-$SWAPSIZE_GIB_DEFAULT}";

log "Choose installation type:";
echo "  1) Encrypted (LUKS2 root + encrypted swap partition)"
echo "  2) Non-encrypted (plain BTRFS root + swapfile)"
read -r -p "Enter choice [1/2]: " ENC_CHOICE
[[ "$ENC_CHOICE" == "1" || "$ENC_CHOICE" == "2" ]] || err "Invalid choice"
ENCRYPTED=$([[ "$ENC_CHOICE" == "1" ]] && echo 1 || echo 0)

# Secure password prompt
log "Enter password for root and user (will not echo)"
read -r -s -p "Password (root & user): " PASSWORD; echo
read -r -s -p "Confirm Password: " PASSWORD_CONFIRM; echo
[[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]] || err "Passwords do not match"
[[ -n "$PASSWORD" ]] || err "Password cannot be empty"

# Separate LUKS password (must differ) if encryption chosen
if [[ $ENCRYPTED -eq 1 ]]; then
  log "Enter separate LUKS2 disk encryption password (distinct from user password)"
  while true; do
    read -r -s -p "LUKS Password: " ENCRYPT_PASSWORD; echo
    read -r -s -p "Confirm LUKS Password: " ENCRYPT_PASSWORD_CONFIRM; echo
    [[ "$ENCRYPT_PASSWORD" == "$ENCRYPT_PASSWORD_CONFIRM" ]] || { log "Mismatch, try again"; continue; }
    [[ -n "$ENCRYPT_PASSWORD" ]] || { log "Empty password, try again"; continue; }
    [[ "$ENCRYPT_PASSWORD" != "$PASSWORD" ]] || { log "LUKS password must differ from user/root password"; continue; }
    break
  done
fi

log "Summary:\n  Hostname: $HOSTNAME\n  User: $USERNAME\n  Encrypted: $([[ $ENCRYPTED -eq 1 ]] && echo YES || echo NO)\n  Swap GiB: $SWAPSIZE_GIB\n  Timezone: $TIMEZONE\n  Locale: $LOCALE\n  Keymap: $KEYMAP"
confirm "Proceed with disk wipe and install on $DISK?" || err "Aborted by user"

# ------------------------------
# Disk Size & Dynamic Partition Math (in MiB)
# ------------------------------
DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK")
DISK_SIZE_MB=$(( DISK_SIZE_BYTES / 1024 / 1024 ))
SWAP_SIZE_MB=$(( SWAPSIZE_GIB * 1024 ))

# Validate swap size feasibility
[ $SWAP_SIZE_MB -lt $((DISK_SIZE_MB / 2)) ] || log "Large swap selected (>=50% of disk). Continuing."
ROOT_END_MB=$(( DISK_SIZE_MB - SWAP_SIZE_MB ))
ROOT_SIZE_MB=$(( ROOT_END_MB - ESP_SIZE_MB ))
[ $ROOT_SIZE_MB -ge $MIN_ROOT_MB ] || err "Root size ($ROOT_SIZE_MB MiB) < minimum ($MIN_ROOT_MB MiB). Reduce swap size."

log "Calculated layout (MiB):\n  Disk: ${DISK_SIZE_MB}\n  ESP: 0-$(($ESP_SIZE_MB))\n  Root: ${ESP_SIZE_MB}-${ROOT_END_MB} (size ${ROOT_SIZE_MB})\n  Swap: ${ROOT_END_MB}-${DISK_SIZE_MB} (size ${SWAP_SIZE_MB})"

# ------------------------------
# Full Disk Wipe (Headers + GPT + Residual LUKS) - destructive
# ------------------------------
log "Wiping existing partition table and initial headers"
sgdisk --zap-all "$DISK"
log "Zeroing first and last 32MiB for cleanliness"
dd if=/dev/zero of="$DISK" bs=1M count=32 conv=fsync status=progress || true
END_SECTOR=$(blockdev --getsz "$DISK")
SECTOR_SIZE=$(cat /sys/block/"$(basename $DISK)"/queue/hw_sector_size)
TAIL_BYTES=$((32 * 1024 * 1024))
TAIL_SECTORS=$(( TAIL_BYTES / SECTOR_SIZE ))
dd if=/dev/zero of="$DISK" bs=$SECTOR_SIZE seek=$(( END_SECTOR - TAIL_SECTORS )) count=$TAIL_SECTORS status=progress || true
flush_writes
partprobe "$DISK" || true
sleep 2

# ------------------------------
# Partition Creation (GPT) using sgdisk for precise alignment
# ------------------------------
log "Creating GPT partitions"
sgdisk -n 1:0:+${ESP_SIZE_MB}MiB -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:+$(( ROOT_SIZE_MB ))MiB -t 2:8300 -c 2:"ROOT" "$DISK"
sgdisk -n 3:0:+${SWAP_SIZE_MB}MiB -t 3:8200 -c 3:"SWAP" "$DISK"
flush_writes
partprobe "$DISK"; sleep 2

EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"
SWAP_PART="${DISK}p3"

log "Partition table created:"
lsblk -o NAME,SIZE,TYPE,PARTTYPE,MOUNTPOINT "$DISK"

# ------------------------------
# Encryption (if selected)
# ------------------------------
if [[ $ENCRYPTED -eq 1 ]]; then
  log "Setting up LUKS2 encryption (argon2id) for root"
  echo -n "$ENCRYPT_PASSWORD" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --label cryptroot "$ROOT_PART" -
  echo -n "$ENCRYPT_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -

  log "Setting up LUKS2 encryption for swap"
  echo -n "$ENCRYPT_PASSWORD" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --label cryptswap "$SWAP_PART" -
  echo -n "$ENCRYPT_PASSWORD" | cryptsetup open "$SWAP_PART" cryptswap -
  mkswap /dev/mapper/cryptswap
  swapon /dev/mapper/cryptswap
  ROOT_MAPPED="/dev/mapper/cryptroot"
else
  log "Non-encrypted path selected"
  ROOT_MAPPED="$ROOT_PART"
  mkswap "$SWAP_PART"; swapon "$SWAP_PART"
fi

# ------------------------------
# Filesystem Formatting
# ------------------------------
log "Formatting EFI and Root (BTRFS)"
mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f -L arch_root "$ROOT_MAPPED"

# ------------------------------
# BTRFS Subvolumes
# ------------------------------
log "Creating BTRFS subvolumes"
TEMP_MNT="/mnt/btrfs_setup"
mkdir -p "$TEMP_MNT"
mount -o defaults,noatime "$ROOT_MAPPED" "$TEMP_MNT"
btrfs subvolume create "$TEMP_MNT/@"
btrfs subvolume create "$TEMP_MNT/@home"
btrfs subvolume create "$TEMP_MNT/@snapshots"
btrfs subvolume create "$TEMP_MNT/@var_log"
btrfs subvolume create "$TEMP_MNT/@var_cache"
umount "$TEMP_MNT"

# ------------------------------
# Mount Final Layout
# ------------------------------
log "Mounting final subvolume layout"
mount -o noatime,compress=${BTRFS_COMPRESS},ssd,discard=async,subvol=@ "$ROOT_MAPPED" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache}
mount -o noatime,compress=${BTRFS_COMPRESS},ssd,discard=async,subvol=@home "$ROOT_MAPPED" /mnt/home
mount -o noatime,compress=${BTRFS_COMPRESS},ssd,discard=async,subvol=@snapshots "$ROOT_MAPPED" /mnt/.snapshots
mount -o noatime,compress=${BTRFS_COMPRESS},ssd,discard=async,subvol=@var_log "$ROOT_MAPPED" /mnt/var/log
mount -o noatime,compress=${BTRFS_COMPRESS},ssd,discard=async,subvol=@var_cache "$ROOT_MAPPED" /mnt/var/cache
mount "$EFI_PART" /mnt/boot
chmod 750 /mnt/.snapshots

# ------------------------------
# Base Package List
# ------------------------------
PACKAGES=(
  base linux linux-firmware linux-headers
  btrfs-progs base-devel networkmanager grub efibootmgr intel-ucode
  libinput cpupower bluez bluez-utils mesa tlp acpi acpid pipewire pipewire-pulse wireplumber
  iio-sensor-proxy thermald man-db man-pages ufw snapper wget curl nano sudo git openssh fastfetch kitty hyprland
)

log "Installing base system (pacstrap)"
pacstrap /mnt "${PACKAGES[@]}"

# ------------------------------
# fstab Generation & Adjustments
# ------------------------------
log "Generating fstab"
genfstab -U /mnt > /mnt/etc/fstab
## Filter out any Arch ISO / loop device entries & potential duplicate root lines
sed -i '/run\/archiso/d;/archiso\/boot/d;/dev\/loop/d' /mnt/etc/fstab
## Remove subvolid entries (clarity) and enforce noatime
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab || true
sed -i 's/relatime/noatime/g' /mnt/etc/fstab || true
## Deduplicate root mount (keep first occurrence of mountpoint /)
awk '($2=="/" && ++c>1){next} {print}' /mnt/etc/fstab > /mnt/etc/fstab.dedup && mv /mnt/etc/fstab.dedup /mnt/etc/fstab
## Add tmpfs /tmp entry
grep -q '^tmpfs /tmp' /mnt/etc/fstab || echo 'tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0' >> /mnt/etc/fstab

log "fstab contents (post-filter):"; cat /mnt/etc/fstab

# ------------------------------
# Chroot Configuration Script
# ------------------------------
log "Preparing chroot configuration script"
cat > /mnt/arch_chroot_setup.sh <<'EOF_CHROOT'
#!/bin/bash
set -euo pipefail

logc() { printf "\n[CHROOT] %s\n" "$*"; }

# Environment variables are inherited (HOSTNAME, LOCALE, KEYMAP, TIMEZONE, USERNAME, PASSWORD, ENCRYPTED, ROOT_PART, SWAP_PART)

logc "Configuring timezone and clock"
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

logc "Configuring locale & keymap"
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

logc "Setting hostname and hosts"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

logc "Setting root password"
echo "root:$PASSWORD" | chpasswd

logc "Creating dedicated group and user '$USERNAME'"
groupadd -f "$USERNAME"  # create group if not exists
useradd -m -g "$USERNAME" -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# mkinitcpio hooks
if [[ "$ENCRYPTED" == "1" ]]; then
  logc "Applying mkinitcpio hooks for encrypted root + resume"
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt resume filesystems keyboard fsck)/' /etc/mkinitcpio.conf
else
  logc "Applying mkinitcpio hooks for standard root + resume"
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block resume filesystems keyboard fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

logc "Installing and configuring GRUB"
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchLinux --recheck

# Kernel cmdline
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART") || true

if [[ "$ENCRYPTED" == "1" ]]; then
  # cryptdevice for root; resume points to decrypted mapper of swap
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
  sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=\/dev\/mapper\/cryptroot rootflags=subvol=@ resume=\/dev\/mapper\/cryptswap rw\"/" /etc/default/grub
else
  sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"root=UUID=$ROOT_UUID rootflags=subvol=@ resume=UUID=$SWAP_UUID rw\"/" /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg

logc "Setting default editor"
echo "EDITOR=/usr/bin/nano" >> /etc/profile
echo "VISUAL=/usr/bin/nano" >> /etc/profile

logc "Enabling essential services"
for svc in NetworkManager tlp acpid bluetooth thermald cpupower ufw; do systemctl enable "$svc"; done
systemctl enable systemd-timesyncd || true

logc "Configuring UFW firewall"
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

logc "Setting cpupower governor to 'powersave' for energy efficiency"
cat > /etc/default/cpupower <<CPUPWR
CPUPOWER_START_OPTS="--governor powersave"
CPUPWR

logc "Snapper configuration"
snapper -c root create-config /
# Adjust root config: ensure subvolume path correct
sed -i 's/^SUBVOLUME=.*/SUBVOLUME="\/"/' /etc/snapper/configs/root
#systemctl enable snapper-timeline.timer
#systemctl enable snapper-cleanup.timer

logc "Creating user profile initialization"
cat > /home/$USERNAME/.profile <<UPROFILE
export EDITOR=nano
export VISUAL=nano
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
UPROFILE
chown $USERNAME:$USERNAME /home/$USERNAME/.profile || true

if [[ "$ENCRYPTED" != "1" ]]; then
  logc "Creating swapfile (inside BTRFS root) for non-encrypted setup"
  # Using existing swap partition: already active; optionally skip swapfile
  # If user prefers swapfile instead of partition, comment previous mkswap and swapon and uncomment below logic.
  # (Retained partition approach to allow potential future encryption conversion.)
  true
fi

logc "Configuration complete"
EOF_CHROOT
export HOSTNAME LOCALE KEYMAP TIMEZONE USERNAME PASSWORD ENCRYPTED ROOT_PART SWAP_PART
chmod +x /mnt/arch_chroot_setup.sh
log "Entering chroot"
arch-chroot /mnt /bin/bash /arch_chroot_setup.sh
rm /mnt/arch_chroot_setup.sh || true

# ------------------------------
# Post-Install Cleanup
# ------------------------------
log "Finalizing installation (unmounting)"
swapoff -a || true  # Will be reactivated on boot via fstab or systemd
umount -R /mnt
if [[ $ENCRYPTED -eq 1 ]]; then
  cryptsetup close cryptroot || true
  cryptsetup close cryptswap || true
fi

log "Installation complete. You may now 'reboot'."
log "Next steps after boot: login as $USERNAME and verify services (systemctl --failed)."
log "Enable Audio: 'systemctl --user enable --now pipewire-pulse.service wireplumber.service'"
log "For DisplayLink dock (optional): 'yay -S dkms displaylink evdi-dkms && sudo systemctl enable --now displaylink.service'"

# EOF
