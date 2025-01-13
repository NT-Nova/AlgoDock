#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error

# Paths and environment variables
ALGORAND_DATA="/algod/data"
LOG_FILE="/algod/logs/node.log"
NETWORK=${NETWORK:-mainnet}  # Default network is MainNet
GENESIS_URL="https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/${NETWORK}/genesis.json"
CONFIG_URL="https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/config.json.example"
CATCHPOINT_URL="https://algorand-catchpoints.s3.us-east-2.amazonaws.com/channel/$NETWORK/latest.catchpoint"

# Helper functions
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
exit_with_error() { log_error "$*"; exit 1; }

# Function to ensure the data directory exists
ensure_data_dir() {
    if [ ! -d "$ALGORAND_DATA" ]; then
        log_info "Creating data directory at $ALGORAND_DATA..."
        mkdir -p "$ALGORAND_DATA"
    fi
}

# Function to download genesis.json if not present
ensure_genesis() {
    log_info "Ensuring genesis.json exists for $NETWORK..."
    if [ ! -f "${ALGORAND_DATA}/genesis.json" ]; then
        log_info "genesis.json not found. Downloading from ${GENESIS_URL}..."
        curl -fSL "${GENESIS_URL}" -o "${ALGORAND_DATA}/genesis.json" || exit_with_error "Failed to download genesis.json"
    else
        log_info "genesis.json already exists. Skipping download."
    fi
}

# Function to download or configure config.json
ensure_config() {
    CONFIG_FILE="${ALGORAND_DATA}/config.json"
    log_info "Ensuring config.json exists..."
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "config.json not found. Downloading from ${CONFIG_URL}..."
        curl -fSL "${CONFIG_URL}" -o "$CONFIG_FILE" || exit_with_error "Failed to download config.json"
    fi

    # Add or enable EnableCatchup in config.json
    log_info "Configuring $CONFIG_FILE for fast catchup..."
    if grep -q '"EnableCatchup":' "$CONFIG_FILE"; then
        sed -i.bak 's/"EnableCatchup":.*/"EnableCatchup": true,/' "$CONFIG_FILE"
    else
        sed -i.bak '1s/^/{ "EnableCatchup": true, /' "$CONFIG_FILE"
    fi
    log_info "Config.json configured successfully."
}

# Function to fetch the latest catchpoint
fetch_catchpoint() {
    log_info "Fetching the latest catchpoint for $NETWORK..."
    CATCHPOINT=$(curl -s "$CATCHPOINT_URL" | tr -d '\n') || exit_with_error "Failed to fetch catchpoint"
    if [ -z "$CATCHPOINT" ]; then
        exit_with_error "Catchpoint is empty. Check the network configuration."
    fi
    log_info "Latest catchpoint: $CATCHPOINT"
}

# Function to apply fast catchup
apply_fast_catchup() {
    fetch_catchpoint
    log_info "Applying fast catchup with catchpoint: $CATCHPOINT..."
    goal node catchup "$CATCHPOINT" -d "$ALGORAND_DATA" || exit_with_error "Fast catchup failed"
}

# Function to check if the node is synchronized
is_node_synced() {
    local status
    status=$(goal node status -d "$ALGORAND_DATA" 2>&1 || log_error "Unable to get node status")
    if echo "$status" | grep -q "Sync Time: 0.0s"; then
        return 0  # Node is synchronized
    fi
    return 1  # Node is not synchronized
}

# Function to monitor node synchronization
monitor_sync() {
    log_info "Waiting for the node to synchronize..."
    until is_node_synced; do
        log_info "Node is not synchronized yet. Retrying in 10 seconds..."
        sleep 10
    done
    log_info "Node is fully synchronized."
}

# Function to start the Algorand node
start_node() {
    log_info "Starting the Algorand node..."
    if goal node start -d "$ALGORAND_DATA"; then
        log_info "Algorand node started successfully."
    else
        exit_with_error "Failed to start the Algorand node"
    fi
}

# Function to monitor logs
monitor_logs() {
    log_info "Monitoring logs from $LOG_FILE..."
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    tail -f "$LOG_FILE" &
    TAIL_PID=$!
}

# Main process
main() {
    ensure_data_dir
    ensure_genesis
    ensure_config
    start_node
    monitor_logs

    if is_node_synced; then
        log_info "Node is already synchronized."
    else
        if [ -z "$(ls -A "$ALGORAND_DATA")" ]; then
            log_info "Data directory is empty. Initiating fast catchup..."
            apply_fast_catchup
        else
            log_info "Resuming existing sync."
            monitor_sync
        fi
    fi

    wait "$TAIL_PID"  # Keep the container running
}

# Execute the main process
main