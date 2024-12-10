#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error

# Paths
ALGORAND_DATA="/algod/data"
LOG_FILE="/algod/logs/node.log"
RENEWAL_SCRIPT="/algod/auto_key_renewal.py"
METRICS_SCRIPT="/algod/check_node_metrics.py"

# Function to check if the Algorand node is synchronized
wait_for_sync() {
    echo "[INFO] Waiting for the Algorand node to synchronize..."
    while true; do
        # Check node status
        STATUS=$(goal node status -d "$ALGORAND_DATA" 2>&1 || echo "[ERROR] Unable to get node status.")
        
        # Parse synchronization status
        if echo "$STATUS" | grep -q "Last committed block"; then
            SYNC_TIME=$(echo "$STATUS" | grep "Sync Time" | awk '{print $3}')
            if [ "$SYNC_TIME" == "0.0s" ]; then
                echo "[INFO] Node is synchronized."
                break
            else
                echo "[INFO] Node is not synchronized yet. Sync time: $SYNC_TIME"
            fi
        else
            echo "[WARNING] Node status unavailable. Retrying in 10 seconds..."
        fi
        sleep 10
    done
}

# Start the Algorand node
start_node() {
    echo "[INFO] Starting the Algorand node..."
    if goal node start -d "$ALGORAND_DATA"; then
        echo "[INFO] Node started successfully."
    else
        echo "[ERROR] Failed to start the node. Exiting."
        exit 1
    fi
}

# Monitor the node logs
monitor_logs() {
    echo "[INFO] Monitoring logs from $LOG_FILE..."
    tail -f "$LOG_FILE" &
    TAIL_PID=$!
}

# Run the participation key renewal script
run_key_renewal() {
    echo "[INFO] Starting the participation key renewal script..."
    if python3 "$RENEWAL_SCRIPT"; then
        echo "[INFO] Participation key renewal script executed successfully."
    else
        echo "[ERROR] Participation key renewal script failed."
    fi
}

# Run the metrics monitoring script
run_metrics_monitor() {
    echo "[INFO] Starting the node metrics monitoring script..."
    if python3 "$METRICS_SCRIPT"; then
        echo "[INFO] Node metrics monitoring script executed successfully."
    else
        echo "[ERROR] Node metrics monitoring script failed."
    fi
}

# Main process
main() {
    # Ensure the data directory exists
    if [ ! -d "$ALGORAND_DATA" ]; then
        echo "[ERROR] Data directory $ALGORAND_DATA does not exist. Exiting."
        exit 1
    fi

    # Start the node
    start_node

    # Start monitoring logs
    monitor_logs

    # Wait for the node to synchronize
    wait_for_sync

    # Run the participation key renewal script
    run_key_renewal

    # Run metrics monitoring in the background
    run_metrics_monitor &

    # Keep the container running
    wait "$TAIL_PID"
}

# Execute the main process
main