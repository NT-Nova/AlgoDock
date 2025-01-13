#!/bin/bash

# Enable strict error handling to ensure the script exits on errors or undefined variables
set -euo pipefail
# Define how the internal field separator (IFS) handles spaces, tabs, and newlines
IFS=$'\n\t'

# Enable debugging if the DEBUG environment variable is set to true
DEBUG=${DEBUG:-false}
if [ "$DEBUG" == "true" ]; then
  set -x
fi

# Logging functions for different log levels
log_info() { echo -e "\033[1;34m[INFO]\033[0m $*" >&2; } # Info messages
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; } # Warning messages
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; } # Error messages
die() { log_error "$*"; exit 1; } # Log error and exit the script

# Function to fetch the latest LazyDocker version
get_latest_version() {
  # Fetch the URL of the latest release and extract the version number
  local latest_url
  latest_url=$(curl -Ls -o /dev/null -w '%{url_effective}' https://github.com/jesseduffield/lazydocker/releases/latest)
  echo "$latest_url" | grep -o "tag/v[0-9.]*" | cut -d'v' -f2 || die "Failed to extract version from latest release URL."
}

# Function to generate the tarball download URL based on OS and architecture
get_tarball_url() {
  local version=$1
  local os=$2
  local arch=$3

  # Construct the URL based on OS and architecture
  if [ "$os" == "darwin" ]; then
    if [ "$arch" == "arm64" ]; then
      echo "https://github.com/jesseduffield/lazydocker/releases/download/v${version}/lazydocker_${version}_Darwin_arm64.tar.gz"
    else
      echo "https://github.com/jesseduffield/lazydocker/releases/download/v${version}/lazydocker_${version}_Darwin_x86_64.tar.gz"
    fi
  else
    echo "https://github.com/jesseduffield/lazydocker/releases/download/v${version}/lazydocker_${version}_Linux_x86_64.tar.gz"
  fi
}

# Function to get the installed LazyDocker version and architecture
get_installed_version_and_arch() {
  if command -v lazydocker &> /dev/null; then
    local version
    local arch

    # Extract the version and architecture from the LazyDocker binary
    version=$(lazydocker --version | awk -F: '/^Version/ {print $2}' | xargs || echo "0.0.0")
    arch=$(lazydocker --version | awk -F: '/^Arch/ {print $2}' | xargs || echo "unknown")
    echo "$version,$arch"
  else
    # Return a default value if LazyDocker is not installed
    echo "0.0.0,unknown"
  fi
}

# Function to download and install LazyDocker
install_lazydocker() {
  local tarball_url=$1
  local install_path=$2

  log_info "Downloading lazydocker tarball..."
  local temp_dir
  # Create a temporary directory for downloading the tarball
  temp_dir=$(mktemp -d) || die "Failed to create temporary directory."
  curl -L "$tarball_url" -o "$temp_dir/lazydocker.tar.gz" || die "Failed to download tarball."

  log_info "Extracting lazydocker binary..."
  # Extract the binary from the downloaded tarball
  tar -xzf "$temp_dir/lazydocker.tar.gz" -C "$temp_dir" || die "Failed to extract tarball."

  log_info "Installing lazydocker to $install_path..."
  # Copy the binary to the target installation path
  sudo cp "$temp_dir/lazydocker" "$install_path" || die "Failed to copy lazydocker binary."
  sudo chmod +x "$install_path" || die "Failed to make lazydocker executable."

  log_info "Cleaning up..."
  # Remove the temporary directory
  rm -rf "$temp_dir" || log_warn "Failed to clean up temporary directory."

  log_info "Lazydocker installed successfully to $install_path!"
}

# Main script logic
main() {
  # Detect the operating system and architecture
  local os="linux"
  local arch="x86_64"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    os="darwin"
    arch=$(uname -m) # e.g., arm64 or x86_64
  fi

  log_info "Checking installed lazydocker version and architecture..."
  local installed_info
  # Fetch the installed version and architecture of LazyDocker
  installed_info=$(get_installed_version_and_arch 2>/dev/null)
  local installed_version
  local installed_arch
  IFS=',' read -r installed_version installed_arch <<< "$installed_info"

  log_info "Installed lazydocker version: $installed_version, architecture: $installed_arch"

  log_info "Fetching the latest lazydocker version..."
  # Get the latest available version of LazyDocker
  local latest_version
  latest_version=$(get_latest_version)
  log_info "Latest lazydocker version: $latest_version"

  log_info "Comparing versions..."
  log_info "Local version: $installed_version, Remote version: $latest_version"

  # Check if the installed version matches the latest version
  if [ "$installed_version" != "0.0.0" ] && [ "$installed_version" == "$latest_version" ]; then
    log_info "Lazydocker is already up-to-date. Skipping installation."
    exit 0
  fi

  log_info "Preparing to download and install lazydocker..."
  # Generate the tarball URL for downloading LazyDocker
  local tarball_url
  tarball_url=$(get_tarball_url "$latest_version" "$os" "$arch")

  # Determine the installation path (overwrite existing binary if applicable)
  local install_path="/usr/local/bin/lazydocker"
  if [ "$installed_version" != "0.0.0" ]; then
    install_path=$(command -v lazydocker)
  fi

  # Install or update LazyDocker
  install_lazydocker "$tarball_url" "$install_path"
}

# Execute the main function
main "$@"