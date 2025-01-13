# Use the official Algorand Docker image as the base
FROM algorand/algod:latest

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ALGORAND_DATA=/algod/data
ENV PATH="/algod/myenv/bin:$PATH"

# Optional ARGs to customize genesis URL (default: MainNet)
ARG NETWORK="mainnet"
ARG GENESIS_URL="https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/${NETWORK}/genesis.json"

# Update and install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3.11-venv \
    curl \
    jq && \
    python3 -m pip install --upgrade pip && \
    python3 -m pip install pipx && \
    pipx install algokit && \
    rm -rf /var/lib/apt/lists/*

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
      curl -fSL "${GENESIS_URL}" -o "${ALGORAND_DATA}/genesis.json" || \
      (echo "[ERROR] Failed to download genesis.json" && exit 1); \
    else \
      echo "[INFO] Using existing genesis.json"; \
    fi

# Expose necessary ports (REST API, Node communication)
EXPOSE 8080 4001 4002

# Set up volume for logs
VOLUME ["/algod/logs"]

# Set the entrypoint
COPY entrypoint.sh /node/run/entrypoint.sh
RUN chmod +x /node/run/entrypoint.sh
ENTRYPOINT ["/node/run/entrypoint.sh"]