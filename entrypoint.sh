#!/bin/bash

set -e  # Exit on command failure
set -u  # Treat unset variables as an error

# Paths and environment variables
ALGORAND_DATA="/algod/data"
LOG_FILE="/algod/logs/node.log"
NETWORK=${NETWORK:-mainnet}  # Default to MainNet
CATCHPOINT_URL="https://algorand-catchpoints.s3.us-east-2.amazonaws.com/channel/$NETWORK/latest.catchpoint"

# Function to fetch the latest catchpoint
fetch_catchpoint() {
    echo "[INFO] Fetching the latest catchpoint for $NETWORK..."
    CATCHPOINT=$(curl -s "$CATCHPOINT_URL" | tr -d '\n')
    if [ -z "$CATCHPOINT" ]; then
        echo "[ERROR] Failed to retrieve the catchpoint. Exiting."
        exit 1
    fi
    echo "[INFO] Latest catchpoint for $NETWORK: $CATCHPOINT"
}

# Ensure the config.json is properly configured for fast catchup
configure_fast_catchup() {
    CONFIG_FILE="$ALGORAND_DATA/config.json"
    
    echo "[INFO] Configuring $CONFIG_FILE for fast catchup..."
    
    # Check if config.json exists; create it if not
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[INFO] config.json not found. Creating a new one..."
        echo '{ "EnableCatchup": true }' > "$CONFIG_FILE"
    else
        # Update or add the EnableCatchup setting
        if grep -q '"EnableCatchup":' "$CONFIG_FILE"; then
            sed -i.bak 's/"EnableCatchup":.*/"EnableCatchup": true,/' "$CONFIG_FILE"
        else
            sed -i.bak '1s/^/{ "EnableCatchup": true, /' "$CONFIG_FILE"
        fi
    fi
    
    echo "[INFO] Configured $CONFIG_FILE for fast catchup."
}

# Function to apply fast catchup
fast_catchup() {
    fetch_catchpoint
    echo "[INFO] Applying fast catchup with catchpoint: $CATCHPOINT"
    if ! goal node catchup "$CATCHPOINT" -d "$ALGORAND_DATA"; then
        echo "[ERROR] Fast catchup failed. Exiting."
        exit 1
    fi
}

# Function to check node sync status
is_synced() {
    local status
    status=$(goal node status -d "$ALGORAND_DATA" 2>&1 || echo "[ERROR] Unable to get node status.")
    if echo "$status" | grep -q "Sync Time"; then
        local sync_time
        sync_time=$(echo "$status" | grep "Sync Time" | awk '{print $3}')
        if [ "$sync_time" == "0.0s" ]; then
            return 0  # Node is fully synchronized
        fi
    fi
    return 1  # Node is not synchronized
}

# Function to wait for sync
wait_for_sync() {
    echo "[INFO] Waiting for the node to synchronize..."
    until is_synced; do
        echo "[INFO] Node is not yet synchronized. Retrying in 10 seconds..."
        sleep 10
    done
    echo "[INFO] Node is fully synchronized."
}

# Start the node
start_node() {
    echo "[INFO] Starting the Algorand node..."
    if goal node start -d "$ALGORAND_DATA"; then
        echo "[INFO] Node started successfully."
    else
        echo "[ERROR] Failed to start the node. Exiting."
        exit 1
    fi
}

# Monitor logs
monitor_logs() {
    # Ensure log file exists
    if [ ! -f "$LOG_FILE" ]; then
        echo "[INFO] Creating placeholder log file at $LOG_FILE..."
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"
    fi

    echo "[INFO] Monitoring logs from $LOG_FILE..."
    tail -f "$LOG_FILE" &
    TAIL_PID=$!
}

# Main logic
main() {
    # Ensure the data directory exists
    if [ ! -d "$ALGORAND_DATA" ]; then
        echo "[ERROR] Data directory $ALGORAND_DATA does not exist. Exiting."
        exit 1
    fi

    # Ensure genesis.json is present
    if [ ! -f "$ALGORAND_DATA/genesis.json" ]; then
        echo "[ERROR] genesis.json not found in $ALGORAND_DATA. Exiting."
        exit 1
    fi

    # Configure the node for fast catchup
    configure_fast_catchup

    # Start the node
    start_node

    # Monitor the logs
    monitor_logs

    # Check if the node is already synchronized
    if is_synced; then
        echo "[INFO] Node is already synchronized."
    else
        echo "[INFO] Node is not synchronized. Checking for existing blockchain data..."
        if [ -z "$(ls -A "$ALGORAND_DATA")" ]; then
            echo "[INFO] Data directory is empty. Initiating fast catchup."
            fast_catchup
        else
            echo "[INFO] Resuming existing sync."
            wait_for_sync
        fi
    fi

    # Keep the container running
    wait "$TAIL_PID"
}

# Execute the main process
main