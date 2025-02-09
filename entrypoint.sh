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

# Ensure `/opt/func/` and run `FUNC` in the background
# start_func_service() {
#     log_info "Navigating to /opt/func/..."
#     cd /opt/func/ || exit_with_error "Failed to navigate to /opt/func/"

#     log_info "Starting FUNC service in the background..."
#     ./FUNC &
# }

# Function to ensure the data directory exists
ensure_data_dir() {
    if [ ! -d "${ALGORAND_DATA}" ]; then
        log_info "Creating data directory at ${ALGORAND_DATA}..."
        mkdir -p "${ALGORAND_DATA}"
    fi
}

# Function to download genesis.json if not present
ensure_genesis() {
    local genesis_file="${ALGORAND_DATA}/genesis.json"
    log_info "Ensuring genesis.json exists for ${NETWORK}..."
    if [ ! -f "${genesis_file}" ]; then
        log_info "genesis.json not found. Downloading from ${GENESIS_URL}..."
        curl -fSL "${GENESIS_URL}" -o "${genesis_file}" || exit_with_error "Failed to download genesis.json"
    else
        log_info "genesis.json already exists. Skipping download."
    fi
}

ensure_config() {
    local config_file="${ALGORAND_DATA}/config.json"
    log_info "Ensuring config.json exists and is properly formatted..."

    # If something exists at config.json and it's not a file (for example, a directory), remove it.
    if [ -e "${config_file}" ] && [ ! -f "${config_file}" ]; then
        log_info "Found ${config_file} exists but is not a file. Removing it..."
        rm -rf "${config_file}"
    fi

    # If config.json doesn't exist, download it.
    if [ ! -f "${config_file}" ]; then
        log_info "config.json not found. Downloading from ${CONFIG_URL}..."
        curl -fSL "${CONFIG_URL}" -o "${config_file}" || exit_with_error "Failed to download config.json"
    fi

    # Recommended configuration settings.
    declare -A RECOMMENDED_CONFIG=(
        [EnableCatchup]=true
        [EnableRestAPI]=true
        [EnableRelay]=false
        [MaxConnections]=64
        [EnableTelemetry]=true
        [LedgerSynchronousMode]=2
        [GossipFanout]=10
        [BaseLoggerDebugLevel]=3
        [DNSSecurityFlags]=0
        [Archival]=false
        [EndpointAddress]="0.0.0.0:8080"
        [NetAddress]="0.0.0.0:38086"
        [EnableP2P]=true
        [EnableMetricReporting]=true
        [NodeExporterPath]="/node/bin/node_exporter --web.listen-address=0.0.0.0:9100"
        [EnableRuntimeMetrics]=true
        [EnableLedgerService]=true
        [EnableBlockService]=true
        [DatabaseReadOnly]=false
        [SQLiteJournalMode]="WAL"
        [SQLiteSynchronous]="NORMAL"
        [SQLiteLockTimeout]=20000
        [SQLitePageSize]=16384
        [SQLiteCacheSize]=2000000
        [SQLiteBusyTimeout]=20000
        [DeadlockDetection]=0
        [TransactionTimeoutSeconds]=10
        [SQLiteTempStore]="MEMORY"
        [SQLiteMmapSize]=268435456
        [SQLiteDefaultTimeout]=20000
        [CatchupParallelBlocks]=8
        [EnableCatchupFromArchival]=false
        [DisableNetworking]=false
        [MaxCatchupBlocks]=100
        [EnableProcessBlockStats]=true
    )

    # Update or add each recommended key in config.json.
    for key in "${!RECOMMENDED_CONFIG[@]}"; do
        value="${RECOMMENDED_CONFIG[${key}]}"
        if jq -e ".${key}" "${config_file}" >/dev/null 2>&1; then
            current_value=$(jq -r ".${key}" "${config_file}")
            if [ "${current_value}" != "${value}" ]; then
                log_info "Updating ${key} from ${current_value} to ${value}..."
                if [[ "${value}" =~ ^[0-9]+$|^(true|false)$ ]]; then
                    jq --arg key "${key}" --argjson value "${value}" '.[$key] = $value' "${config_file}" > "${config_file}.tmp" \
                        && mv "${config_file}.tmp" "${config_file}"
                else
                    jq --arg key "${key}" --arg value "${value}" '.[$key] = $value' "${config_file}" > "${config_file}.tmp" \
                        && mv "${config_file}.tmp" "${config_file}"
                fi
            fi
        else
            log_info "Adding ${key} with value ${value}..."
            if [[ "${value}" =~ ^[0-9]+$|^(true|false)$ ]]; then
                jq --arg key "${key}" --argjson value "${value}" '.[$key] = $value' "${config_file}" > "${config_file}.tmp" \
                    && mv "${config_file}.tmp" "${config_file}"
            else
                jq --arg key "${key}" --arg value "${value}" '.[$key] = $value' "${config_file}" > "${config_file}.tmp" \
                    && mv "${config_file}.tmp" "${config_file}"
            fi
        fi
    done

    # # Unconditionally update ExcludeFields array.
    # log_info "Updating ExcludeFields..."
    # jq '.ExcludeFields = ["Metrics", "details"]' "${config_file}" > "${config_file}.tmp" && mv "${config_file}.tmp" "${config_file}"

    # Validate the JSON structure.
    if ! jq empty "${config_file}" >/dev/null 2>&1; then
        exit_with_error "Invalid JSON structure in ${config_file}. Exiting."
    fi

    log_info "config.json updated and validated successfully."
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

start_node_kmd() {
    log_info "Starting the Algorand KMD..."
    if goal kmd start -d "$ALGORAND_DATA"; then
        log_info "Algorand KMD successfully started!"
    else
        exit_with_error "Failed to start the Algorand KMD"
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

# Function to ensure Elasticsearch mapping
# ensure_es_mapping() {
#     local ELASTIC_URL="http://algomon-elasticsearch:9200"
#     local INDEX_NAME="stable-mainnet-v1.0"
#     local MAPPING_FILE="data/mapping.json"  # Adjust path if needed
#     local ELASTIC_USER="elastic"
#     local ELASTIC_PASSWORD="elastic"

#     log_info "Checking Elasticsearch mapping and settings for index: $INDEX_NAME..."

#     # Check if the index exists
#     if ! curl -s -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL/$INDEX_NAME" > /dev/null; then
#         log_error "Index $INDEX_NAME does not exist. Please create the index before applying the mapping."
#         return 1
#     fi

#     # Set the number of replicas to 0
#     log_info "Setting number_of_replicas to 0 for $INDEX_NAME..."
#     if ! curl -s -u "$ELASTIC_USER:$ELASTIC_PASSWORD" -X PUT "$ELASTIC_URL/$INDEX_NAME/_settings" \
#         -H "Content-Type: application/json" -d '{
#           "index": {
#             "number_of_replicas": 0
#           }
#         }'; then
#         log_error "Failed to update the number_of_replicas for $INDEX_NAME. Exiting."
#         return 1
#     fi
#     log_info "Successfully set number_of_replicas to 0 for $INDEX_NAME."

#     # Fetch current mapping
#     local current_mapping
#     current_mapping=$(curl -s -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL/$INDEX_NAME/_mapping")

#     # Check if current mapping is valid
#     if [ -z "$current_mapping" ] || ! echo "$current_mapping" | jq -e . > /dev/null 2>&1; then
#         log_error "Failed to fetch current mapping for $INDEX_NAME. Exiting."
#         return 1
#     fi

#     # Define expected mapping for comparison (compact JSON)
#     local expected_mapping
#     if ! expected_mapping=$(jq -c . "$MAPPING_FILE" 2>/dev/null); then
#         log_error "Failed to read or parse the mapping file: $MAPPING_FILE. Exiting."
#         return 1
#     fi

#     # Compare current mapping with expected mapping
#     if echo "$current_mapping" | grep -q "$expected_mapping"; then
#         log_info "Elasticsearch mapping for $INDEX_NAME is already correct."
#         return 0
#     fi

#     log_info "Elasticsearch mapping for $INDEX_NAME is incorrect or missing. Updating mapping..."

#     # Close the index to apply mapping changes
#     log_info "Closing the index $INDEX_NAME..."
#     if ! curl -s -u "$ELASTIC_USER:$ELASTIC_PASSWORD" -X POST "$ELASTIC_URL/$INDEX_NAME/_close"; then
#         log_error "Failed to close the index $INDEX_NAME. Exiting."
#         return 1
#     fi

#     # Apply the mapping
#     log_info "Applying the updated mapping to $INDEX_NAME..."
#     if ! curl -s -u "$ELASTIC_USER:$ELASTIC_PASSWORD" -X PUT "$ELASTIC_URL/$INDEX_NAME/_mapping" \
#         -H "Content-Type: application/json" -d @"$MAPPING_FILE"; then
#         log_error "Failed to update the mapping for $INDEX_NAME. Exiting."
#         return 1
#     fi

#     # Reopen the index after applying mapping
#     log_info "Reopening the index $INDEX_NAME..."
#     if ! curl -s -u "$ELASTIC_USER:$ELASTIC_PASSWORD" -X POST "$ELASTIC_URL/$INDEX_NAME/_open"; then
#         log_error "Failed to reopen the index $INDEX_NAME. Exiting."
#         return 1
#     fi

#     log_info "Elasticsearch mapping and settings for $INDEX_NAME have been updated and applied successfully."
#     return 0
# }

# Main process
main() {
    ensure_data_dir
    ensure_genesis
    ensure_config  # Ensure config.json is properly set up
    # ensure_es_mapping  # Ensure Elasticsearch mapping is correct
    start_node
    # start_node_kmd
   #/node/bin/node_exporter --web.listen-address="0.0.0.0:9100" &

    sleep 5

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
            # if apply_fast_catchup; then
            #     log_info "Catchup process finished successfully. Starting node normally."
            #     start_node
            # else
            #     exit_with_error "Fast catchup failed."
            # fi
        fi
    fi

   # Start monitoring logs so we can see detailed output.
    monitor_logs

    # # Start FUNC service
    # start_func_service
    
    wait "$TAIL_PID"  # Keep the container running
}

# Execute the main process
main



    
