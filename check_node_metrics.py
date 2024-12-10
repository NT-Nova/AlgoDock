import os
import re
import logging
from algosdk.v2client import algod
from algosdk import mnemonic

# Configuration via environment variables for flexibility
ALGOD_ADDRESS = os.getenv("ALGOD_ADDRESS", "http://localhost:4001")
ALGOD_TOKEN = os.getenv("ALGOD_TOKEN", "your_algod_token_here")
ACCOUNT_MNEMONIC = os.getenv("ACCOUNT_MNEMONIC", "your_25_word_mnemonic_here")

# Path to node's log file (modify as needed or use the default environment variable)
NODE_LOG_PATH = os.getenv("NODE_LOG_PATH", "/node/data/node.log")

# Regex pattern used to detect block proposals in the log.
# Adjust this based on your node.log patterns.
PROPOSAL_PATTERN = os.getenv("PROPOSAL_PATTERN", r"Proposing block for round \d+")

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def get_algod_client() -> algod.AlgodClient:
    """
    Initialize and return an AlgodClient instance.

    Returns:
        algod.AlgodClient: A client for interacting with the Algorand node.
    """
    try:
        client = algod.AlgodClient(ALGOD_TOKEN, ALGOD_ADDRESS)
        logger.info(f"[INFO] Algorand client initialized.")
        return client
    except Exception as e:
        logger.error(f"[ERROR] Failed to initialize Algod client: {e}")
        raise

def get_account_address() -> str:
    """
    Convert the mnemonic to an Algorand address.

    Returns:
        str: The public address of the account.
    """
    try:
        account_address = mnemonic.to_public_key(ACCOUNT_MNEMONIC)
        logger.info(f"[INFO] Account address retrieved: {account_address}")
        return account_address
    except Exception as e:
        logger.error(f"[ERROR] Failed to retrieve account address from mnemonic: {e}")
        raise

def check_node_sync_status(client: algod.AlgodClient):
    """
    Print the node's synchronization status.
    
    If the node is fully synced, 'catchup-time' or 'time-since-last-round' should be near zero.
    """
    try:
        status = client.status()
        current_round = status.get("last-round", "N/A")
        catchup_time = status.get("catchup-time", None)
        sync_time = status.get("time-since-last-round", None)

        logger.info(f"[INFO] Node Status:")
        logger.info(f" - Last Round: {current_round}")

        if catchup_time is not None:
            if catchup_time == 0:
                logger.info(" - Sync Status: The node is fully synchronized.")
            else:
                logger.info(f" - Sync Status: Node is catching up, estimated time: {catchup_time}s")
        elif sync_time is not None:
            if sync_time == 0:
                logger.info(" - Sync Status: The node is fully synchronized.")
            else:
                logger.info(" - Sync Status: The node is not fully synchronized yet.")
        else:
            logger.warning(" - Sync Status: Unable to determine sync status.")
    except Exception as e:
        logger.error(f"[ERROR] Unable to get node status: {e}")

def print_account_info(client: algod.AlgodClient, account_address: str):
    """
    Print the account's balance and rewards.
    
    Rewards represent the passive accrual of Algos due to holding and participating.
    """
    try:
        account_info = client.account_info(account_address)
        balance = account_info.get("amount", 0)
        rewards = account_info.get("rewards", 0)

        algo_balance = balance / 1_000_000
        algo_rewards = rewards / 1_000_000

        logger.info(f"[INFO] Account Info:")
        logger.info(f" - Address: {account_address}")
        logger.info(f" - Balance: {algo_balance} Algos")
        logger.info(f" - Rewards Earned: {algo_rewards} Algos")
    except Exception as e:
        logger.error(f"[ERROR] Unable to get account info: {e}")

def print_node_telemetry(client: algod.AlgodClient):
    """
    Print additional telemetry info about the node:
    - Genesis ID and Hash
    - Node version/build info
    - Ledger supply (online money, total money)
    - Suggested transaction params (consensus version, fee)
    
    This provides a snapshot of the node's environment and operating parameters.
    """
    try:
        version_data = client.versions()
        genesis_data = client.genesis()
        ledger_supply = client.ledger_supply()
        params = client.suggested_params()

        build_version = version_data.get('build', 'N/A')
        genesis_id = genesis_data.get('genesis_id', 'N/A')
        genesis_hash = genesis_data.get('genesis_hash_b64', 'N/A')

        online_money = ledger_supply.get('online-money', 'N/A')
        total_money = ledger_supply.get('total-money', 'N/A')

        logger.info(f"[INFO] Node Telemetry:")
        logger.info(f" - Genesis ID: {genesis_id}")
        logger.info(f" - Genesis Hash: {genesis_hash}")
        logger.info(f" - Node Version (Build): {build_version}")
        logger.info(f" - Online Money: {online_money} microAlgos")
        logger.info(f" - Total Money: {total_money} microAlgos")

        if params:
            logger.info(f" - Suggested Params:")
            logger.info(f"    * Consensus Version: {params.consensus_version}")
            logger.info(f"    * Fee (per byte): {params.fee} microAlgos")
            logger.info(f"    * Genesis ID: {params.genesis_id}")
        else:
            logger.warning(" - Suggested Params: N/A")
    except Exception as e:
        logger.error(f"[ERROR] Unable to get telemetry data: {e}")

def count_proposed_blocks(log_path, proposal_pattern):
    """
    Attempt to identify how many blocks this node proposed by analyzing the node log.
    
    Limitations:
    - Algorand does not explicitly record which node proposed a block on-chain.
    - We rely on log patterns that may indicate a proposal event.
    - Adjust 'proposal_pattern' as needed to match the node's actual log messages.
    
    Returns:
        int: The approximate count of proposed blocks.
    """
    if not os.path.exists(log_path):
        logger.warning(f"[WARNING] Log file not found at {log_path}, cannot determine proposed blocks.")
        return 0

    proposed_count = 0
    pattern = re.compile(proposal_pattern, re.IGNORECASE)

    try:
        with open(log_path, 'r', encoding='utf-8', errors='replace') as log_file:
            for line in log_file:
                if pattern.search(line):
                    proposed_count += 1
    except Exception as e:
        logger.error(f"[ERROR] An error occurred reading the log file: {e}")

    return proposed_count

if __name__ == "__main__":
    logger.info("[INFO] Gathering node metrics...")
    client = get_algod_client()
    account_address = get_account_address()

    # Check node sync status
    check_node_sync_status(client)

    # Print account balances and rewards
    print_account_info(client, account_address)

    # Print additional telemetry info
    print_node_telemetry(client)

    # Attempt to count proposed (minted) blocks from logs
    blocks_proposed = count_proposed_blocks(NODE_LOG_PATH, PROPOSAL_PATTERN)
    logger.info(f"[INFO] Block Proposals (Heuristic):")
    logger.info(f" - Blocks proposed by this node (approx): {blocks_proposed}")

    logger.info("[INFO] Finished gathering node metrics.")
    logger.info("[NOTE] Block proposals are determined by log heuristics and may not be accurate.")
    logger.info("[NOTE] For more detailed insights, consider external tools or telemetry services.")