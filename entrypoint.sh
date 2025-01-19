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

ensure_config() {
    CONFIG_FILE="${ALGORAND_DATA}/config.json"
    log_info "Ensuring config.json exists and is properly formatted..."

    # If config.json doesn't exist, download it
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "config.json not found. Downloading from ${CONFIG_URL}..."
        curl -fSL "${CONFIG_URL}" -o "$CONFIG_FILE" || {
            log_error "Failed to download config.json. Exiting."
            exit 1
        }
    fi

    # Recommended configuration changes
    declare -A RECOMMENDED_CONFIG=(
        ["EnableCatchup"]=true
        ["EnableRestAPI"]=true
        ["DNSSecurityFlags"]=9
        ["DisableAPIAuth"]=false
        ["DisableLocalhostConnectionRateLimit"]=true
        ["EnableGossipBlockService"]=true
        ["EnableGossipService"]=true
        ["EnableTxBacklogRateLimiting"]=true
        ["EnableMetricReporting"]=true
        ["EnableAgreementReporting"]=true
        ["EnableP2P"]=true
        ["FallbackDNSResolverAddress"]="8.8.8.8"
        ["EndpointAddress"]=":8080"
        ["PublicAddress"]="152.53.86.170:4160"
        ["NetAddress"]=":4160"
        ["EnableRelay"]=false
        ["AnnounceParticipationKey"]=true
        ["MaxConnections"]=64
    )

    log_info "Updating config.json with recommended settings..."
    for key in "${!RECOMMENDED_CONFIG[@]}"; do
        value=${RECOMMENDED_CONFIG[$key]}

        # Check if the key exists in config.json
        if jq -e ".${key}" "$CONFIG_FILE" >/dev/null 2>&1; then
            # If the value differs, update it
            current_value=$(jq -r ".${key}" "$CONFIG_FILE")
            if [ "$current_value" != "$value" ]; then
                log_info "Updating $key from $current_value to $value..."
                if [[ "$value" =~ ^[0-9]+$|^(true|false)$ ]]; then
                    # Use --argjson for numeric/boolean values
                    jq --arg key "$key" --argjson value "$value" '.[$key] = $value' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
                else
                    # Use --arg for string values
                    jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
                fi
            fi
        else
            # Add the key-value pair if it doesn't exist
            log_info "Adding $key with value $value..."
            if [[ "$value" =~ ^[0-9]+$|^(true|false)$ ]]; then
                jq --arg key "$key" --argjson value "$value" '.[$key] = $value' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            else
                jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            fi
        fi
    done

    # Validate the resulting JSON structure
    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        log_error "Invalid JSON structure in $CONFIG_FILE. Exiting."
        exit 1
    fi

    log_info "Config.json updated successfully and validated."
}

# Function to fetch the latest catchpoint
fetch_catchpoint() {
    log_info "Fetching the latest catchpoint for $NETWORK..."
    CATCHPOINT=$(curl -s "$CATCHPOINT_URL" | tr -d '\n') || exit_with_error "Failed to fetch catchpoint"
    if [ -z "$CATCHPOINT" ]; then
        exit_with_error "Catchpoint is empty. Check the network configuration."
    fi
    log_info "Retrieved catchpoint key: [$CATCHPOINT]"
}

# Function to apply fast catchup
apply_fast_catchup() {
    fetch_catchpoint
    log_info "Initiating fast catchup using catchpoint: [$CATCHPOINT]..."
    # Run the catchup command and log if it starts successfully
    if goal node catchup "$CATCHPOINT" -d "$ALGORAND_DATA"; then
        log_info "Fast catchup restore process has started and is running."
    else
        exit_with_error "Fast catchup failed to start."
    fi
}

# Refined function to check if the node is synchronized
is_node_synced() {
    local status
    status=$(goal node status -d "$ALGORAND_DATA" 2>&1) || { log_error "Unable to get node status"; return 1; }

    # Using sed to strip non-digits from the lines that mention sync times.
    local sync_time_rem
    sync_time_rem=$(echo "$status" | grep -i "Sync Time Remaining" | sed -E 's/[^0-9]+//g')
    local sync_time
    sync_time=$(echo "$status" | grep -i "Sync Time:" | sed -E 's/[^0-9]+//g')

    log_info "Parsed sync time remaining: [${sync_time_rem}] and sync time: [${sync_time}]."

    if [ -n "$sync_time_rem" ] && [ -n "$sync_time" ]; then
        if [[ "$sync_time_rem" == "0" && "$sync_time" == "0" ]]; then
            return 0
        fi
    else
        log_info "Warning: Could not extract sync times from node status output."
    fi
    return 1
}

# Function to monitor node synchronization with an initial delay
monitor_sync() {
    log_info "Waiting for the node to stabilize before checking sync status..."
    sleep 15

    log_info "Monitoring node synchronization..."
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
        log_info "Algorand node successfully started!"
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
    ensure_config  # Ensure config.json is properly set up
    start_node

    sleep 15

    if is_node_synced; then
        log_info "Node is already synchronized."
    else
        DATA_SIZE=$(du -s "$ALGORAND_DATA" 2>/dev/null | awk '{print $1}')
        log_info "Data folder size: ${DATA_SIZE} bytes."

        # Define the threshold for 1 GB in bytes
        ONE_GB=1073741824

        # Determine whether blockchain data (a folder starting with the network name) exists,
        # and that the data folder size is greater than 1 GB.
        if compgen -G "${ALGORAND_DATA}/${NETWORK}*" > /dev/null && [ "${DATA_SIZE}" -gt "${ONE_GB}" ]; then
            # Your code when both conditions are true
            log_info "Blockchain data folder detected (matching ${NETWORK}*) and the data folder size is greater than 1 GB.(${DATA_SIZE})"
            start_node
        else
            log_info "Initiating fast catchup..."
            if apply_fast_catchup; then
                log_info "Catchup process finished successfully. Starting node normally."
                start_node
            else
                exit_with_error "Fast catchup failed."
            fi
        fi
    fi

   # Start monitoring logs so we can see detailed output.
    monitor_logs

    wait "$TAIL_PID"  # Keep the container running
}

# Execute the main process
main



    
