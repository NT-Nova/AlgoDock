# Use the official Algorand Docker image as the base
FROM algorand/algod:latest

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ALGORAND_DATA=/algod/data
ENV PATH="/root/.local/bin:/algod/myenv/bin:$PATH"

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
    rm -rf /var/lib/apt/lists/*

# Set up and activate a Python virtual environment for pipx and algokit
RUN python3 -m venv /algod/myenv && \
    /algod/myenv/bin/pip install --upgrade pip && \
    /algod/myenv/bin/pip install pipx && \
    /algod/myenv/bin/pipx install algokit

# Enables and activate env in bash
RUN echo "source /algod/myenv/bin/activate" > /root/.bashrc

# Set up directories and copy scripts
WORKDIR /algod
RUN mkdir -p /algod/logs
COPY check_node_metrics.py auto_key_renewal.py ./

# Install Python dependencies in the virtual environment
COPY requirements.txt /algod/
RUN if [ -f requirements.txt ]; then \
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

# Set the entrypoint
COPY entrypoint.sh /node/run/entrypoint.sh
RUN chmod +x /node/run/entrypoint.sh
ENTRYPOINT ["/node/run/entrypoint.sh"]