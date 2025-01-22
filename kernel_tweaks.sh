#!/bin/bash
#########################################################################
# Script Name: kernel_tweaks_enhanced.sh
#
# Description:
#   This script applies kernel performance tweaks dynamically based on the
#   system's CPU and RAM configuration. It includes additional best-practice
#   parameters for maximizing system throughput and responsiveness.
#   Docker and XFS filesystems are tuned if detected. Transparent Huge Pages
#   can optionally be disabled; CPU governors can be set to "performance".
#
# Usage:
#   sudo ./kernel_tweaks_enhanced.sh [OPTIONS]
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
  local TIMESTAMP
  TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
  printf "%b[%s]%b [%b%s%b] %b%s%b\n" \
    "$COLOR_DATE" "$TIMESTAMP" "$COLOR_RESET" \
    "$COLOR" "$LEVEL" "$COLOR_RESET" \
    "$COLOR_MESSAGE" "$MESSAGE" "$COLOR_RESET" | tee -a "$LOG_FILE"
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
    echo "# $PARAM added for compatibility. Value will be set if applicable." >> "$SYSCTL_CONF"
    return 1
  fi
  return 0
}

is_docker_installed() {
  command -v docker &>/dev/null
}

apply_sysctl_param() {
  local PARAM="$1"
  local VALUE="$2"
  if check_sysctl_param "$PARAM"; then
    sysctl -w "$PARAM=$VALUE"
    success "Applied sysctl: $PARAM = $VALUE"
    # Persist the setting
    sed -i "/^$PARAM\s*=/d" "$SYSCTL_CONF" 2>/dev/null || true
    echo "$PARAM = $VALUE" >> "$SYSCTL_CONF"
  else
    warn "Skipped sysctl: $PARAM (parameter added for Debian compatibility)"
  fi
}

#########################################################################
# Optional Tuning Functions
#########################################################################
disable_transparent_hugepages() {
  # For workloads that benefit from disabling THP (databases, etc.).
  # Check if THP is available; not all kernels have /sys/kernel/mm/transparent_hugepage
  if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    info "Disabling Transparent Huge Pages (THP)..."
    echo never > /sys/kernel/mm/transparent_hugepage/enabled || warn "Cannot disable THP."
    echo never > /sys/kernel/mm/transparent_hugepage/defrag || warn "Cannot disable THP defrag."
    success "Transparent Huge Pages disabled."
    # Persist across reboots (varies by distro/init system):
    if [ -f /etc/rc.local ]; then
      grep -q "transparent_hugepage" /etc/rc.local || {
        echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.local
        echo "echo never > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.local
      }
    else
      warn "/etc/rc.local not found; ensure THP settings persist manually."
    fi
  else
    info "Transparent Huge Pages not found or not supported in this kernel. Skipping."
  fi
}

apply_cpu_governor() {
  # For performance-oriented setups, force CPU scaling governor to "performance".
  if [ -d /sys/devices/system/cpu ]; then
    info "Setting CPU frequency scaling governor to 'performance'..."
    for governor_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      if [ -f "$governor_file" ]; then
        echo performance > "$governor_file" || warn "Failed to set $governor_file to performance."
      fi
    done
    success "CPU governors set to performance."
  else
    warn "CPU frequency scaling not found or not supported. Skipping governor setting."
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

  # Basic VM tunings
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
  apply_sysctl_param "vm.overcommit_ratio" "100"

  # File system limits
  apply_sysctl_param "fs.file-max" "2097152"
  apply_sysctl_param "fs.inotify.max_user_watches" "1048576"
  apply_sysctl_param "fs.aio-max-nr" "1048576"
  apply_sysctl_param "fs.nr_open" "2097152"

  # Network stack tunings
  apply_sysctl_param "net.core.netdev_max_backlog" "5000"
  apply_sysctl_param "net.core.rmem_max" "16777216"
  apply_sysctl_param "net.core.wmem_max" "16777216"
  apply_sysctl_param "net.core.somaxconn" "4096"
  apply_sysctl_param "net.core.default_qdisc" "fq"
  apply_sysctl_param "net.ipv4.tcp_congestion_control" "bbr"
  apply_sysctl_param "net.ipv4.tcp_fin_timeout" "15"
  apply_sysctl_param "net.ipv4.tcp_max_syn_backlog" "8192"
  apply_sysctl_param "net.ipv4.tcp_rmem" "4096 87380 16777216"
  apply_sysctl_param "net.ipv4.tcp_wmem" "4096 87380 16777216"
  apply_sysctl_param "net.ipv4.tcp_slow_start_after_idle" "0"
  apply_sysctl_param "net.ipv4.ip_local_port_range" "1024 65535"

  # Bridge (Docker / container) settings
  apply_sysctl_param "net.bridge.bridge-nf-call-iptables" "1"
  apply_sysctl_param "net.bridge.bridge-nf-call-ip6tables" "1"

  # CPU / Scheduler tunings
  apply_sysctl_param "kernel.sched_min_granularity_ns" "10000000"
  apply_sysctl_param "kernel.sched_wakeup_granularity_ns" "15000000"
  apply_sysctl_param "kernel.numa_balancing" "0"
  apply_sysctl_param "kernel.pid_max" "4194304"

  # Randomness tunings
  apply_sysctl_param "kernel.random.read_wakeup_threshold" "128"
  apply_sysctl_param "kernel.random.write_wakeup_threshold" "256"

  success "Sysctl settings applied successfully."
}

apply_docker_tweaks() {
  if is_docker_installed; then
    info "Docker detected. Applying Docker performance tweaks..."
    mkdir -p /etc/docker
    cat <<EOF | tee "$DOCKER_CONF"
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
    systemctl daemon-reload
    systemctl restart docker
    success "Docker performance tweaks applied successfully."
  else
    info "Docker not detected. Skipping Docker tweaks."
  fi
}

apply_xfs_tweaks() {
  info "Checking for XFS filesystems and applying performance tweaks..."
  check_command "findmnt"
  for mount_point in $(findmnt -n -t xfs -o TARGET 2>/dev/null || true); do
    block_device=$(findmnt -n -t xfs -o SOURCE --target "$mount_point" 2>/dev/null || true)
    if [ -n "$block_device" ]; then
      info "Applying XFS tweaks for $block_device mounted at $mount_point..."
      check_command "xfs_io"
      xfs_io -c 'extsize 1m' "$block_device" || warn "Failed to apply XFS extent size tweak."
    fi
  done
  success "XFS performance tweaks applied successfully."
}

reload_settings() {
  info "Reloading sysctl settings..."
  sysctl --system
  success "Sysctl settings reloaded successfully."
}

main() {
  check_root
  check_command "sysctl"

  # Parse arguments
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

  info "Starting enhanced kernel tweaks..."
  get_system_metrics

  # Core performance tweaks
  apply_sysctl
  apply_docker_tweaks
  apply_xfs_tweaks

  # Optional advanced tunings (uncomment as desired)
  # disable_transparent_hugepages
  # apply_cpu_governor

  # Reload sysctl settings to ensure they persist
  reload_settings

  success "All kernel tweaks applied successfully. Check $LOG_FILE for details."
}

main "$@"