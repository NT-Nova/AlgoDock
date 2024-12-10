# Use the official Algorand Docker image as the base
FROM algorand/go-algorand

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ALGORAND_DATA=/algod/data

# Optional ARGs to customize genesis URL (default: MainNet)
ARG NETWORK="mainnet"
ARG GENESIS_URL="hhttps://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/${NETWORK}/genesis.json"

# Update and install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Set up directories for logs
RUN mkdir -p /algod/logs

# Copy Python scripts into the container
COPY check_node_metrics.py /algod/
COPY auto_key_renewal.py /algod/

# Install Python dependencies (if any)
COPY requirements.txt /algod/requirements.txt
RUN pip3 install --no-cache-dir -r /algod/requirements.txt

# Check for genesis.json and download if it doesn't exist
RUN if [ ! -f ${ALGORAND_DATA}/genesis.json ]; then \
      echo "[INFO] genesis.json not found. Downloading from ${GENESIS_URL}" && \
      curl -fSL "${GENESIS_URL}" -o ${ALGORAND_DATA}/genesis.json; \
    else \
      echo "[INFO] Using existing genesis.json"; \
    fi

# Expose necessary ports
EXPOSE 8080 4001 4002

# Set up volume for logs
VOLUME ["/algod/logs"]

# Set the entrypoint
ENTRYPOINT ["/node/run/run.sh"]