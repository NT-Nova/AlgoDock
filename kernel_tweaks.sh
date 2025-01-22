#!/bin/bash
#########################################################################
# Script Name: kernel_tweaks.sh
#
# Description:
#   This script applies a series of kernel performance tweaks via sysctl,
#   saving the settings persistently. It gathers system metrics, validates 
#   the environment, and applies changes transactionally – meaning if one 
#   setting fails, previously changed parameters are rolled back.
#
#   Additionally, if one or more XFS filesystems are present, the script
#   applies additional performance tweaks (such as increasing readahead values)
#   for the corresponding block devices.
#
# Usage:
#   sudo ./kernel_tweaks.sh [OPTIONS]
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
LOG_FILE="/var/log/kernel_tweaks.log"
DEBUG=false
DRY_RUN=false
SYSCTL_CONF="/etc/sysctl.d/99-performance-tweaks.conf"
# (UDEV_RULES reserved for future use)
UDEV_RULES="/etc/udev/rules.d/60-io-scheduler.rules"

# ANSI color codes for UI formatting.
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# Associative arrays to hold new parameters, their descriptions, and original values.
declare -A SYSCTL_PARAMS
declare -A SYSCTL_DESCRIPTIONS
declare -A ORIGINAL_VALUES

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

# Print the help message.
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

# Display a spinner for a running process (given a PID).
spinner() {
  local pid="$1"
  local delay=0.1
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    local temp="${spinstr#?}"
    printf " [%c] " "$spinstr"
    spinstr=${temp}${spinstr%"$temp"}
    sleep "$delay"
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# Check for root privileges or sudo availability.
check_root() {
  if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo &>/dev/null; then
      echo "sudo is required. Please install sudo or run as root."
      exit 1
    fi
  fi
}

# Validate that essential files and directories exist and are writable.
validate_environment() {
  # Check /proc/meminfo exists.
  if [ ! -r /proc/meminfo ]; then
    log "ERROR" "/proc/meminfo is not readable. Aborting."
    exit 1
  fi

  # Check that the log file directory is writable.
  if [ ! -w "$(dirname "$LOG_FILE")" ]; then
    echo "Log directory $(dirname "$LOG_FILE") is not writable. Aborting."
    exit 1
  fi

  # Check that the sysctl configuration directory is writable.
  if [ ! -w "$(dirname "$SYSCTL_CONF")" ]; then
    log "ERROR" "Configuration directory $(dirname "$SYSCTL_CONF") is not writable. Aborting."
    exit 1
  fi

  # Optionally, check available disk space for backups.
  local avail
  avail=$(df --output=avail "$(dirname "$SYSCTL_CONF")" | tail -1)
  if (( avail < 1048576 )); then  # less than ~1GB free
    log "ERROR" "Not enough free disk space in $(dirname "$SYSCTL_CONF") for backups. Aborting."
    exit 1
  fi

  log "INFO" "Environment validated successfully."
}

# Gather system metrics: total RAM in kB and CPU count.
get_system_metrics() {
  TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  CPU_COUNT=$(nproc)
  log "INFO" "Detected system memory: ${TOTAL_RAM_KB} kB, CPU count: ${CPU_COUNT}"
}

#########################################################################
# Define and Calculate Parameters
#########################################################################
get_and_define_parameters() {
  # Calculate vm.min_free_kbytes based on 1% of total RAM, with a minimum threshold.
  CALC_MIN_FREE_KB=$(( TOTAL_RAM_KB / 100 ))
  if (( CALC_MIN_FREE_KB < 65536 )); then
    CALC_MIN_FREE_KB=65536
  fi
  log "INFO" "Calculated vm.min_free_kbytes: ${CALC_MIN_FREE_KB} kB (1% of total memory