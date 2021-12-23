#!/bin/bash -e

ISO=$1
WORKING_DIR=/usr/local/harvester-upgrade
ISO_MNT=$WORKING_DIR/iso_mnt


clean_up() {
  umount $WORKING_DIR/squashfs_mnt || true
  umount $ISO_MNT || true
}

mount_iso() {
  mkdir -p $ISO_MNT
  mount $ISO $ISO_MNT
}

display_version() {
  echo "The ISO contains the following versions:"
  cat $ISO_MNT/harvester-release.yaml

  if [ -n "$HARV_FORCE" ]; then
    return
  fi

  read -p "Do you want to upgrade? (y/n)" confirm
  if [ "$confirm" != "y" ]; then
    echo "Abort."
    exit 0
  fi
}

upgrade_os() {
  mkdir -p $WORKING_DIR/squashfs_mnt
  mount $ISO_MNT/rootfs.squashfs $WORKING_DIR/squashfs_mnt
  /usr/local/harvester-upgrade/upgrade-helpers/bin/harv-os-upgrade --directory $WORKING_DIR/squashfs_mnt

  # fix grub menu
  mount -o remount,rw /run/initramfs/cos-state/
  cp /usr/local/harvester-upgrade/upgrade-helpers/grub-fix/grubmenu /run/initramfs/cos-state/
  cp /usr/local/harvester-upgrade/upgrade-helpers/grub-fix/grub2/grub.cfg /run/initramfs/cos-state/grub2/
  grub2-editenv /run/initramfs/cos-state/grub_oem_env set default_menu_entry="$(/usr/local/harvester-upgrade/upgrade-helpers/bin/yq -e e '.os' /usr/local/harvester-upgrade/iso_mnt/harvester-release.yaml)"
  mount -o remount,ro /run/initramfs/cos-state/
}

trap clean_up EXIT

mount_iso
display_version

/usr/local/harvester-upgrade/upgrade-helpers/bin/harv-load-images $ISO_MNT
/usr/local/harvester-upgrade/upgrade-helpers/bin/harv-clean-old-manifests.sh
upgrade_os
