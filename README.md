# AlgoDock: Algorand Validator Node with Automated Participation Key Renewal

Effortlessly deploy your own Algorand validator node with automated participation key renewal, secured using Docker Compose and Docker Secrets.

🚀 Overview

AlgoDock provides a seamless solution for deploying an Algorand validator node using Docker Compose. It includes an automated script for participation key renewal, ensuring your node remains active in the consensus process without manual intervention. Security is a top priority, with Docker Secrets used to handle sensitive data securely.

📋 Table of Contents
- Features
- Prerequisites
- Setup Guide
    1. Clone the Repository
    2. Prepare Secrets
    3. Configure the Network
    4. Build and Run with Docker Compose
- 🔧 Configuration
- 🔒 Security Considerations
- 📈 Monitoring and Maintenance
- 🛠 Troubleshooting
- 🤝 Contributing
- 📄 License
- 🙏 Acknowledgments

🌟 Features

- Automated Participation Key Renewal: Keeps your node continuously participating in the Algorand consensus without manual intervention.
- Secure Secrets Management: Utilizes Docker Secrets to securely handle sensitive information.
- Dockerized Deployment: Simplifies setup and management using Docker Compose.
- Non-Root Execution: Runs the node and scripts as a non-root user for enhanced security.
- Customizable Configuration: Easily switch between MainNet and TestNet or adjust key validity durations to suit your needs.

✅ Prerequisites

Before starting, ensure you have the following tools installed on your system:

- Docker: 👉 Install Docker
- Docker Compose (v1.13.0 or higher): 👉 Install Docker Compose
- Git: 👉 Install Git

🛠 Setup Guide

1. Clone the Repository

```bash
git clone https://github.com/NT-Nova/AlgoDock.git
cd AlgoDock
```

2. Prepare Secrets

Create a secrets directory to securely store sensitive data:

```bash
mkdir secrets
chmod 700 secrets
```
Add files for each secret:

- ACCOUNT_MNEMONIC: Your 25-word Algorand account mnemonic.
- ALGOD_TOKEN: Your Algod API token.
- WALLET_NAME: The name of your Algorand wallet.
- WALLET_PASSWORD: The password for your Algorand wallet.

Example:

```bash
echo -n "your_25_word_mnemonic_here" > secrets/ACCOUNT_MNEMONIC
echo -n "your_algod_token_here" > secrets/ALGOD_TOKEN
echo -n "your_wallet_name_here" > secrets/WALLET_NAME
echo -n "your_wallet_password_here" > secrets/WALLET_PASSWORD
```

```bash
chmod 600 secrets/*
```

⚠️ Important: Replace placeholders with your actual credentials. Never expose these files publicly.

3. Configure the Network

Download the genesis.json file for your desired network and place it in the algod/config directory.

The genesis file can be fetched dynamically by modifying the Dockerfile with the following build argument:

```bash
ARG GENESIS_URL="https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/${NETWORK}/genesis.json"
```

Alternatively, download the file manually:
- MainNet:

```bash
wget -O algod/config/genesis.json https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/mainnet/genesis.json
```

- TestNet:

```bash
wget -O algod/config/genesis.json https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/testnet/genesis.json
```

4. Build and Run with Docker Compose

Build the Docker image:

docker-compose build

Start the Algorand node:

docker-compose up -d

Verify the node is running:

docker-compose ps

🔧 Configuration

- Environment Variables: Modify docker-compose.yml to change environment variables like ALGOD_ADDRESS.
- Participation Key Validity: Adjust the KEY_VALIDITY_DURATION in auto_key_renewal.py to set the validity duration of participation keys (default: ~30 days).
- Network Selection: Switch between MainNet and TestNet by downloading the respective genesis.json file or modifying the NETWORK build argument in the Dockerfile.

🔒 Security Considerations
1.Secrets Management:
Ensure the secrets directory and files have strict permissions (700 for the directory, 600 for the files).
2.Non-Root Execution:
The container runs as a non-root user (algoranduser) to minimize security risks.
3.Firewall Settings:
Secure exposed ports (8080, 4001, 4002) by restricting access to trusted networks only.

📈 Monitoring and Maintenance

- View Logs:

docker-compose logs -f algorand-node

- Check Node Status:

docker-compose exec algorand-node goal node status -d /algod/data

- Update Algorand Software:

```bash
docker-compose pull
docker-compose up -d
```

🛠 Troubleshooting

- Node Not Synchronizing:
Ensure network connectivity and proper firewall settings. Verify the server can connect to Algorand peer nodes.
- Permission Issues:
Double-check that the secrets directory and files have correct permissions and ownership.
- Docker Compose Version:
Use Docker Compose v1.13.0 or higher to support the secrets feature.

🤝 Contributing

Contributions are welcome! To contribute:
1.Fork the repository.
2.Create a feature branch:

```bash
git checkout -b feature/AmazingFeature
```

3.Commit your changes:

```bash
git commit -m "Add AmazingFeature"
```

4.Push to the branch:

```bash
git push origin feature/AmazingFeature
```

5.Open a pull request.

📄 License

This project is licensed under the MIT License. See the LICENSE file for more details.

🙏 Acknowledgments

- Algorand: For their innovative blockchain technology.
- Docker: For simplifying containerization.
- Paweł Pierścionek (Urtho): For the insightful article on Algorand Key Registration.
- Community Contributors: For their continuous support and feedback.

🚀 Empower your blockchain journey with an automated and secure Algorand validator node deployment using AlgoDock!

Let me know if additional refinements are needed!