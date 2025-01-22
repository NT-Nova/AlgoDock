#!/bin/bash
#########################################################################
# Script Name: create_xfs_volume.sh
#
# Description:
#   This script finds the mounted partition with the largest available
#   space, then creates a volume file on that partition occupying 3/5 of
#   the available space. The volume file is formatted as XFS, attached as a
#   loop device, mounted at a specified mount point, and its configuration
#   is added to /etc/fstab.
#
# Usage:
#   sudo ./create_xfs_volume.sh [OPTIONS]
#
# Options:
#   --debug      Enable debug mode.
#   --dry-run    Show the changes without applying them.
#   -h, --help   Display this help message and exit.
#
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
FSTAB_FILE="/etc/fstab"

# Mount point where the volume (loop device) will be attached.
MOUNT_POINT="$HOME/DATA"
# Name of the volume file that will be created on the selected partition.
VOLUME_FILE_NAME="volume.img"

# ANSI color codes for UI formatting.
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

#########################################################################
# Trap Signals and Cleanup
#########################################################################
cleanup() {
  log "INFO" "Exiting script..."
}
trap cleanup EXIT
trap 'log "ERROR" "Script interrupted."; exit 1' INT TERM

#########################################################################
# Helper Functions
#########################################################################

# Print help message.
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --debug      Enable debug mode.
  --dry-run    Show the changes without applying them.
  -h, --help   Show this help message and exit.
EOF
}

# Log messages with color and timestamps.
log() {
  local LEVEL="$1"
  shift
  local MESSAGE="$*"
  local TIMESTAMP
  TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
  case "$LEVEL" in
    INFO)    echo -e "[${BLUE}INFO${RESET}] [$TIMESTAMP] $MESSAGE"    | tee -a "$LOG_FILE" ;;
    DEBUG)   echo -e "[${YELLOW}DEBUG${RESET}] [$TIMESTAMP] $MESSAGE"  | tee -a "$LOG_FILE" ;;
    ERROR)   echo -e "[${RED}ERROR${RESET}] [$TIMESTAMP] $MESSAGE"     | tee -a "$LOG_FILE" ;;
    SUCCESS) echo -e "[${GREEN}SUCCESS${RESET}] [$TIMESTAMP] $MESSAGE"   | tee -a "$LOG_FILE" ;;
    *)       echo -e "[$TIMESTAMP] $MESSAGE"                           | tee -a "$LOG_FILE" ;;
  esac
}

# Print debug messages if DEBUG mode is enabled.
debug() {
  if $DEBUG; then
    log "DEBUG" "$*"
  fi
}

# Check for root privileges (or available sudo).
check_root() {
  if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo &>/dev/null; then
      echo "sudo is required. Please install sudo or run as root."
      exit 1
    fi
  fi
}

# Validate that essential files and directories exist and are writable/readable.
validate_environment() {
  # Ensure /proc/meminfo exists.
  if [ ! -r /proc/meminfo ]; then
    log "ERROR" "/proc/meminfo is not readable. Aborting."
    exit 1
  fi

  # Ensure log file directory is writable.
  if [ ! -w "$(dirname "$LOG_FILE")" ]; then
    echo "Log directory $(dirname "$LOG_FILE") is not writable. Aborting."
    exit 1
  fi

  # Ensure fstab directory is writable.
  if [ ! -w "$(dirname "$FSTAB_FILE")" ]; then
    log "ERROR" "Configuration directory $(dirname "$FSTAB_FILE") is not writable. Aborting."
    exit 1
  fi

  # Ensure mount point directory exists (create it if it does not).
  if [ ! -d "$MOUNT_POINT" ]; then
    if $DRY_RUN; then
      log "INFO" "[DRY-RUN] Would create mount point $MOUNT_POINT."
    else
      mkdir -p "$MOUNT_POINT"
      log "INFO" "Created mount point $MOUNT_POINT."
    fi
  fi

  log "INFO" "Environment validated successfully."
}

# Find the mounted partition with the most available space.
# It uses df output and selects a device whose name begins with "/dev/".
find_partition_with_max_space() {
  log "INFO" "Searching for the mounted partition with the most available space..."

  # Using df in kilobytes. Format (Filesystem Available Mountpoint)
  local candidate
  candidate=$(df --output=source,avail,target -k | \
    awk 'NR>1 && $1 ~ /^\/dev\// {print $1, $2, $3}' | \
    sort -k2 -n | tail -1)
  
  if [ -z "$candidate" ]; then
    log "ERROR" "No suitable mounted partition found."
    exit 1
  fi

  # Parse the result.
  local device avail mp
  read -r device avail mp <<< "$candidate"
  log "INFO" "Selected partition: $device mounted on $mp with $avail KB available."
  echo "$device $avail $mp"
}

# Create a volume file sized to 3/5 of the available space on a given partition.
create_volume_file() {
  local mp="$1"
  local avail_kb="$2"
  local vol_path="$mp/$VOLUME_FILE_NAME"

  # Calculate 3/5 of the available space (in KB).
  local size_kb
  size_kb=$(( (avail_kb * 3) / 5 ))
  
  # Convert size to bytes.
  local size_bytes=$(( size_kb * 1024 ))

  log "INFO" "Available space on partition: ${avail_kb} KB."
  log "INFO" "Creating volume file of size 3/5 of available space: ${size_kb} KB (${size_bytes} bytes) at ${vol_path}."

  if $DRY_RUN; then
    log "INFO" "[DRY-RUN] Would create volume file ${vol_path} with size ${size_bytes} bytes."
  else
    # Create a sparse file.
    fallocate -l "${size_bytes}" "$vol_path"
    log "SUCCESS" "Volume file ${vol_path} created."
  fi

  echo "$vol_path"
}

# Format the volume file as XFS (using -f to force the format).
format_volume_file() {
  local vol_file="$1"
  log "INFO" "Formatting volume file ${vol_file} with XFS..."
  if $DRY_RUN; then
    log "INFO" "[DRY-RUN] Would format ${vol_file} with mkfs.xfs -f."
  else
    mkfs.xfs -f "$vol_file" >/dev/null 2>&1 && \
      log "SUCCESS" "Formatted ${vol_file} with XFS." || {
        log "ERROR" "Failed to format ${vol_file}."
        exit 1
      }
  fi
}

# Set up a loop device for the volume file.
setup_loop_device() {
  local vol_file="$1"
  local loop_dev
  if $DRY_RUN; then
    loop_dev="/dev/loopX"
    log "INFO" "[DRY-RUN] Would associate ${vol_file} with a loop device, e.g. ${loop_dev}."
  else
    loop_dev=$(losetup --find --show "$vol_file")
    if [ -z "$loop_dev" ]; then
      log "ERROR" "Failed to set up loop device for ${vol_file}."
      exit 1
    fi
    log "SUCCESS" "Associated ${vol_file} with loop device ${loop_dev}."
  fi
  echo "$loop_dev"
}

# Mount the loop device to the designated mount point and update /etc/fstab.
mount_loop_device() {
  local loop_dev="$1"
  local mountp="$2"
  log "INFO" "Mounting ${loop_dev} to ${mountp}..."
  if $DRY_RUN; then
    log "INFO" "[DRY-RUN] Would mount ${loop_dev} to ${mountp}."
  else
    mount "$loop_dev" "$mountp" || {
      log "ERROR" "Failed to mount ${loop_dev} on ${mountp}."
      exit 1
    }
    log "SUCCESS" "Mounted ${loop_dev} on ${mountp}."
  fi

  # Retrieve the UUID of the loop device for persistent mounting.
  local uuid
  if ! uuid=$(blkid -s UUID -o value "$loop_dev"); then
    log "ERROR" "Failed to retrieve UUID for ${loop_dev}."
    exit 1
  fi

  # Add an entry to /etc/fstab if not already present.
  if grep -q "$mountp" "$FSTAB_FILE"; then
    log "WARNING" "Entry for ${mountp} already exists in ${FSTAB_FILE}."
  else
    local entry="UUID=${uuid} ${mountp} xfs defaults 0 0"
    if $DRY_RUN; then
      log "INFO" "[DRY-RUN] Would add the following entry to ${FSTAB_FILE}: ${entry}"
    else
      echo "$entry" | sudo tee -a "$FSTAB_FILE" >/dev/null && \
        log "SUCCESS" "Added entry to ${FSTAB_FILE}." || {
          log "ERROR" "Failed to update ${FSTAB_FILE}."
          exit 1
      }
    fi
  fi
}

#########################################################################
# Main Function: Parse Options, Validate, and Execute
#########################################################################
main() {
  check_root
  validate_environment

  # Parse command-line options.
  while [[ "${1:-}" =~ ^- ]]; do
    case "$1" in
      --debug)
        DEBUG=true
        log "INFO" "Debug mode enabled."
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        log "INFO" "Dry-run mode enabled. No changes will be applied."
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        log "ERROR" "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done

  log "INFO" "Starting XFS volume creation process..."

  # Find the mounted partition with the largest available space.
  read -r chosen_dev avail_kb chosen_mp < <(find_partition_with_max_space)
  
  # For example, in your case:
  #   /dev/vda3 is mounted on "/" and has the largest available space.
  log "INFO" "Using partition ${chosen_dev} (mounted on ${chosen_mp})."

  # Create the volume file on the selected partition.
  vol_file=$(create_volume_file "$chosen_mp" "$avail_kb")

  # Format the volume file as XFS.
  format_volume_file "$vol_file"

  # Associate the volume file with a free loop device.
  loop_dev=$(setup_loop_device "$vol_file")

  # Mount the new loop device to the designated mount point.
  mount_loop_device "$loop_dev" "$MOUNT_POINT"

  log "SUCCESS" "XFS volume file created on ${chosen_dev} (volume file ${vol_file}, loop device ${loop_dev}) and mounted on ${MOUNT_POINT}."
}

# Execute the main function, passing command-line arguments.
main "$@"