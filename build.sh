#!/bin/bash

set -e # Exit on error

DEVICE=/dev/sda
IFACE=ens18
TZAREA="Europe"
TZNAME="Budapest"
SWAP="4G"
ROOTLABEL="LINUX"
DEBIAN_VERSION="buster"
REPOSITORY="http://deb.debian.org/debian/"


[ -z "${DEVICE}" ] && echo "Usage $0 /dev/sdX" && exit 1


if [ -z "$DEVICE" -o -z "$ROOTLABEL" ]; then
  echo "Syntax: $0 <image|disk> <root-label> [<chroot-dir>]"
  exit 1
fi

if [ "$UID" != "0" ]; then
  echo "Must be root."
  exit 1
fi

# Exit on errors
set -xe

udevadm info -n ${DEVICE} -q property
echo "Selected device is ${DEVICE}"

# Create sparse file (if we're not dealing with a block device)
echo "Umount ${DEVICE}"
umount ${DEVICE}* || true

# Create partition layout
echo "Set partition table to GPT"
parted ${DEVICE} --script mktable gpt

echo "Create partition layout"

sgdisk -Z $DEVICE 

sgdisk \
  --new 1::+1M --typecode=1:ef02 --change-name=1:'BIOS boot partition' \
  --new 2::+100M --typecode=2:ef00 --change-name=2:'EFI' \
  --new 3::+${SWAP} --typecode=2:8200 --change-name=3:'SWAP' \
  --new 4::-0 --typecode=3:8300 --change-name=4:${ROOTLABEL} \
  $DEVICE 

# Loop sparse file
LOOPDEV=$(losetup --find --show $DEVICE)
partprobe ${LOOPDEV}

# Create filesystems
echo "Format partitions"
mkfs.vfat -n EFI ${DEVICE}2
mkswap ${DEVICE}3
mkfs.ext4 -F -L ${ROOTLABEL} ${DEVICE}4

# Mount OS partition, copy chroot, install grub
MOUNTDIR=$(mktemp -d -t demoXXXXXX)
mount ${DEVICE}4 ${MOUNTDIR}

debootstrap --arch amd64 ${DEBIAN_VERSION} ${MOUNTDIR} ${REPOSITORY}
    # Install kernel and grub
for d in dev sys proc; do
  mount --bind /$d ${MOUNTDIR}/$d;
done
DEBIAN_FRONTEND=noninteractive chroot ${MOUNTDIR} apt-get install linux-image-amd64 linux-headers-amd64 grub-pc -y --force-yes
mount -t devpts /dev/pts ${MOUNTDIR}/dev/pts

echo "Base network"
cat << EOF >> ${MOUNTDIR}/etc/network/interfaces.d/${IFACE}
  allow-hotplug ${IFACE}
  iface ens18 inet dhcp
EOF

cat << EOF >> ${MOUNTDIR}/etc/fstab
   PARTUUID=$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/${ROOTLABEL}) / ext4 defaults 0 1
   PARTUUID=$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/EFI) /boot/efi vfat defaults 0 1
   PARTUUID=$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/SWAP) none swap sw 0 0
EOF


#for d in dev sys proc; do mount --bind /$d ${MOUNTDIR}/$d; done
DEBCONF=`cat << EOF
echo grub-pc grub-pc/install_devices multiselect ${DEVICE} | debconf-set-selections
echo locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8, hu_HU.UTF-8 UTF-8 | debconf-set-selections
echo locales locales/default_environment_locale select C.UTF-8 | debconf-set-selections
echo debconf debconf/priority select critical | debconf-set-selections
echo debconf debconf/frontend select Noninteractive | debconf-set-selections
echo tzdata tzdata/Areas select ${TZAREA} | debconf-set-selections
echo tzdata tzdata/Zones/${TZAREA} select ${TZNAME} | debconf-set-selections
EOF
`

cat << EOF | chroot ${MOUNTDIR} /bin/bash
  set -e
  export HOME=/root
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y grub-efi grub-efi-amd64
  apt-get update
  apt-get install -y linux-image-amd64 linux-headers-amd64 debconf-utils locales qemu-guest-agent
  apt-get install -y sudo ssh
  ${DEBCONF}
  apt -y full-upgrade
  apt -y install grub-pc
  update-initramfs -u -k all
  useradd -m -d /home/ansible/ -s /bin/bash ansible
  mkdir -p /home/ansible/.ssh
  chown -R ansible:ansible /home/ansible
  touch /home/ansible/.ssh/authorized_keys
  chmod 750 /home/ansible
EOF
chroot ${MOUNTDIR}/ grub-install --modules="ext2 part_gpt" ${LOOPDEV}
chroot ${MOUNTDIR}/ update-grub

echo "ansible user settings"
cat << EOF > ${MOUNTDIR}/etc/sudoers.d/ansible
  ansible ALL=(ALL:ALL) NOPASSWD:ALL
EOF
cat .ssh/authorized_keys >  ${MOUNTDIR}/home/ansible/.ssh/authorized_keys


umount $MOUNTDIR/dev/pts
umount $MOUNTDIR/{dev,proc,sys,}
rmdir $MOUNTDIR

# Mount EFI partition
MOUNTDIR=$(mktemp -d -t demoXXXXXX)
mount ${LOOPDEV}p2 $MOUNTDIR
 
mkdir -p ${MOUNTDIR}/EFI/BOOT
grub-mkimage \
  -d /usr/lib/grub/x86_64-efi \
  -o ${MOUNTDIR}/EFI/BOOT/bootx64.efi \
  -p /efi/boot \
  -O x86_64-efi \
    fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain efifwsetup efi_gop \
    efi_uga ls search search_label search_fs_uuid search_fs_file gfxterm gfxterm_background \
    gfxterm_menu test all_video loadenv exfat ext2 ntfs btrfs hfsplus udf
 
# Create grub config
cat <<GRUBCFG > ${MOUNTDIR}/EFI/BOOT/grub.cfg
search --label "${ROOTLABEL}" --set prefix
configfile (\$prefix)/boot/grub/grub.cfg
GRUBCFG

umount $MOUNTDIR
rmdir $MOUNTDIR

# Remove loop device
sync ${LOOPDEV} 
losetup -d ${LOOPDEV}

echo "Done. ${DEVICE} is ready to be booted via BIOS and UEFI."


