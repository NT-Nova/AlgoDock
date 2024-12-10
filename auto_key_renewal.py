import os
import subprocess
import time
from algosdk.v2client import algod
from algosdk import mnemonic
from datetime import datetime

# Constants: Set participation key validity and script behavior
KEY_VALIDITY_DURATION = 1_000_000  # ~30 days in Algorand rounds
CHECK_INTERVAL = 24 * 60 * 60      # Check for renewal once a day (in seconds)
SECRETS_PATH = "/run/secrets"      # Path where Docker secrets are mounted

def read_secret(secret_name: str) -> str:
    """
    Reads a secret from the Docker secrets directory.

    Args:
        secret_name (str): The name of the secret file to read.

    Returns:
        str: The content of the secret file.

    Raises:
        SystemExit: If the secret cannot be read.
    """
    secret_path = os.path.join(SECRETS_PATH, secret_name)
    try:
        with open(secret_path, 'r') as file:
            return file.read().strip()
    except Exception as e:
        print(f"[ERROR] Failed to read secret {secret_name}: {str(e)}")
        exit(1)

# Read secrets from Docker secrets
ALGOD_TOKEN = read_secret("ALGOD_TOKEN")
WALLET_PASSWORD = read_secret("WALLET_PASSWORD")
ACCOUNT_MNEMONIC = read_secret("ACCOUNT_MNEMONIC")
WALLET_NAME = read_secret("WALLET_NAME")

# Read optional environment variables
ALGOD_ADDRESS = os.getenv("ALGOD_ADDRESS", "http://0.0.0.0:4001")

def get_algod_client() -> algod.AlgodClient:
    """
    Initialize and return an AlgodClient instance.

    Returns:
        algod.AlgodClient: A client for interacting with the Algorand node.
    """
    try:
        return algod.AlgodClient(ALGOD_TOKEN, ALGOD_ADDRESS)
    except Exception as e:
        print(f"[CRITICAL] Failed to initialize Algod client: {str(e)}")
        exit(1)

def get_account_address() -> str:
    """
    Retrieve the public key (address) from the account mnemonic.

    Returns:
        str: The public address of the account.
    """
    try:
        return mnemonic.to_public_key(ACCOUNT_MNEMONIC)
    except Exception as e:
        print(f"[CRITICAL] Failed to retrieve account address from mnemonic: {str(e)}")
        exit(1)

def generate_new_participation_key(account_address: str, first_round: int, last_round: int):
    """
    Generate a new participation key for the given account using the 'goal' CLI.

    Args:
        account_address (str): The Algorand account address.
        first_round (int): The first round of the key's validity.
        last_round (int): The last round of the key's validity.
    """
    try:
        command = [
            "goal", "account", "addpartkey",
            "-a", account_address,
            "--roundFirst", str(first_round),
            "--roundLast", str(last_round),
            "-w", WALLET_NAME,
            "--password", WALLET_PASSWORD
        ]
        subprocess.run(command, check=True, capture_output=True)
        print(f"[INFO] New participation key generated for rounds {first_round} to {last_round}.")
    except subprocess.CalledProcessError as e:
        error_message = e.stderr.decode('utf-8') if e.stderr else str(e)
        print(f"[ERROR] Error generating participation key: {error_message}")

def delete_old_keys(account_address: str):
    """
    Remove old participation keys for the given account using the 'goal' CLI.

    Args:
        account_address (str): The Algorand account address.
    """
    try:
        command = [
            "goal", "account", "clearpartkey",
            "-a", account_address,
            "-w", WALLET_NAME,
            "--password", WALLET_PASSWORD
        ]
        subprocess.run(command, check=True, capture_output=True)
        print(f"[INFO] Old participation keys cleared for account {account_address}.")
    except subprocess.CalledProcessError as e:
        # It's possible no keys are present yet, so handle that gracefully.
        error_message = e.stderr.decode('utf-8') if e.stderr else str(e)
        print(f"[WARNING] Could not clear old participation keys: {error_message}")

def check_and_renew_keys():
    """
    Checks the current blockchain round and renews the participation key if necessary.
    """
    try:
        client = get_algod_client()
        account_address = get_account_address()

        # Get the current blockchain status
        status = client.status()
        current_round = status.get("last-round", 0)

        # Define the validity period for the new participation key
        first_round = current_round + 1
        last_round = first_round + KEY_VALIDITY_DURATION

        print(f"[INFO] Current Round: {current_round}")
        print(f"[INFO] Generating new key valid from round {first_round} to {last_round}.")

        # Delete old participation keys
        delete_old_keys(account_address)

        # Generate new participation key
        generate_new_participation_key(account_address, first_round, last_round)

    except Exception as e:
        print(f"[ERROR] An error occurred during key renewal: {str(e)}")

if __name__ == "__main__":
    print(f"[INFO] Starting participation key renewal script at {datetime.now()}")
    while True:
        try:
            check_and_renew_keys()
        except Exception as e:
            # Catch any unexpected errors to prevent the script from crashing
            print(f"[CRITICAL] Unexpected error: {str(e)}")

        print(f"[INFO] Sleeping until next check ({CHECK_INTERVAL // 3600} hours)...")
        time.sleep(CHECK_INTERVAL)