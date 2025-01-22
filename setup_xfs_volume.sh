#!/bin/bash
#########################################################################
# Script Name: setup_xfs_volume.sh
#
# Description:
#   This script finds the mounted partition with the largest available
#   space, creates a volume file on that partition with a size either
#   specified by the user or defaulting to 3/5 of the available space,
#   formats it as XFS, attaches it as a loop device, mounts it at a
#   specified mount point, and updates /etc/fstab.
#
# Usage:
#   sudo ./setup_xfs_volume.sh [OPTIONS]
#
# Options:
#   --debug         Enable debug mode.
#   --dry-run       Show the changes without applying them.
#   --volume-size   Specify the custom volume size (e.g., 1G, 500M).
#   -h, --help      Display this help message and exit.
#########################################################################

# Enable strict mode.
set -euo pipefail
IFS=$'\n\t'

#########################################################################
# Global Variables
#########################################################################
LOG_FILE="/var/log/create_xfs_volume.log"
DEBUG=false
DRY_RUN=false
CUSTOM_VOLUME_SIZE=""
FSTAB_FILE="/etc/fstab"
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6 2>/dev/null || echo "$HOME")
VOLUME_FILE_NAME="${USER_HOME}/volume.img"
MOUNT_POINT="${USER_HOME}/DATAXFS"

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

#########################################################################
# Helper Functions
#########################################################################
log() {
  local LEVEL="$1"
  shift
  local MESSAGE="$*"
  local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
  case "$LEVEL" in
    INFO)    echo -e "[${BLUE}INFO${RESET}] [$TIMESTAMP] $MESSAGE"    | tee -a "$LOG_FILE" ;;
    DEBUG)   echo -e "[${YELLOW}DEBUG${RESET}] [$TIMESTAMP] $MESSAGE"  | tee -a "$LOG_FILE" ;;
    ERROR)   echo -e "[${RED}ERROR${RESET}] [$TIMESTAMP] $MESSAGE"     | tee -a "$LOG_FILE" ;;
    SUCCESS) echo -e "[${GREEN}SUCCESS${RESET}] [$TIMESTAMP] $MESSAGE"   | tee -a "$LOG_FILE" ;;
    *)       echo -e "[$TIMESTAMP] $MESSAGE"                           | tee -a "$LOG_FILE" ;;
  esac
}

debug() {
  $DEBUG && log "DEBUG" "$*"
}

check_command() {
  if ! command -v "$1" &>/dev/null; then
    if $DRY_RUN; then
      log "INFO" "[DRY-RUN] Would install $1."
    else
      log "INFO" "Installing missing command: $1..."
      apt-get update && apt-get install -y "$1"
      log "SUCCESS" "$1 installed."
    fi
  fi
}

install_xfsprogs() {
  if ! command -v mkfs.xfs &>/dev/null; then
    if $DRY_RUN; then
      log "INFO" "[DRY-RUN] Would install xfsprogs."
    else
      log "INFO" "Installing xfsprogs package for XFS support..."
      sudo apt-get update && apt-get install -y xfsprogs
      log "SUCCESS" "xfsprogs installed."
    fi
  fi
}

validate_environment() {
  log "Validating environment..."
  check_command "df"
  check_command "fallocate"
  check_command "losetup"
  install_xfsprogs

  # Clean up unused loop devices
  clean_unused_loop_devices

  [ -d "$MOUNT_POINT" ] || {
    $DRY_RUN && log "INFO" "[DRY-RUN] Would create mount point $MOUNT_POINT." || {
      mkdir -p "$MOUNT_POINT"
      log "INFO" "Created mount point $MOUNT_POINT."
    }
  }
}

find_partition_with_max_space() {
  local candidate=$(df --output=source,avail,target -k | awk 'NR>1 && $1 ~ /^\/dev\// {print $1, $2, $3}' | sort -k2 -n | tail -1)
  [ -z "$candidate" ] && { log "ERROR" "No suitable mounted partition found."; exit 1; }
  echo "$candidate"
}

create_volume_file() {
  local mp="$1"
  local avail_kb="$2"
  local vol_path=$(realpath "$VOLUME_FILE_NAME")

  local size_kb
  if [[ -n "$CUSTOM_VOLUME_SIZE" ]]; then
    log "INFO" "Using custom volume size: $CUSTOM_VOLUME_SIZE."
    size_kb=$(numfmt --from=iec "$CUSTOM_VOLUME_SIZE") || {
      log "ERROR" "Invalid custom volume size: $CUSTOM_VOLUME_SIZE."; exit 1;
    }
  else
    size_kb=$(( (avail_kb * 3) / 5 ))
    log "INFO" "Calculated default volume size: $((size_kb / 1024 / 1024)) GB (3/5 of available space)."
  fi

  if [[ "$size_kb" -le 0 ]]; then
    log "ERROR" "Calculated size for volume file is invalid: $size_kb KB."
    exit 1
  fi

  local size_bytes=$(( size_kb * 1024 ))

  debug "Volume file size in KB: $size_kb"
  debug "Volume file size in bytes: $size_bytes"
  debug "Volume file path: $vol_path"

  mkdir -p "$(dirname "$vol_path")"

  $DRY_RUN && log "INFO" "[DRY-RUN] Would create volume file ${vol_path} of size ${size_bytes} bytes." || {
    fallocate -l "$size_bytes" "$vol_path" || {
      log "ERROR" "Failed to create volume file at ${vol_path}."
      exit 1
    }
    chown "$SUDO_USER":"$SUDO_USER" "$vol_path" || log "ERROR" "Failed to change ownership of $vol_path."
    log "SUCCESS" "Volume file ${vol_path} created."
  }
}

format_volume_file() {
  debug "Checking if volume file exists: $VOLUME_FILE_NAME"
  if [[ ! -f "$VOLUME_FILE_NAME" ]]; then
    log "ERROR" "Volume file $VOLUME_FILE_NAME does not exist; cannot format."
    exit 1
  fi

  # Ensure the script can access the file
  if [[ ! -w "$VOLUME_FILE_NAME" ]]; then
    log "ERROR" "Volume file $VOLUME_FILE_NAME is not writable. Check permissions."
    exit 1
  fi

  $DRY_RUN && log "INFO" "[DRY-RUN] Would format ${VOLUME_FILE_NAME} with mkfs.xfs -f." || {
    sudo mkfs.xfs -f "$VOLUME_FILE_NAME" && log "SUCCESS" "Formatted ${VOLUME_FILE_NAME} with XFS." || {
      log "ERROR" "Failed to format ${VOLUME_FILE_NAME}."; exit 1;
    }
  }
}

setup_loop_device() {
  local loop_dev
  log "Setting up loop device for ${VOLUME_FILE_NAME}..."

  # Ensure enough loop devices exist
  clean_unused_loop_devices

  # Find and associate an unused loop device
  if $DRY_RUN; then
    loop_dev="/dev/loopX"
    log "INFO" "[DRY-RUN] Would associate ${VOLUME_FILE_NAME} with ${loop_dev}."
  else
    loop_dev=$(sudo losetup --find --show "$VOLUME_FILE_NAME" 2>/dev/null) || {
      log "ERROR" "Failed to associate ${VOLUME_FILE_NAME} with a loop device. No unused loop devices available."
      exit 1
    }
    log "SUCCESS" "Associated ${VOLUME_FILE_NAME} with loop device ${loop_dev}."
  fi

  # Return the loop device path
  echo "$loop_dev"
}

clean_unused_loop_devices() {
  log "Ensuring util-linux package is installed..."
  sudo apt-get update && sudo apt-get install -y util-linux

  log "Cleaning up unused loop devices..."
  for loop in /dev/loop*; do
    if ! sudo losetup "$loop" &>/dev/null; then
      sudo rm -f "$loop"
      log "Removed unused loop device: $loop"
    fi
  done

  log "Checking for active loop devices..."
  max_loop=$(sudo losetup -a | awk -F: '/\/dev\/loop/ {gsub("/dev/loop", "", $1); if ($1+0 > max) max=$1+0} END {print max}')
  max_loop=${max_loop:-0}

  log "Recreating necessary loop devices..."
  for ((i=0; i<=max_loop+4; i++)); do
    if [[ ! -e /dev/loop$i ]]; then
      sudo mknod -m660 /dev/loop$i b 7 $i
      sudo chown root:disk /dev/loop$i
      log "Created /dev/loop$i"
    fi
  done

  log "Verifying recreated loop devices..."
  ls -l /dev/loop*

  log "Loop device cleanup and recreation completed."
}

mount_loop_device() {
  local loop_dev="$1"
  local mountp="$2"
  $DRY_RUN && log "INFO" "[DRY-RUN] Would mount ${loop_dev} on ${mountp}." || {
    mount "$loop_dev" "$mountp" || { log "ERROR" "Failed to mount ${loop_dev} on ${mountp}."; exit 1; }
    log "SUCCESS" "Mounted ${loop_dev} on ${mountp}."
  }
}

update_fstab() {
  local mountp="$2"
  local entry="${VOLUME_FILE_NAME} ${mountp} xfs defaults,loop 0 0"

  log "Updating /etc/fstab with the new mount entry..."
  if grep -qF "${mountp}" "$FSTAB_FILE"; then
    log "INFO" "Mount point ${mountp} already exists in /etc/fstab. Skipping update."
  else
    if $DRY_RUN; then
      log "INFO" "[DRY-RUN] Would add the following entry to /etc/fstab: ${entry}"
    else
      echo "${entry}" | sudo tee -a "$FSTAB_FILE" >/dev/null
      log "SUCCESS" "Added the following entry to /etc/fstab: ${entry}"

      log "INFO" "Verifying /etc/fstab by running 'sudo mount -a'..."
      if ! sudo mount -a; then
        log "ERROR" "Failed to mount all entries in /etc/fstab. Reverting changes."
        sudo sed -i "\|${entry}|d" "$FSTAB_FILE"
        exit 1
      fi
      log "SUCCESS" "New /etc/fstab entry verified successfully."
    fi
  fi
}

mount_loop_device() {
  local mountp="$2"
  $DRY_RUN && log "INFO" "[DRY-RUN] Would mount ${VOLUME_FILE_NAME} on ${mountp}." || {
    if sudo mount "$VOLUME_FILE_NAME" "$mountp"; then
      log "SUCCESS" "Mounted ${VOLUME_FILE_NAME} on ${mountp}."
    else
      log "ERROR" "Failed to mount ${VOLUME_FILE_NAME} on ${mountp}."
      exit 1
    fi
  }
}

main() {
  validate_environment

  while [[ "${1:-}" =~ ^- ]]; do
    case "$1" in
      --debug) DEBUG=true; log "INFO" "Debug mode enabled."; shift ;;
      --dry-run) DRY_RUN=true; log "INFO" "Dry-run mode enabled."; shift ;;
      --volume-size) CUSTOM_VOLUME_SIZE="$2"; shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      *) log "ERROR" "Unknown option: $1"; exit 1 ;;
    esac
  done

  log "INFO" "Starting XFS volume creation process..."

  read -r chosen_dev avail_kb chosen_mp <<< $(find_partition_with_max_space)
  log "INFO" "Selected partition: ${chosen_dev} mounted on ${chosen_mp} with ${avail_kb} KB available."

  create_volume_file "$chosen_mp" "$avail_kb"
  format_volume_file
  loop_dev=$(setup_loop_device)
  mount_loop_device "$loop_dev" "$MOUNT_POINT"
  update_fstab "$loop_dev" "$MOUNT_POINT"

  log "SUCCESS" "XFS volume setup complete: ${VOLUME_FILE_NAME} -> ${loop_dev} -> ${MOUNT_POINT}."
}

main "$@"