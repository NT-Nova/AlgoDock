#!/bin/bash
#########################################################################
# Script Name: setup_xfs.sh
#
# Description:
#   Sets up an XFS filesystem on a disk device with two modes:
#     - Automatic mode: Auto-detects an unmounted disk.
#     - Manual mode: Prompts for disk device and mount point.
#
#   The script installs necessary packages, formats the disk,
#   mounts it, updates /etc/fstab for persistence, and verifies the setup.
#
# Usage:
#   ./setup_xfs.sh [OPTIONS]
#
# Options:
#   -a, --auto      Automatic setup (default).
#   -m, --manual    Manual setup (interactive prompts).
#   -d, --debug     Enable debug mode.
#   -h, --help      Display this help message and exit.
#
#########################################################################

# Enable strict error handling and proper field separation
set -euo pipefail
IFS=$'\n\t'

#########################################################################
# Global Variables
#########################################################################
AUTO_MODE=true
DEBUG=false
DEFAULT_MOUNT_POINT="$HOME/DATA"
FSTAB_FILE="/etc/fstab"
LOG_FILE="/var/log/setup_xfs.log"

#########################################################################
# Trap Signals and Errors
#########################################################################
cleanup() {
  # Place cleanup steps here if needed in the future.
  log "INFO" "Cleaning up before exit..."
}
trap cleanup EXIT
trap 'log "ERROR" "Script interrupted." ; exit 1' INT TERM

#########################################################################
# Helper Functions
#########################################################################

# Function: Print help message
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -a, --auto      Automatic setup (auto-detects the disk device). [default]
  -m, --manual    Manual setup (prompts for disk device and mount point).
  -d, --debug     Enable debug mode.
  -h, --help      Display this help message and exit.
EOF
}

# Function: Log messages to console and log file
log() {
  local LEVEL="$1"
  shift
  local MESSAGE="$*"
  local TIMESTAMP
  TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$TIMESTAMP] [$LEVEL] $MESSAGE" | tee -a "$LOG_FILE"
}

# Function: Debug messages
debug() {
  if $DEBUG; then
    log "DEBUG" "$*"
  fi
}

#########################################################################
# Validate Root Privileges for Some Operations
#########################################################################
check_root_or_sudo() {
  # For operations where sudo is used, ensure either the user is root or sudo is available.
  if [ "$EUID" -ne 0 ] && ! command -v sudo &>/dev/null; then
    echo "sudo is required when not running as root. Please install sudo or run as root."
    exit 1
  fi
}

#########################################################################
# Parse Command-Line Arguments
#########################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--auto)
      AUTO_MODE=true
      shift
      ;;
    -m|--manual)
      AUTO_MODE=false
      shift
      ;;
    -d|--debug)
      DEBUG=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

#########################################################################
# Pre-requisite Check: Ensure XFS Tools Are Installed
#########################################################################
log "INFO" "Starting XFS setup script."
check_root_or_sudo
log "INFO" "Checking for XFS tools (mkfs.xfs)..."
if ! command -v mkfs.xfs &>/dev/null; then
  log "INFO" "XFS tools not found. Installing xfsprogs..."
  if ! sudo apt update && sudo apt install -y xfsprogs; then
    log "ERROR" "Failed to install xfsprogs. Exiting."
    exit 1
  fi
else
  log "INFO" "XFS tools are already installed."
fi

#########################################################################
# Determine Disk Device and Mount Point (Mode Selection)
#########################################################################
if $AUTO_MODE; then
  log "INFO" "Running in AUTOMATIC mode."
  # Auto-detect an unmounted disk (no filesystem and not mounted)
  DISK_DEVICE=$(lsblk -dpno NAME,TYPE,FSTYPE,MOUNTPOINT,SIZE | \
                awk '$2 == "disk" && $3 == "" && $4 == "" {print $1}' | head -n 1)
  if [ -z "$DISK_DEVICE" ]; then
    log "ERROR" "No suitable unmounted disk found in automatic mode."
    exit 1
  fi
  log "INFO" "Detected disk: $DISK_DEVICE"
  MOUNT_POINT="$DEFAULT_MOUNT_POINT"

  # Confirmation prompt
  read -r -p "Proceed to format and mount $DISK_DEVICE at $MOUNT_POINT? This will ERASE ALL DATA! (yes/no): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    log "INFO" "User aborted the setup."
    exit 0
  fi

else
  log "INFO" "Running in MANUAL mode."
  # Prompt user for disk device
  read -r -p "Enter the disk device (e.g., /dev/sdX): " DISK_DEVICE
  if [ ! -b "$DISK_DEVICE" ]; then
    log "ERROR" "Disk device '$DISK_DEVICE' does not exist. Exiting."
    exit 1
  fi
  log "INFO" "Disk device '$DISK_DEVICE' exists."

  # Prompt user for mount point, using default if empty
  read -r -p "Enter the mount point (default: $DEFAULT_MOUNT_POINT): " USER_MOUNT_POINT
  if [ -n "$USER_MOUNT_POINT" ]; then
    MOUNT_POINT="$USER_MOUNT_POINT"
  else
    MOUNT_POINT="$DEFAULT_MOUNT_POINT"
  fi

  # Final confirmation prompt
  echo "You have chosen to format '$DISK_DEVICE' and mount it at '$MOUNT_POINT'."
  read -r -p "Are you sure you want to continue? This will ERASE ALL DATA on $DISK_DEVICE (yes/no): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    log "INFO" "User aborted the manual setup."
    exit 0
  fi
fi

#########################################################################
# Format the Disk with XFS
#########################################################################
log "INFO" "Formatting $DISK_DEVICE as XFS..."
if ! sudo mkfs.xfs -f "$DISK_DEVICE"; then
  log "ERROR" "Failed to format $DISK_DEVICE. Exiting."
  exit 1
fi

#########################################################################
# Create Mount Point Directory
#########################################################################
log "INFO" "Creating mount point at $MOUNT_POINT..."
if ! sudo mkdir -p "$MOUNT_POINT"; then
  log "ERROR" "Failed to create mount point directory $MOUNT_POINT. Exiting."
  exit 1
fi

#########################################################################
# Mount the Disk
#########################################################################
log "INFO" "Mounting $DISK_DEVICE to $MOUNT_POINT..."
if ! sudo mount "$DISK_DEVICE" "$MOUNT_POINT"; then
  log "ERROR" "Failed to mount $DISK_DEVICE to $MOUNT_POINT. Exiting."
  exit 1
fi

#########################################################################
# Update /etc/fstab for Persistence
#########################################################################
log "INFO" "Updating /etc/fstab for persistence..."
UUID=$(sudo blkid -s UUID -o value "$DISK_DEVICE")
if [ -z "$UUID" ]; then
  log "ERROR" "Could not retrieve UUID for $DISK_DEVICE. Exiting."
  exit 1
fi

if grep -q "$MOUNT_POINT" "$FSTAB_FILE"; then
  log "WARNING" "An entry for $MOUNT_POINT already exists in $FSTAB_FILE."
else
  # Backup fstab before modifying
  sudo cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%F_%T)"
  echo "UUID=$UUID $MOUNT_POINT xfs defaults 0 0" | sudo tee -a "$FSTAB_FILE" >/dev/null
  log "INFO" "Added $DISK_DEVICE to $FSTAB_FILE with UUID $UUID."
fi

#########################################################################
# Set Ownership and Permissions
#########################################################################
log "INFO" "Setting ownership and permissions for $USER on $MOUNT_POINT..."
if ! sudo chown -R "$USER":"$USER" "$MOUNT_POINT"; then
  log "WARNING" "Failed to set ownership on $MOUNT_POINT."
fi
if ! sudo chmod -R 700 "$MOUNT_POINT"; then
  log "WARNING" "Failed to set permissions on $MOUNT_POINT."
fi

#########################################################################
# Verify the Setup
#########################################################################
log "INFO" "Verifying the setup..."
if df -h | grep -q "$MOUNT_POINT" && mount | grep -q "$MOUNT_POINT"; then
  log "SUCCESS" "$DISK_DEVICE successfully mounted to $MOUNT_POINT."
else
  log "ERROR" "Verification failed. Please check the mount and configuration manually."
  exit 1
fi

log "INFO" "XFS setup completed successfully."
exit 0