#!/usr/bin/env bash
set -e

# Arch Linux Install Script Recovery (alis-recovery) start a recovery for an
# failed installation or broken system.
# Copyright (C) 2022 picodotdev

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

# This script is hosted at https://github.com/picodotdev/alis. For new features,
# improvements and bugs fill an issue in GitHub or make a pull request.
# Pull Request are welcome!
#
# If you test it in real hardware please send me an email to pico.dev@gmail.com with
# the machine description and tell me if somethig goes wrong or all works fine.
#
# Please, don't ask for support for this script in Arch Linux forums, first read
# the Arch Linux wiki [1], the Installation Guide [2] and the General
# Recomendations [3], later compare the commands with those of this script.
#
# [1] https://wiki.archlinux.org
# [2] https://wiki.archlinux.org/index.php/Installation_guide
# [3] https://wiki.archlinux.org/index.php/General_recommendations

# Reference:
# * [Change root](https://wiki.archlinux.org/index.php/Change_root)
# * [Deactivate volume group](https://wiki.archlinux.org/index.php/LVM#Deactivate_volume_group)

# Usage:
# # loadkeys es
# # iwctl --passphrase "[WIFI_KEY]" station [WIFI_INTERFACE] connect "[WIFI_ESSID]"          # (Optional) Connect to WIFI network. _ip link show_ to know WIFI_INTERFACE.
# # curl https://raw.githubusercontent.com/picodotdev/alis/master/download.sh | bash, or with URL shortener curl -sL https://git.io/JeaH6 | bash
# # vim alis-recovery.conf
# # ./alis-recovery.sh

# global variables (no configuration, don't edit)
START_TIMESTAMP=""
END_TIMESTAMP=""
ASCIINEMA=""
BIOS_TYPE=""
PARTITION_BOOT=""
PARTITION_ROOT=""
PARTITION_BOOT_NUMBER=""
PARTITION_ROOT_NUMBER=""
DEVICE_ROOT=""
DEVICE_LVM=""
LUKS_DEVICE_NAME="cryptroot"
LVM_VOLUME_GROUP="vg"
LVM_VOLUME_LOGICAL="root"
SWAPFILE="/swapfile"
BOOT_DIRECTORY=""
ESP_DIRECTORY=""
#PARTITION_BOOT_NUMBER=0
UUID_BOOT=""
UUID_ROOT=""
PARTUUID_BOOT=""
PARTUUID_ROOT=""
DEVICE_SATA=""
DEVICE_NVME=""
DEVICE_MMC=""
CPU_VENDOR=""
GPU_VENDOR=""
VIRTUALBOX=""
VMWARE=""
CMDLINE_LINUX_ROOT=""
CMDLINE_LINUX=""
BTRFS_SUBVOLUME_ROOT=()
BTRFS_SUBVOLUME_SWAP=()

# configuration variables declartion (no configuration, don't edit)
declare -A SYSTEMD_HOMED_STORAGE_LUKS
declare -A SYSTEMD_HOMED_STORAGE_CIFS

CONF_FILE="alis-recovery.conf"
GLOBALS_FILE="alis-globals.conf"
LOG_FILE="alis-recovery.log"
ASCIINEMA_FILE="alis-recovery.asciinema"

RED='\033[0;31m'
GREEN='\033[0;32m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

function configuration_install() {
    source "$CONF_FILE"
}

function sanitize_variables() {
    DEVICE=$(sanitize_variable "$DEVICE")
    FILE_SYSTEM_TYPE=$(sanitize_variable "$FILE_SYSTEM_TYPE")
    PARTITION_MODE=$(sanitize_variable "$PARTITION_MODE")
    PARTITION_CUSTOMMANUAL_BOOT=$(sanitize_variable "$PARTITION_CUSTOMMANUAL_BOOT")
    PARTITION_CUSTOMMANUAL_ROOT=$(sanitize_variable "$PARTITION_CUSTOMMANUAL_ROOT")

    for I in "${BTRFS_SUBVOLUMES_MOUNTPOINTS[@]}"; do
        IFS=',' SUBVOLUME=($I)
        if [ ${SUBVOLUME[0]} == "root" ]; then
            BTRFS_SUBVOLUME_ROOT=("${SUBVOLUME[@]}")
        elif [ ${SUBVOLUME[0]} == "swap" ]; then
            BTRFS_SUBVOLUME_SWAP=("${SUBVOLUME[@]}")
        fi
    done
}

function sanitize_variable() {
    VARIABLE=$1
    VARIABLE=$(echo $VARIABLE | sed "s/![^ ]*//g") # remove disabled
    VARIABLE=$(echo $VARIABLE | sed "s/ {2,}/ /g") # remove unnecessary white spaces
    VARIABLE=$(echo $VARIABLE | sed 's/^[[:space:]]*//') # trim leading
    VARIABLE=$(echo $VARIABLE | sed 's/[[:space:]]*$//') # trim trailing
    echo "$VARIABLE"
}

function check_variables() {
    check_variables_value "KEYS" "$KEYS"
    check_variables_value "DEVICE" "$DEVICE"
    check_variables_boolean "LVM" "$LVM"
    check_variables_equals "LUKS_PASSWORD" "LUKS_PASSWORD_RETYPE" "$LUKS_PASSWORD" "$LUKS_PASSWORD_RETYPE"
    check_variables_list "PARTITION_MODE" "$PARTITION_MODE" "auto custom manual" "true"
    if [ "$PARTITION_MODE" == "custom" ]; then
        check_variables_value "PARTITION_CUSTOM_PARTED_UEFI" "$PARTITION_CUSTOM_PARTED_UEFI"
        check_variables_value "PARTITION_CUSTOM_PARTED_BIOS" "$PARTITION_CUSTOM_PARTED_BIOS"
    fi
    if [ "$PARTITION_MODE" == "custom" -o "$PARTITION_MODE" == "manual" ]; then
        check_variables_value "PARTITION_CUSTOMMANUAL_BOOT" "$PARTITION_CUSTOMMANUAL_BOOT"
        check_variables_value "PARTITION_CUSTOMMANUAL_ROOT" "$PARTITION_CUSTOMMANUAL_ROOT"
    fi
    if [ "$LVM" == "true" ]; then
        check_variables_list "PARTITION_MODE" "$PARTITION_MODE" "auto" "true"
    fi
    check_variables_value "PING_HOSTNAME" "$PING_HOSTNAME"
    check_variables_value "CHROOT" "$CHROOT"
}

function check_variables_value() {
    NAME=$1
    VALUE=$2
    if [ -z "$VALUE" ]; then
        echo "$NAME environment variable must have a value."
        exit
    fi
}

function check_variables_boolean() {
    NAME=$1
    VALUE=$2
    check_variables_list "$NAME" "$VALUE" "true false"
}

function check_variables_list() {
    NAME=$1
    VALUE=$2
    VALUES=$3
    REQUIRED=$4
    if [ "$REQUIRED" == "" -o "$REQUIRED" == "true" ]; then
        check_variables_value "$NAME" "$VALUE"
    fi

    if [ "$VALUE" != "" -a -z "$(echo "$VALUES" | grep -F -w "$VALUE")" ]; then
        echo "$NAME environment variable value [$VALUE] must be in [$VALUES]."
        exit
    fi
}

function check_variables_equals() {
    NAME1=$1
    NAME2=$2
    VALUE1=$3
    VALUE2=$4
    if [ "$VALUE1" != "$VALUE2" ]; then
        echo "$NAME1 and $NAME2 must be equal [$VALUE1, $VALUE2]."
        exit
    fi
}

function check_variables_size() {
    NAME=$1
    SIZE_EXPECT=$2
    SIZE=$3
    if [ "$SIZE_EXPECT" != "$SIZE" ]; then
        echo "$NAME array size [$SIZE] must be [$SIZE_EXPECT]."
        exit
    fi
}

function warning() {
    echo -e "${LIGHT_BLUE}Welcome to Arch Linux Install Script Recovery${NC}"
    echo ""
    read -p "Do you want to continue? [y/N] " yn
    case $yn in
        [Yy]* )
            ;;
        [Nn]* )
            exit
            ;;
        * )
            exit
            ;;
    esac
}

function init() {
    init_log
    loadkeys $KEYS
}

function init_log() {
    if [ "$LOG" == "true" ]; then
        exec > >(tee -a $LOG_FILE)
        exec 2> >(tee -a $LOG_FILE >&2)
    fi
    set -o xtrace
}

function facts() {
    if [ -d /sys/firmware/efi ]; then
        BIOS_TYPE="uefi"
    else
        BIOS_TYPE="bios"
    fi

    if [ -f "$ASCIINEMA_FILE" ]; then
        ASCIINEMA="true"
    else
        ASCIINEMA="false"
    fi

    DEVICE_SATA="false"
    DEVICE_NVME="false"
    DEVICE_MMC="false"
    if [ -n "$(echo $DEVICE | grep "^/dev/[a-z]d[a-z]")" ]; then
        DEVICE_SATA="true"
    elif [ -n "$(echo $DEVICE | grep "^/dev/nvme")" ]; then
        DEVICE_NVME="true"
    elif [ -n "$(echo $DEVICE | grep "^/dev/mmc")" ]; then
        DEVICE_MMC="true"
    fi

    if [ -n "$(lscpu | grep GenuineIntel)" ]; then
        CPU_VENDOR="intel"
    elif [ -n "$(lscpu | grep AuthenticAMD)" ]; then
        CPU_VENDOR="amd"
    fi

    if [ -n "$(lspci -nn | grep "\[03" | grep -i intel)" ]; then
        GPU_VENDOR="intel"
    elif [ -n "$(lspci -nn | grep "\[03" | grep -i amd)" ]; then
        GPU_VENDOR="amd"
    elif [ -n "$(lspci -nn | grep "\[03" | grep -i nvidia)" ]; then
        GPU_VENDOR="nvidia"
    elif [ -n "$(lspci -nn | grep "\[03" | grep -i vmware)" ]; then
        GPU_VENDOR="vmware"
    fi

    if [ -n "$(systemd-detect-virt | grep -i oracle)" ]; then
        VIRTUALBOX="true"
    fi

    if [ -n "$(systemd-detect-virt | grep -i vmware)" ]; then
        VMWARE="true"
    fi
}


function prepare() {
    prepare_partition
    configure_network
    ask_passwords
}

function prepare_partition() {
    if [ -d /mnt/boot ]; then
        umount /mnt/boot
        umount /mnt
    fi
    if [ -e "/dev/mapper/$LVM_VOLUME_GROUP-$LVM_VOLUME_LOGICAL" ]; then
        umount "/dev/mapper/$LVM_VOLUME_GROUP-$LVM_VOLUME_LOGICAL"
    fi
    if [ -e "/dev/mapper/$LUKS_DEVICE_NAME" ]; then
        cryptsetup close $LUKS_DEVICE_NAME
    fi
    partprobe $DEVICE
}

function configure_network() {
    if [ -n "$WIFI_INTERFACE" ]; then
        iwctl --passphrase "$WIFI_KEY" station $WIFI_INTERFACE connect "$WIFI_ESSID"
        sleep 10
    fi

    ping -c 1 -i 2 -W 5 -w 30 $PING_HOSTNAME
    if [ $? -ne 0 ]; then
        echo "Network ping check failed. Cannot continue."
        exit
    fi
}

function ask_passwords() {
    if [ "$LUKS_PASSWORD" == "ask" ]; then
        PASSWORD_TYPED="false"
        while [ "$PASSWORD_TYPED" != "true" ]; do
            read -sp 'Type LUKS password: ' LUKS_PASSWORD
            echo ""
            read -sp 'Retype LUKS password: ' LUKS_PASSWORD_RETYPE
            echo ""
            if [ "$LUKS_PASSWORD" == "$LUKS_PASSWORD_RETYPE" ]; then
                PASSWORD_TYPED="true"
            else
                echo "LUKS password don't match. Please, type again."
            fi
        done
    fi
}

function partition() {
    # setup
    if [ "$PARTITION_MODE" == "auto" ]; then
        if [ "$BIOS_TYPE" == "uefi" ]; then
            if [ "$DEVICE_SATA" == "true" ]; then
                PARTITION_BOOT="${DEVICE}1"
                PARTITION_ROOT="${DEVICE}2"
                DEVICE_ROOT="${DEVICE}2"
            fi

            if [ "$DEVICE_NVME" == "true" ]; then
                PARTITION_BOOT="${DEVICE}p1"
                PARTITION_ROOT="${DEVICE}p2"
                DEVICE_ROOT="${DEVICE}p2"
            fi

            if [ "$DEVICE_MMC" == "true" ]; then
                PARTITION_BOOT="${DEVICE}p1"
                PARTITION_ROOT="${DEVICE}p2"
                DEVICE_ROOT="${DEVICE}p2"
            fi
        fi

        if [ "$BIOS_TYPE" == "bios" ]; then
            if [ "$DEVICE_SATA" == "true" ]; then
                PARTITION_BOOT="${DEVICE}1"
                PARTITION_ROOT="${DEVICE}2"
                DEVICE_ROOT="${DEVICE}2"
            fi

            if [ "$DEVICE_NVME" == "true" ]; then
                PARTITION_BOOT="${DEVICE}p1"
                PARTITION_ROOT="${DEVICE}p2"
                DEVICE_ROOT="${DEVICE}p2"
            fi

            if [ "$DEVICE_MMC" == "true" ]; then
                PARTITION_BOOT="${DEVICE}p1"
                PARTITION_ROOT="${DEVICE}p2"
                DEVICE_ROOT="${DEVICE}p2"
            fi
        fi
    elif [ "$PARTITION_MODE" == "custom" ]; then
        PARTITION_PARTED_UEFI="$PARTITION_CUSTOM_PARTED_UEFI"
        PARTITION_PARTED_BIOS="$PARTITION_CUSTOM_PARTED_BIOS"
    fi

    if [ "$PARTITION_MODE" == "custom" -o "$PARTITION_MODE" == "manual" ]; then
        PARTITION_BOOT="$PARTITION_CUSTOMMANUAL_BOOT"
        PARTITION_ROOT="$PARTITION_CUSTOMMANUAL_ROOT"
        DEVICE_ROOT="${PARTITION_ROOT}"
    fi

    PARTITION_BOOT_NUMBER="$PARTITION_BOOT"
    PARTITION_ROOT_NUMBER="$PARTITION_ROOT"
    PARTITION_BOOT_NUMBER="${PARTITION_BOOT_NUMBER//\/dev\/sda/}"
    PARTITION_BOOT_NUMBER="${PARTITION_BOOT_NUMBER//\/dev\/nvme0n1p/}"
    PARTITION_BOOT_NUMBER="${PARTITION_BOOT_NUMBER//\/dev\/vda/}"
    PARTITION_BOOT_NUMBER="${PARTITION_BOOT_NUMBER//\/dev\/mmcblk0p/}"
    PARTITION_ROOT_NUMBER="${PARTITION_ROOT_NUMBER//\/dev\/sda/}"
    PARTITION_ROOT_NUMBER="${PARTITION_ROOT_NUMBER//\/dev\/nvme0n1p/}"
    PARTITION_ROOT_NUMBER="${PARTITION_ROOT_NUMBER//\/dev\/vda/}"
    PARTITION_ROOT_NUMBER="${PARTITION_ROOT_NUMBER//\/dev\/mmcblk0p/}"

    # luks and lvm
    if [ -n "$LUKS_PASSWORD" ]; then
        echo -n "$LUKS_PASSWORD" | cryptsetup --key-file=- open $PARTITION_ROOT $LUKS_DEVICE_NAME
        sleep 5
    fi

    if [ -n "$LUKS_PASSWORD" ]; then
        DEVICE_ROOT="/dev/mapper/$LUKS_DEVICE_NAME"
    fi
    if [ "$LVM" == "true" ]; then
        DEVICE_ROOT="/dev/mapper/$LVM_VOLUME_GROUP-$LVM_VOLUME_LOGICAL"
    fi

    # options
    PARTITION_OPTIONS_BOOT="defaults"
    PARTITION_OPTIONS_ROOT="defaults"

    if [ "$DEVICE_TRIM" == "true" ]; then
        PARTITION_OPTIONS_BOOT="$PARTITION_OPTIONS_BOOT,noatime"
        PARTITION_OPTIONS_ROOT="$PARTITION_OPTIONS_ROOT,noatime"
        if [ "$FILE_SYSTEM_TYPE" == "f2fs" ]; then
            PARTITION_OPTIONS_ROOT="$PARTITION_OPTIONS_ROOT,nodiscard"
        fi
    fi

    # mount
    if [ "$FILE_SYSTEM_TYPE" == "btrfs" ]; then
        # mount subvolumes
        mount -o "subvol=${BTRFS_SUBVOLUME_ROOT[1]},$PARTITION_OPTIONS_ROOT,compress=zstd" "$DEVICE_ROOT" /mnt
        mkdir -p /mnt/boot
        mount -o "$PARTITION_OPTIONS_BOOT" "$PARTITION_BOOT" /mnt/boot
        for I in "${BTRFS_SUBVOLUMES_MOUNTPOINTS[@]}"; do
            IFS=',' SUBVOLUME=($I)
            if [ ${SUBVOLUME[0]} == "root" ]; then
                continue
            fi
            if [ ${SUBVOLUME[0]} == "swap" -a -z "$SWAP_SIZE" ]; then
                continue
            fi
            if [ ${SUBVOLUME[0]} == "swap" ]; then
                mkdir -p -m 0755 "/mnt${SUBVOLUME[2]}"
            else
                mkdir -p "/mnt${SUBVOLUME[2]}"
            fi
            mount -o "subvol=${SUBVOLUME[1]},$PARTITION_OPTIONS_ROOT,compress=zstd" "$DEVICE_ROOT" "/mnt${SUBVOLUME[2]}"
        done
    else
        mount -o "$PARTITION_OPTIONS_ROOT" "$DEVICE_ROOT" /mnt

        mkdir -p /mnt/boot
        mount -o "$PARTITION_OPTIONS_BOOT" "$PARTITION_BOOT" /mnt/boot
    fi
}

function recovery() {
    arch-chroot /mnt
}

function end() {
    echo ""
    echo -e "${GREEN}Recovery started.${NC} You must do an explicit reboot after finalize recovery (exit if in arch-chroot, ./alis-reboot.sh)."
    echo ""
}

function do_reboot() {
    umount -R /mnt/boot
    umount -R /mnt
    reboot
}

function main() {
    configuration_install
    sanitize_variables
    check_variables
    warning
    init
    facts
    prepare
    partition
    if [ "$CHROOT" == "true" ]; then
        recovery
    fi
    end
}

main
