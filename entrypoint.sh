#!/bin/bash

set -e  # Exit on command failure
set -u  # Treat unset variables as an error

# Paths and environment variables
ALGORAND_DATA="/algod/data"
LOG_FILE="/algod/logs/node.log"
NETWORK=${NETWORK:-mainnet}  # Use "mainnet" as default
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
    if echo "$status" | grep -q "Last committed block"; then
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

    # Start the node
    start_node

    # Check if the node is already synced
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

    # Monitor the logs
    echo "[INFO] Monitoring logs from $LOG_FILE..."
    tail -f "$LOG_FILE" &
    TAIL_PID=$!

    # Keep the container running
    wait "$TAIL_PID"
}

# Execute the main process
main