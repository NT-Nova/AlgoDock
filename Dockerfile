# Use the official Algorand Docker image as the base
FROM algorand/algod:latest

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ALGORAND_DATA=/algod/data

# Optional ARGs to customize genesis URL (default: MainNet)
ARG NETWORK="mainnet"
ARG GENESIS_URL="https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/${NETWORK}/genesis.json"

# Update and install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3.11-venv \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Set up directories and copy scripts
WORKDIR /algod
RUN mkdir -p /algod/logs
COPY check_node_metrics.py auto_key_renewal.py ./

# Install Python dependencies in a virtual environment
RUN python3 -m venv /algod/myenv && \
    /algod/myenv/bin/pip install --no-cache-dir --upgrade pip && \
    if [ -f requirements.txt ]; then \
        /algod/myenv/bin/pip install --no-cache-dir -r requirements.txt; \
    fi

# Ensure genesis.json is present
RUN if [ ! -f "${ALGORAND_DATA}/genesis.json" ]; then \
      echo "[INFO] genesis.json not found. Downloading from ${GENESIS_URL}" && \
      curl -fSL "${GENESIS_URL}" -o "${ALGORAND_DATA}/genesis.json"; \
    else \
      echo "[INFO] Using existing genesis.json"; \
    fi

# Expose necessary ports
EXPOSE 8080 4001 4002

# Set up volume for logs
VOLUME ["/algod/logs"]

# # Set the entrypoint
# ENTRYPOINT ["/node/run/run.sh"]

# Set the entrypoint
COPY entrypoint.sh /node/run/entrypoint.sh
RUN chmod +x /node/run/entrypoint.sh
ENTRYPOINT ["/node/run/entrypoint.sh"]