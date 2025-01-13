AlgoDock: Algorand Validator Node with Automated Participation Key Renewal

Effortlessly deploy and manage an Algorand validator node with automated participation key renewal, all secured using Docker Compose and Docker Secrets. This repository includes two additional utility scripts to prepare a secure Debian-based environment and manage Docker-related tasks effectively.

📋 Table of Contents
 1. Overview
 2. Features
 3. Prerequisites
 4. Setup Guide
 1. System Preparation with debian_docker_setup.sh
 2. Installing LazyDocker with update_lazydocker.sh
 3. Deploying the Validator Node
 5. Configuration
 6. Security Considerations
 7. Monitoring and Maintenance
 8. Troubleshooting
 9. Contributing
 10. License
 11. Acknowledgments

🚀 Overview

AlgoDock provides a streamlined way to deploy an Algorand validator node with Docker Compose. It features automated participation key renewal, ensuring your node remains active in the consensus process without manual intervention. The included setup scripts make it easy to prepare a secure environment with tools like Docker, security hardening mechanisms, and utility scripts for simplified management.

🌟 Features
 • Automated Participation Key Renewal: Keeps your node continuously active in the Algorand consensus.
 • Secure Secrets Management: Protects sensitive data using Docker Secrets.
 • System Setup Automation: Includes a script for setting up Debian systems with Docker and enhanced security features.
 • LazyDocker Integration: Simplifies Docker and container management with an intuitive terminal UI.
 • Dockerized Deployment: Ensures easy setup and scaling using Docker Compose.
 • Customizable Configurations: Supports MainNet/TestNet and adjustable participation key durations.

✅ Prerequisites

Before starting, ensure the following tools are installed or available on your system:
 1. Debian-based Operating System
 2. Root or Sudo Access
 3. Internet connectivity for downloading dependencies

🛠 Setup Guide

1. System Preparation with debian_docker_setup.sh

The debian_docker_setup.sh script configures a secure Debian environment by installing Docker, setting up firewall rules, and creating a non-root user (adebian) with SSH key-based access.

Steps:
 1. Clone this repository:

git clone https://github.com/NT-Nova/AlgoDock.git
cd AlgoDock


 2. Make the script executable:

chmod +x debian_docker_setup.sh


 3. Run the script with root privileges:

sudo ./debian_docker_setup.sh



Features of debian_docker_setup.sh:
 • Updates system packages and installs essential tools (Docker, fail2ban, UFW, etc.).
 • Creates a secure non-root user (adebian) with a password and SSH key.
 • Configures a custom SSH port (33322 by default) and applies basic firewall rules (UFW).
 • Enables security features like fail2ban and apparmor.

Once complete, log in as the adebian user to proceed with LazyDocker installation.

2. Installing LazyDocker with update_lazydocker.sh

The update_lazydocker.sh script installs or updates LazyDocker, a terminal UI for managing Docker containers.

Steps:
 1. Switch to the adebian user:

su - adebian


 2. Make the script executable:

chmod +x update_lazydocker.sh


 3. Run the script:

./update_lazydocker.sh



Features of update_lazydocker.sh:
 • Detects if LazyDocker is installed and its version.
 • Automatically downloads and installs the latest version compatible with your OS and architecture.
 • Supports both macOS and Debian-based Linux systems.

Once LazyDocker is installed, you can easily manage Docker containers using its intuitive interface.

3. Deploying the Validator Node

Clone the Repository:

Ensure you are in the AlgoDock directory.

Prepare Secrets:
 1. Create a directory for secrets:

mkdir secrets
chmod 700 secrets


 2. Add the required files to the secrets directory:
 • ACCOUNT_MNEMONIC: Your 25-word Algorand account mnemonic.
 • ALGOD_TOKEN: Your Algod API token.
 • WALLET_NAME: Your wallet name.
 • WALLET_PASSWORD: Your wallet password.
Example:

echo -n "your_25_word_mnemonic_here" > secrets/ACCOUNT_MNEMONIC
echo -n "your_algod_token_here" > secrets/ALGOD_TOKEN
echo -n "your_wallet_name_here" > secrets/WALLET_NAME
echo -n "your_wallet_password_here" > secrets/WALLET_PASSWORD
chmod 600 secrets/*



Configure the Network:

Download the appropriate genesis.json file for your network:
 • MainNet:

wget -O algod/config/genesis.json https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/mainnet/genesis.json


 • TestNet:

wget -O algod/config/genesis.json https://raw.githubusercontent.com/algorand/go-algorand/refs/heads/master/installer/genesis/testnet/genesis.json



Build and Start the Node:
 1. Build the Docker image:

docker compose build


 2. Start the Algorand node:

docker compose up -d


 3. Verify the node is running:

docker compose ps

🔧 Configuration
 • Environment Variables:
Modify docker-compose.yml to adjust variables such as ALGOD_ADDRESS.
 • Key Validity Duration:
Update KEY_VALIDITY_DURATION in auto_key_renewal.py to set the validity period for participation keys (default: 30 days).
 • Network Selection:
Use MainNet or TestNet by downloading the corresponding genesis.json file or adjusting the NETWORK build argument.

🔒 Security Considerations
 1. Secrets Management:
Ensure the secrets directory has 700 permissions and files have 600 permissions.
 2. Non-Root Execution:
The node runs as a non-root user (algoranduser) within the container.
 3. Firewall Rules:
Restrict access to ports 8080, 4001, and 4002 to trusted IP ranges.

📈 Monitoring and Maintenance
 • View Logs:

docker compose logs -f algorand-node


 • Check Node Status:

docker compose exec algorand-node goal node status -d /algod/data


 • Update Algorand Software:

docker compose pull
docker compose up -d

🛠 Troubleshooting
 • Node Synchronization:
Ensure proper network connectivity and firewall configuration.
 • Permission Errors:
Verify secrets have correct permissions and ownership.
 • Docker Issues:
Ensure Docker Compose v1.13.0 or higher is installed.

🤝 Contributing

Contributions are welcome! To contribute:
 1. Fork the repository.
 2. Create a feature branch:

git checkout -b feature/AmazingFeature


 3. Commit your changes:

git commit -m "Add AmazingFeature"


 4. Push to the branch:

git push origin feature/AmazingFeature


 5. Open a pull request.

📄 License

This project is licensed under the MIT License. See the LICENSE file for more details.

🙏 Acknowledgments
 • Algorand: For their innovative blockchain technology.
 • Docker: For simplifying containerization.
 • LazyDocker: For making Docker management easy.
 • Community Contributors: For their invaluable feedback and contributions.

Empower your blockchain journey with AlgoDock for an automated and secure Algorand validator node deployment!