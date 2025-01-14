#!/usr/bin/env python3

import os
import subprocess
import time
import json
from datetime import datetime
from algosdk.v2client import algod
from algosdk import mnemonic
from rich.console import Console
from rich.logging import RichHandler

# Setup logging and console
import logging
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    datefmt="[%X]",
    handlers=[RichHandler(rich_tracebacks=True)]
)
logger = logging.getLogger("auto_key_renewal")
console = Console()

###############################################################################
# CONFIGURATION
###############################################################################
class Config:
    """
    Configuration for the key renewal script.
    """
    NODE_DIR = os.getenv("NODE_DIR", "/algod/data")
    ALGOD_ADDRESS = os.getenv("ALGOD_ADDRESS", "http://localhost:4001")
    ALGOD_TOKEN_PATH = os.getenv("ALGOD_TOKEN_PATH", f"{NODE_DIR}/algod.token")
    WALLET_NAME = os.getenv("WALLET_NAME", "my_wallet")
    ACCOUNT_MNEMONIC = os.getenv("ACCOUNT_MNEMONIC", None)
    WALLET_PASSWORD = os.getenv("WALLET_PASSWORD", None)
    KEY_VALIDITY_DURATION = int(os.getenv("KEY_VALIDITY_DURATION", 1_000_000))  # ~30 days
    CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", 24 * 60 * 60))  # 24 hours
    LOCAL_STORE_FILE = os.path.join(NODE_DIR, "accounts.json")

    @staticmethod
    def get_algod_token() -> str:
        """
        Retrieve Algod token either from environment or file.
        """
        try:
            if os.getenv("ALGOD_TOKEN"):
                return os.getenv("ALGOD_TOKEN")
            if os.path.exists(Config.ALGOD_TOKEN_PATH):
                with open(Config.ALGOD_TOKEN_PATH, "r") as file:
                    return file.read().strip()
            raise FileNotFoundError("Algod token not found in environment or token file.")
        except FileNotFoundError as e:
            logger.critical(f"{e}")
            console.print(f"[red][CRITICAL][/red] {e}")
            exit(1)
        except Exception as e:
            logger.critical(f"Unexpected error while fetching Algod token: {e}")
            console.print(f"[red][CRITICAL][/red] Unexpected error: {e}")
            exit(1)

###############################################################################
# HELPER FUNCTIONS
###############################################################################
def get_algod_client() -> algod.AlgodClient:
    """
    Initialize and return an AlgodClient instance.
    """
    try:
        return algod.AlgodClient(Config.get_algod_token(), Config.ALGOD_ADDRESS)
    except Exception as e:
        logger.critical(f"Failed to initialize Algod client: {e}")
        console.print(f"[red][CRITICAL][/red] Failed to initialize Algod client: {e}")
        exit(1)

def load_local_store() -> dict:
    """
    Load account addresses and names from the local store file.
    """
    try:
        if not os.path.exists(Config.LOCAL_STORE_FILE):
            raise FileNotFoundError(f"Local store file not found: {Config.LOCAL_STORE_FILE}")
        with open(Config.LOCAL_STORE_FILE, "r", encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError as e:
        logger.error(f"{e}")
        console.print(f"[yellow][WARNING][/yellow] {e}")
        return {}
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse local store file: {e}")
        console.print(f"[red][ERROR][/red] Failed to parse local store file: {e}")
        return {}
    except Exception as e:
        logger.error(f"Unexpected error loading local store: {e}")
        console.print(f"[red][ERROR][/red] Unexpected error: {e}")
        return {}

def get_default_account() -> str:
    """
    Retrieve the default account address from the local store.
    """
    try:
        store = load_local_store()
        default_account = store.get("default_account")
        if not default_account:
            raise ValueError("No default account configured in the local store.")
        return default_account
    except ValueError as e:
        logger.warning(f"{e}")
        console.print(f"[yellow][WARNING][/yellow] {e}")
        return ""

def run_goal_command(command: list):
    """
    Execute a 'goal' CLI command.
    """
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        logger.info(f"Command succeeded: {' '.join(command)}")
        return result.stdout
    except subprocess.CalledProcessError as e:
        error_output = e.stderr.strip() if e.stderr else str(e)
        logger.error(f"Command failed: {' '.join(command)}\nError: {error_output}")
        console.print(f"[red][ERROR][/red] Command failed: {error_output}")
        raise
    except FileNotFoundError:
        logger.critical(f"'goal' CLI tool not found. Ensure it is installed and accessible.")
        console.print("[red][CRITICAL][/red] 'goal' CLI tool not found.")
        exit(1)
    except Exception as e:
        logger.error(f"Unexpected error while executing command: {e}")
        console.print(f"[red][ERROR][/red] Unexpected error: {e}")
        raise

###############################################################################
# PARTICIPATION KEY MANAGEMENT
###############################################################################
def generate_participation_key(account_address: str, first_round: int, last_round: int):
    """
    Generate a new participation key for the account.
    """
    command = [
        "goal", "account", "addpartkey",
        "-a", account_address,
        "--roundFirst", str(first_round),
        "--roundLast", str(last_round),
        "-w", Config.WALLET_NAME,
        "--password", Config.WALLET_PASSWORD
    ]
    try:
        run_goal_command(command)
        logger.info(f"Participation key generated for rounds {first_round} to {last_round}.")
    except Exception:
        logger.error(f"Failed to generate participation key for address {account_address}.")

def clear_old_participation_keys(account_address: str):
    """
    Remove old participation keys from the account.
    """
    command = [
        "goal", "account", "clearpartkey",
        "-a", account_address,
        "-w", Config.WALLET_NAME,
        "--password", Config.WALLET_PASSWORD
    ]
    try:
        run_goal_command(command)
        logger.info(f"Old participation keys cleared for account {account_address}.")
    except Exception:
        logger.warning(f"Failed to clear old keys for address {account_address}.")

def renew_participation_key():
    """
    Renew the participation key if necessary.
    """
    try:
        client = get_algod_client()
        account_address = get_default_account()

        if not account_address:
            logger.error("No default account available to renew keys.")
            return

        # Get current blockchain status
        status = client.status()
        current_round = status.get("last-round", 0)
        first_round = current_round + 1
        last_round = first_round + Config.KEY_VALIDITY_DURATION

        logger.info(f"Current Round: {current_round}")
        logger.info(f"Renewing key for rounds {first_round} to {last_round}.")

        # Clear old keys and create a new one
        clear_old_participation_keys(account_address)
        generate_participation_key(account_address, first_round, last_round)
    except Exception as e:
        logger.error(f"An error occurred during participation key renewal: {e}")
        console.print(f"[red][ERROR][/red] {e}")

###############################################################################
# MAIN LOOP
###############################################################################
if __name__ == "__main__":
    logger.info(f"Starting key renewal script at {datetime.now()}")

    while True:
        try:
            renew_participation_key()
        except Exception as e:
            logger.critical(f"Unexpected error: {e}")
            console.print(f"[red][CRITICAL][/red] Unexpected error: {e}")

        logger.info(f"Sleeping for {Config.CHECK_INTERVAL // 3600} hours...")
        time.sleep(Config.CHECK_INTERVAL)