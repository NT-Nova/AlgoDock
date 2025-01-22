#!/bin/bash
#########################################################################
# Script Name: kernel_tweaks.sh
#
# Description:
#   This script applies kernel performance tweaks dynamically by calculating
#   certain parameters based on the system's CPU and RAM configuration.
#   It includes additional tweaks for Docker and XFS filesystems if detected.
#   Changes are saved persistently to sysctl configuration files and applied.
#
# Usage:
#   sudo ./kernel_tweaks.sh [OPTIONS]
#
# Options:
#   --debug      Enable debug mode.
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
SYSCTL_CONF="/etc/sysctl.d/99-performance-tweaks.conf"
UDEV_RULES="/etc/udev/rules.d/60-io-scheduler.rules"
XFS_CONF="/etc/sysconfig/xfs_tweaks.conf"
DOCKER_CONF="/etc/docker/daemon.json"

# ANSI color codes for enhanced logging
COLOR_RESET="\e[0m"
COLOR_DATE="\e[90m"
COLOR_TYPE_INFO="\e[97m"
COLOR_TYPE_WARN="\e[33m"
COLOR_TYPE_ADDED="\e[38;5;208m"
COLOR_MESSAGE="\e[37m"
COLOR_SUCCESS="\e[32m"
COLOR_ERROR="\e[31m"

#########################################################################
# Logging Functions
#########################################################################
log() {
  local LEVEL="$1"
  local COLOR="$2"
  shift 2
  local MESSAGE="$*"
  local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
  printf "%b[%s]%b [%b%s%b] %b%s%b\n" "$COLOR_DATE" "$TIMESTAMP" "$COLOR_RESET" "$COLOR" "$LEVEL" "$COLOR_RESET" "$COLOR_MESSAGE" "$MESSAGE" "$COLOR_RESET" | tee -a "$LOG_FILE"
}

info() {
  log "INFO" "$COLOR_TYPE_INFO" "$*"
}

success() {
  log "SUCCESS" "$COLOR_SUCCESS" "$*"
}

warn() {
  log "WARNING" "$COLOR_TYPE_WARN" "$*"
}

added() {
  log "ADDED" "$COLOR_TYPE_ADDED" "$*"
}

error() {
  log "ERROR" "$COLOR_ERROR" "$*"
  exit 1
}

# Debugging Function
debug() {
  if $DEBUG; then
    log "DEBUG" "$COLOR_TYPE_INFO" "$*"
  fi
}

#########################################################################
# Error Handling
#########################################################################
trap 'error "Script interrupted or encountered an unexpected error."' ERR
trap 'info "Cleaning up and exiting..."' EXIT

#########################################################################
# Helper Functions
#########################################################################
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --debug      Enable debug mode.
  -h, --help   Show this help message and exit.
EOF
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root or using sudo."
  fi
}

check_command() {
  if ! command -v "$1" &>/dev/null; then
    warn "Command $1 not found. Installing it..."
    apt-get update && apt-get install -y "$1" || error "Failed to install $1."
  fi
}

check_sysctl_param() {
  local PARAM="$1"
  if [ ! -e "/proc/sys/$PARAM" ]; then
    added "Sysctl parameter /proc/sys/$PARAM does not exist. Adding it for Debian compatibility if safe..."
    echo "$PARAM" >> "$SYSCTL_CONF"
    return 1
  fi
  return 0
}

is_docker_installed() {
  if command -v docker &>/dev/null; then
    return 0
  fi
  return 1
}

apply_sysctl_param() {
  local PARAM="$1"
  local VALUE="$2"
  if check_sysctl_param "$PARAM"; then
    sysctl -w "$PARAM=$VALUE"
    success "Applied sysctl: $PARAM = $VALUE"
  else
    warn "Skipped sysctl: $PARAM (parameter added for Debian compatibility)"
  fi
}

#########################################################################
# Main Functions
#########################################################################
get_system_metrics() {
  TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  CPU_COUNT=$(nproc)
  info "Detected system memory: ${TOTAL_RAM_KB} kB, CPU count: ${CPU_COUNT}"
}

apply_sysctl() {
  info "Applying sysctl settings dynamically based on system metrics..."

  local SWAPPINESS=10
  local DIRTY_RATIO=15
  local DIRTY_BG_RATIO=5
  local MIN_FREE_KBYTES=$(( TOTAL_RAM_KB / 100 ))
  if (( MIN_FREE_KBYTES < 65536 )); then
    MIN_FREE_KBYTES=65536
  fi

  apply_sysctl_param "vm.swappiness" "$SWAPPINESS"
  apply_sysctl_param "vm.dirty_ratio" "$DIRTY_RATIO"
  apply_sysctl_param "vm.dirty_background_ratio" "$DIRTY_BG_RATIO"
  apply_sysctl_param "vm.min_free_kbytes" "$MIN_FREE_KBYTES"
  apply_sysctl_param "vm.overcommit_memory" "1"

  apply_sysctl_param "fs.file-max" "2097152"
  apply_sysctl_param "fs.inotify.max_user_watches" "1048576"
  apply_sysctl_param "fs.aio-max-nr" "1048576"

  apply_sysctl_param "net.core.netdev_max_backlog" "5000"
  apply_sysctl_param "net.core.rmem_max" "16777216"
  apply_sysctl_param "net.core.wmem_max" "16777216"
  apply_sysctl_param "net.ipv4.tcp_rmem" "4096 87380 16777216"
  apply_sysctl_param "net.ipv4.tcp_wmem" "4096 87380 16777216"
  apply_sysctl_param "net.ipv4.tcp_congestion_control" "bbr"
  apply_sysctl_param "net.ipv4.tcp_fin_timeout" "15"
  apply_sysctl_param "net.ipv4.tcp_max_syn_backlog" "8192"
  apply_sysctl_param "net.core.somaxconn" "4096"

  apply_sysctl_param "net.bridge.bridge-nf-call-iptables" "1"
  apply_sysctl_param "net.bridge.bridge-nf-call-ip6tables" "1"

  apply_sysctl_param "kernel.sched_min_granularity_ns" "10000000"
  apply_sysctl_param "kernel.sched_wakeup_granularity_ns" "15000000"
  apply_sysctl_param "kernel.numa_balancing" "0"
  apply_sysctl_param "kernel.pid_max" "4194304"
  apply_sysctl_param "kernel.random.read_wakeup_threshold" "128"
  apply_sysctl_param "kernel.random.write_wakeup_threshold" "256"

  success "Sysctl settings applied successfully."
}

apply_docker_tweaks() {
  if is_docker_installed; then
    info "Docker detected. Applying Docker performance tweaks..."
    mkdir -p /etc/docker
    cat <<EOF | sudo tee "$DOCKER_CONF"
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "bip": "192.168.1.1/24"
}
EOF
    systemctl restart docker
    success "Docker performance tweaks applied successfully."
  else
    info "Docker not detected. Skipping Docker tweaks."
  fi
}

apply_xfs_tweaks() {
  info "Checking for XFS filesystems and applying performance tweaks..."
  for mount_point in $(findmnt -n -t xfs -o TARGET 2>/dev/null || true); do
    block_device=$(findmnt -n -t xfs -o SOURCE --target "$mount_point" 2>/dev/null || true)
    if [ -n "$block_device" ]; then
      info "Applying XFS tweaks for $block_device mounted at $mount_point..."
      if ! command -v xfs_io &>/dev/null; then
        warn "Command xfs_io not found. Installing it..."
        apt-get update && apt-get install -y xfsprogs || error "Failed to install xfsprogs."
      fi
      xfs_io -c 'extsize 1m' "$block_device" || warn "Failed to apply XFS extent size tweak."
    fi
  done
  success "XFS performance tweaks applied successfully."
}

reload_settings() {
  info "Reloading sysctl settings..."
  sudo sysctl --system
  success "Sysctl settings reloaded successfully."
}

main() {
  check_root
  check_command "sysctl"
  check_command "findmnt"

  if [[ $# -eq 0 ]]; then
    info "No arguments provided. Running with default settings."
  fi
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --debug)
        DEBUG=true
        info "Debug mode enabled."
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        ;;
    esac
    shift
  done

  info "Starting kernel tweaks..."
  get_system_metrics
  apply_sysctl
  apply_docker_tweaks
  apply_xfs_tweaks
  reload_settings
  success "Kernel tweaks applied successfully. Check $LOG_FILE for details."
}

main "$@"