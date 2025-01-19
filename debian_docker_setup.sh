#!/usr/bin/env bash

###############################################################################
# Script: Setup adebian user, Docker, security tools on Debian
# Description:
#   - Updates packages
#   - Creates a 'adebian' user with password and SSH key
#   - Installs Docker and common security tools
#   - Improves logging and UI
#   - Changes SSH port to 33322
#   - Opens Mosh (60000:61000/udp) and WireGuard (51820/udp) ports in UFW
#   - Ensures all software is installed before usage
#
# Usage:
#   sudo ./setup_adebian.sh [--no-color] [--log /path/to/logfile] [--help]
###############################################################################

# Default configuration
LOG_FILE="/var/log/setup_adebian.log"
USE_COLOR=true
SSH_NEW_PORT="33322"

###############################################################################
# Color and Logging Functions
###############################################################################
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_info() {
    local msg="$1"
    if [ "$USE_COLOR" = true ]; then
        echo -e "[$(timestamp)] \e[32m[INFO]\e[0m $msg"
    else
        echo "[$(timestamp)] [INFO] $msg"
    fi
    echo "[$(timestamp)] [INFO] $msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="$1"
    if [ "$USE_COLOR" = true ]; then
        echo -e "[$(timestamp)] \e[33m[WARN]\e[0m $msg"
    else
        echo "[$(timestamp)] [WARN] $msg"
    fi
    echo "[$(timestamp)] [WARN] $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="$1"
    if [ "$USE_COLOR" = true ]; then
        echo -e "[$(timestamp)] \e[31m[ERROR]\e[0m $msg"
    else
        echo "[$(timestamp)] [ERROR] $msg"
    fi
    echo "[$(timestamp)] [ERROR] $msg" >> "$LOG_FILE"
}

###############################################################################
# Parse Command Line Arguments
###############################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-color)
            USE_COLOR=false
            shift
            ;;
        --log)
            LOG_FILE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--no-color] [--log /path/to/log] [--help]"
            exit 0
            ;;
        *)
            log_warn "Unknown option: $1"
            shift
            ;;
    esac
done

# Ensure the log file is writable
touch "$LOG_FILE" || { echo "Cannot write to log file $LOG_FILE"; exit 1; }

###############################################################################
# Pre-checks
###############################################################################

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script as root (e.g., with sudo)."
    exit 1
fi

# Check if running on Debian-like system
if ! grep -qi "debian" /etc/*release; then
    log_warn "This script is intended for Debian-based systems. Proceed with caution."
fi

###############################################################################
# Update & Install Required Packages
###############################################################################
log_info "Updating and upgrading packages..."
apt-get update -y >> "$LOG_FILE" 2>&1
apt-get upgrade -y >> "$LOG_FILE" 2>&1

log_info "Installing required tools and security packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg lsb-release apt-transport-https \
  software-properties-common ufw fail2ban apparmor apparmor-utils mosh whiptail git vim python3-pip pipx >> "$LOG_FILE" 2>&1

###############################################################################
# UI (Password and SSH Key Input)
###############################################################################

ask_password() {
    # Now we have whiptail installed, we can safely use it if available
    if command -v whiptail >/dev/null 2>&1; then
        while true; do
            ADEBIAN_PASS=$(whiptail --passwordbox "Please enter a password for the 'adebian' user:" 8 78 --title "adebian Password" 3>&1 1>&2 2>&3)
            exitstatus=$?
            [ $exitstatus -ne 0 ] && { log_error "Password input canceled."; exit 1; }
            
            ADEBIAN_PASS_CONFIRM=$(whiptail --passwordbox "Confirm the password:" 8 78 --title "Confirm Password" 3>&1 1>&2 2>&3)
            exitstatus=$?
            [ $exitstatus -ne 0 ] && { log_error "Password confirmation canceled."; exit 1; }

            if [ "$ADEBIAN_PASS" == "$ADEBIAN_PASS_CONFIRM" ] && [ -n "$ADEBIAN_PASS" ]; then
                break
            else
                whiptail --msgbox "Passwords do not match or were empty. Please try again." 8 78 --title "Error"
            fi
        done
    else
        # Fallback to standard read if whiptail not found (shouldn't happen since we installed it)
        echo "Please enter a password for the 'adebian' user:"
        read -s ADEBIAN_PASS
        echo
        echo "Confirm the password:"
        read -s ADEBIAN_PASS_CONFIRM
        echo
        if [ "$ADEBIAN_PASS" != "$ADEBIAN_PASS_CONFIRM" ] || [ -z "$ADEBIAN_PASS" ]; then
            log_error "Passwords do not match or were empty."
            exit 1
        fi
    fi
}

ask_ssh_key() {
    if command -v whiptail >/dev/null 2>&1; then
        ADEBIAN_SSH_KEY=$(whiptail --inputbox "Please paste the SSH public key for the 'adebian' user (e.g. ssh-rsa AAAA...):" 10 78 --title "adebian SSH Key" 3>&1 1>&2 2>&3)
        exitstatus=$?
        if [ $exitstatus -ne 0 ] || [ -z "$ADEBIAN_SSH_KEY" ]; then
            log_error "SSH key input canceled or empty."
            exit 1
        fi
    else
        # Fallback to standard read if whiptail not found
        echo "Please paste the SSH public key for the 'adebian' user (e.g. ssh-rsa AAAA...):"
        read ADEBIAN_SSH_KEY
        if [ -z "$ADEBIAN_SSH_KEY" ]; then
            log_error "No SSH key provided."
            exit 1
        fi
    fi
}

###############################################################################
# User Setup
###############################################################################
log_info "Creating adebian user if not exist..."
if ! id -u adebian >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" adebian >> "$LOG_FILE" 2>&1
else
    log_warn "User 'adebian' already exists. Proceeding."
fi

ask_password
log_info "Setting password for adebian user..."
echo "adebian:$ADEBIAN_PASS" | chpasswd >> "$LOG_FILE" 2>&1

ask_ssh_key
log_info "Configuring SSH authorized keys for adebian..."
HOME_DIR="/home/adebian"
SSH_DIR="$HOME_DIR/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
echo "$ADEBIAN_SSH_KEY" > "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R adebian:adebian "$SSH_DIR"

log_info "Creating DATA folder in adebian home..."
mkdir -p "$HOME_DIR/DATA"
chown adebian:adebian "$HOME_DIR/DATA"

###############################################################################
# Change SSH Port
###############################################################################
SSHD_CONFIG="/etc/ssh/sshd_config"
log_info "Changing SSH port to $SSH_NEW_PORT..."

if grep -qE "^#?Port 22" "$SSHD_CONFIG"; then
    sed -i "s/^#Port 22/Port $SSH_NEW_PORT/" "$SSHD_CONFIG"
    sed -i "s/^Port 22/Port $SSH_NEW_PORT/" "$SSHD_CONFIG"
else
    echo "Port $SSH_NEW_PORT" >> "$SSHD_CONFIG"
fi

systemctl restart ssh || {
    log_error "Failed to restart SSH service. Please check your SSH configuration."
    exit 1
}

###############################################################################
# Docker Installation
###############################################################################
log_info "Installing Docker..."
# Remove old Docker versions if any
apt-get remove -y docker docker-engine docker.io containerd runc >> "$LOG_FILE" 2>&1 || true

log_info "Setting up Docker repository..."
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >> "$LOG_FILE" 2>&1
fi
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y >> "$LOG_FILE" 2>&1
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

log_info "Adding adebian to docker group..."
usermod -aG docker adebian

log_info "Adding adebian to docker group..."
usermod -aG sudo adebian

systemctl enable docker >> "$LOG_FILE" 2>&1
systemctl start docker >> "$LOG_FILE" 2>&1

###############################################################################
# Security Hardening (Basic)
###############################################################################
log_info "Configuring UFW (Firewall) ..."
ufw default deny incoming >> "$LOG_FILE" 2>&1 || true
ufw default allow outgoing >> "$LOG_FILE" 2>&1 || true

# Allow SSH on port 33322
ufw allow ${SSH_NEW_PORT}/tcp >> "$LOG_FILE" 2>&1 || true

# Allow Mosh and WireGuard
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1 || true
ufw allow 51820/udp >> "$LOG_FILE" 2>&1 || true

# Allow Algorand Node Ports
ufw allow 4160/tcp >> "$LOG_FILE" 2>&1 || true
ufw allow 4161/tcp >> "$LOG_FILE" 2>&1 || true
ufw allow 8080/tcp >> "$LOG_FILE" 2>&1 || true

ufw allow 7833/tcp >> "$LOG_FILE" 2>&1 || true

ufw --force enable >> "$LOG_FILE" 2>&1 || true

log_info "Enabling fail2ban service..."
systemctl enable fail2ban >> "$LOG_FILE" 2>&1
systemctl start fail2ban >> "$LOG_FILE" 2>&1

###############################################################################
# Finished
###############################################################################
log_info "Setup is complete!"
log_info "The 'adebian' user has been created with the provided password and SSH key."
log_info "SSH is now configured on port $SSH_NEW_PORT. Please connect using: ssh -p $SSH_NEW_PORT adebian@<your_server_ip>"
log_info "Docker and security tools have been installed and configured."
log_info "UFW has been configured to allow Mosh, WireGuard, and the new SSH port."

# Prompt the user for LazyDocker installation or update
log_info "Do you want to install or update LazyDocker? (yes/no)"
read -r user_response

if [[ "$user_response" =~ ^[Yy][Ee][Ss]$|^[Yy]$ ]]; then
  log_info "Running LazyDocker installation or update as user 'adebian'..."
  sudo -u adebian bash -c "./update_lazydocker.sh" || die "Failed to install or update LazyDocker."
else
  log_info "Skipping LazyDocker installation or update."
fi

log_info "You can review the log at $LOG_FILE."