#!/usr/bin/env python3
import os
import re
import json
import logging
import subprocess
from typing import List, Dict, Optional

from rich.console import Console
from rich.prompt import Prompt
from rich.table import Table

from algosdk.v2client import algod
from algosdk import mnemonic, account


###############################################################################
# CONFIGURATION & SETUP
###############################################################################
class Config:
    """
    Configuration values for environment and node operation.
    """
    NODE_DIR = os.getenv("NODE_DIR", "/algod/data")
    ALGOD_ADDRESS = os.getenv("ALGOD_ADDRESS", "http://localhost:4001")
    ALGOD_TOKEN_PATH = os.getenv("ALGOD_TOKEN_PATH", f"{NODE_DIR}/algod.token")
    ALGOD_TOKEN = os.getenv("ALGOD_TOKEN", None)

    # If no token is set, try reading from file
    if not ALGOD_TOKEN and os.path.exists(ALGOD_TOKEN_PATH):
        with open(ALGOD_TOKEN_PATH, "r") as f:
            ALGOD_TOKEN = f.read().strip()
    if not ALGOD_TOKEN:
        ALGOD_TOKEN = "your_algod_token_here"

    # Participation key config
    PARTKEY_FIRST_ROUND = 1
    PARTKEY_LAST_ROUND = 3_000_000
    KEY_DILUTION = 1_732

    # Node log path
    NODE_LOG_PATH = os.path.join(NODE_DIR, "node.log")

    # Regex for scanning proposed blocks in node.log
    PROPOSAL_PATTERN = os.getenv("PROPOSAL_PATTERN", r"Proposing block for round \d+")

    # Logging
    LOG_LEVEL = logging.INFO

    # Local store path
    LOCAL_STORE_FILE = os.path.join(NODE_DIR, "accounts.json")


###############################################################################
# LOGGING
###############################################################################
logging.basicConfig(level=Config.LOG_LEVEL)
logger = logging.getLogger(__name__)
console = Console()


###############################################################################
# LOCAL STORE & ACCOUNT UTILS
###############################################################################
def load_local_store() -> Dict:
    """
    Loads local JSON store with structure:
    {
      "default_account": "FULL_ADDRESS",
      "accounts": {
         "FULL_ADDRESS": {"name": "..."}
      }
    }
    """
    path = Config.LOCAL_STORE_FILE
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        logger.exception("Failed to load local store JSON:")
        return {}


def save_local_store(data: Dict):
    """
    Saves the local store back to disk.
    """
    path = Config.LOCAL_STORE_FILE
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception:
        logger.exception("Failed to save local store JSON:")


def get_default_account() -> Optional[str]:
    """Retrieves the default full address from the store."""
    return load_local_store().get("default_account")


def set_default_account(full_address: str):
    """Sets or updates the default account to a full address."""
    store = load_local_store()
    store["default_account"] = full_address
    if "accounts" not in store:
        store["accounts"] = {}
    if full_address not in store["accounts"]:
        store["accounts"][full_address] = {"name": ""}
    save_local_store(store)


def set_account_name(full_address: str, name: str):
    """Stores a user-friendly name for an address in the local store."""
    store = load_local_store()
    if "accounts" not in store:
        store["accounts"] = {}
    if full_address not in store["accounts"]:
        store["accounts"][full_address] = {}
    store["accounts"][full_address]["name"] = name
    save_local_store(store)


def get_account_name(full_address: str) -> str:
    """Retrieve the stored name for a full address, if any."""
    store = load_local_store()
    return store.get("accounts", {}).get(full_address, {}).get("name", "")


###############################################################################
# NODE OPERATIONS
###############################################################################
class NodeOperations:
    """
    Manages node interactions using the detailed partkeyinfo output.
    All values, including the full 'Parent address', are retrieved via
    the goal account partkeyinfo command.
    """
    def __init__(self, config: Config):
        self.config = config
        self._algod_client = None

        # parted_info dict: Participation ID -> dict of fields
        self.parted_info: Dict[str, Dict[str, str]] = {}

    def get_algod_client(self) -> algod.AlgodClient:
        """Returns a cached algod client."""
        if self._algod_client is None:
            try:
                self._algod_client = algod.AlgodClient(
                    self.config.ALGOD_TOKEN,
                    self.config.ALGOD_ADDRESS
                )
                console.log("[green][INFO][/green] Algorand client initialized.")
            except Exception as e:
                logger.exception("Failed to initialize Algod client:")
                console.log(f"[red][ERROR][/red] {e}")
                raise
        return self._algod_client

    def display_sync_status(self):
        """Show node sync status in a Rich table."""
        try:
            status = self.get_algod_client().status()
            table = Table(title="Node Sync Status")
            table.add_column("Metric", justify="left")
            table.add_column("Value", justify="right")

            table.add_row("Last Committed Block", str(status.get("last-round", "N/A")))
            table.add_row("Time Since Last Block", str(status.get("time-since-last-round", "N/A")))
            table.add_row("Sync Time Remaining", str(status.get("catchup-time", "N/A")))
            console.print(table)

            if status.get("catchup-time", None) == 0:
                console.log("[green][INFO][/green] Node is fully synchronized.")
            else:
                console.log("[yellow][INFO][/yellow] Node is still catching up.")
        except Exception as e:
            logger.exception("Unable to fetch node status:")
            console.log(f"[red][ERROR][/red] {e}")

    def show_partkey_info_menu(self):
        """
        Show each detailed partkeyinfo block in a separate Rich table.
        """
        self._parse_partkeyinfo()

        if not self.parted_info:
            console.log("[yellow][WARNING][/yellow] No participation keys found in partkeyinfo.")
            return

        for pid, fields in self.parted_info.items():
            t = Table(title=f"Detailed PartKey Info for Participation ID: {pid}")
            t.add_column("Field", justify="left")
            t.add_column("Value", justify="left")
            for k in sorted(fields.keys()):
                t.add_row(k, fields[k])
            console.print(t)

    def merge_partkeys_and_show(self):
        """
        Retrieves detailed partkeyinfo values (which include the full 'Parent address')
        and displays them in a merged table. This table now uses only the detailed info.
        """
        self._parse_partkeyinfo()

        if not self.parted_info:
            console.log("[yellow][WARNING][/yellow] No participation keys found in partkeyinfo.")
            return

        # Fields to display in addition to Participation ID and Parent address
        extra_fields = [
            "Effective first round",
            "Effective last round",
            "First round",
            "Key dilution",
            "Last block proposal round",
            "Last round",
            "Last vote round",
            "Selection key",
            "Voting key",
            "State proof key"
        ]

        t = Table(title="Merged Detailed Participation Keys")
        t.add_column("Participation ID", justify="center")
        t.add_column("Parent Address (Full)", justify="left")
        t.add_column("Wallet Name", justify="center")
        for ef in extra_fields:
            t.add_column(ef, justify="center")

        for pid, info in self.parted_info.items():
            parent_addr = info.get("Parent address", "")
            wallet_name = get_account_name(parent_addr)
            row_values = [
                pid,
                parent_addr,
                wallet_name
            ]
            for ef in extra_fields:
                row_values.append(info.get(ef, ""))
            t.add_row(*row_values)

            # If the default account is set but appears to be truncated, upgrade it
            default_acct = get_default_account()
            if default_acct and "..." in default_acct and default_acct != parent_addr:
                console.log(f"[blue][INFO][/blue] Upgrading default from {default_acct} to {parent_addr}")
                set_default_account(parent_addr)

        console.print(t)

    def _parse_partkeyinfo(self):
        """
        Runs `goal account partkeyinfo` and stores the detailed fields in self.parted_info.
        Expected output format (fields and order may vary):
          Field                     : Value
          ----------------------------------------
          Effective first round     : N/A
          Effective last round      : N/A
          First round               : 1
          Key dilution              : 1732
          Last block proposal round : N/A
          Last round                : 3000000
          Last vote round           : N/A
          Parent address            : DYE7E2VABLVDUE4TIL6MK2M2H66SRTUNRPDJA6PLUQ4FHC6RQGOWQMJUUA
          Participation ID          : ZJFZ6XIKQL5JYSOXSP5OE4BTA5XCT2YIZMTR5CHM7NHYBOXJTCAA
          Selection key             : xIqFKsLWPTRaFMVcFQl7q9pisndkESue/bQ/rhgdw8Q=
          State proof key           : EYSgQO+hmrByjK7luH8E4u8ntLLvB+qOyN9IpuakOEK6azAYpvcupNUiBSLX4yVMIK/M1oJna5LnJHGPj0K7eQ==
          Voting key                : /6rxPOLvdv76JBttaWUkdCFYmOTY/noMMsky2TVE8YI=
        """
        self.parted_info.clear()
        cmd = ["goal", "account", "partkeyinfo", "-d", self.config.NODE_DIR]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode == 0:
                blocks = self._parse_partkeyinfo_output(r.stdout)
                for b in blocks:
                    pid = b.get("Participation ID", "")
                    if pid:
                        self.parted_info[pid] = b
            else:
                console.log(f"[red][ERROR][/red] partkeyinfo error: {r.stderr}")
        except Exception as e:
            logger.exception("Failed to run partkeyinfo:")
            console.log(f"[red][ERROR][/red] {e}")

    @staticmethod
    def _parse_partkeyinfo_output(stdout: str) -> List[Dict[str, str]]:
        """
        Splits the partkeyinfo output into blocks, each with its fields.
        """
        lines = stdout.splitlines()
        blocks = []
        current = {}
        for line in lines:
            if not line.strip():
                if current:
                    blocks.append(current)
                    current = {}
                continue
            if ":" in line:
                parts = line.split(":", 1)
                k = parts[0].strip()
                v = parts[1].strip()
                current[k] = v
        if current:
            blocks.append(current)
        return blocks

    def create_participation_key(self, full_addr: Optional[str]):
        """Creates a new participation key using the full address."""
        if not full_addr:
            console.log("[yellow][WARNING][/yellow] No account address provided.")
            return
        cmd = [
            "goal", "account", "addpartkey",
            "-a", full_addr,
            "--roundFirstValid", str(self.config.PARTKEY_FIRST_ROUND),
            "--roundLastValid", str(self.config.PARTKEY_LAST_ROUND),
            "--keyDilution", str(self.config.KEY_DILUTION),
            "-d", self.config.NODE_DIR
        ]
        try:
            console.log(f"[blue][INFO][/blue] Creating participation key for: {full_addr}")
            subprocess.run(cmd, check=True)
            console.log("[green][INFO][/green] Participation key created.")
        except subprocess.CalledProcessError as e:
            logger.exception("Failed to create participation key:")
            console.log(f"[red][ERROR][/red] {e}")

    def remove_participation_key(self):
        """
        Removes a key by the user-provided full Parent address or Participation ID.
        """
        self.merge_partkeys_and_show()  # ensure parted_info is up to date

        user_in = Prompt.ask("Enter the [bold]full parent address or Participation ID[/bold] to remove")
        parted_to_remove = None
        for pid, info_block in self.parted_info.items():
            if pid == user_in or info_block.get("Parent address", "") == user_in:
                parted_to_remove = pid
                break

        if not parted_to_remove:
            console.log(f"[red][ERROR][/red] No matching Participation ID or address found: {user_in}")
            return

        cmd = ["goal", "account", "deletepartkey", "--partkeyid", parted_to_remove, "-d", self.config.NODE_DIR]
        try:
            console.log(f"[blue][INFO][/blue] Removing participation key with ID: {parted_to_remove}")
            subprocess.run(cmd, check=True)
            console.log("[green][INFO][/green] Participation key removed successfully.")
            self.merge_partkeys_and_show()
        except subprocess.CalledProcessError as e:
            logger.exception("Failed to remove participation key:")
            console.log(f"[red][ERROR][/red] {e}")

    def count_proposed_blocks(self) -> int:
        """Counts how many blocks were proposed by scanning node.log."""
        if not os.path.exists(self.config.NODE_LOG_PATH):
            console.log("[yellow][WARNING][/yellow] Log file not found.")
            return 0
        pat = re.compile(self.config.PROPOSAL_PATTERN, re.IGNORECASE)
        c = 0
        try:
            with open(self.config.NODE_LOG_PATH, "r", encoding="utf-8", errors="replace") as lf:
                c = sum(1 for line in lf if pat.search(line))
            console.log(f"[green][INFO][/green] Blocks Proposed: {c}")
        except Exception as e:
            logger.exception("Error reading node.log:")
            console.log(f"[red][ERROR][/red] {e}")
        return c


###############################################################################
# WALLET OPERATIONS
###############################################################################
class WalletOperations:
    """
    For importing, generating, or choosing full addresses as default accounts.
    """
    @staticmethod
    def import_wallet() -> str:
        phrase = Prompt.ask("Enter your 25-word mnemonic")
        full_addr = mnemonic.to_public_key(phrase)
        console.log(f"[green][INFO][/green] Wallet imported. Address: {full_addr}")
        nm = Prompt.ask("Enter a name for this wallet (optional)", default="")
        set_account_name(full_addr, nm)
        set_default_account(full_addr)
        return full_addr

    @staticmethod
    def generate_new_wallet() -> str:
        pkey, addr = account.generate_account()
        phrase = mnemonic.from_private_key(pkey)
        console.log(f"[green][INFO][/green] New wallet created. Address: {addr}")
        console.log("[bold red]Save this mnemonic securely:[/bold red]")
        console.print(f"[bold]{phrase}[/bold]")
        nm = Prompt.ask("Enter a name for this wallet (optional)", default="")
        set_account_name(addr, nm)
        set_default_account(addr)
        return addr

    @staticmethod
    def use_existing_account() -> str:
        addr = Prompt.ask("Enter the existing [bold]full[/bold] account address")
        console.log(f"[green][INFO][/green] Using address: {addr}")
        nm = Prompt.ask("Enter a name for this wallet (optional)", default="")
        set_account_name(addr, nm)
        set_default_account(addr)
        return addr

    @staticmethod
    def display_account_info(client: algod.AlgodClient, full_addr: Optional[str]):
        if not full_addr:
            console.log("[yellow][WARNING][/yellow] No account address set.")
            return
        try:
            info = client.account_info(full_addr)
            balance = info.get("amount", 0) / 1_000_000
            rewards = info.get("rewards", 0) / 1_000_000

            t = Table(title="Account Information")
            t.add_column("Address", justify="center")
            t.add_column("Wallet Name", justify="center")
            t.add_column("Balance (Algos)", justify="right")
            t.add_column("Rewards (Algos)", justify="right")

            wname = get_account_name(full_addr)
            t.add_row(full_addr, wname, f"{balance:.6f}", f"{rewards:.6f}")
            console.print(t)
        except Exception as e:
            logger.exception("Unable to retrieve account info:")
            console.log(f"[red][ERROR][/red] {e}")


###############################################################################
# EXTENDED COMMANDS MENU
###############################################################################
def extended_commands_menu(node_ops: NodeOperations):
    """
    Hardcoded commands for 'goal account ...', always using the full address.
    """
    while True:
        console.print("\n[bold magenta]Extended Commands Menu[/bold magenta]")
        console.print("1.  Show Detailed PartKey Info (all fields)")
        console.print("2.  Account assetdetails")
        console.print("3.  Account balance")
        console.print("4.  Account changeonlinestatus")
        console.print("5.  Account delete")
        console.print("6.  Account dump")
        console.print("7.  Account export")
        console.print("8.  Account import")
        console.print("9.  Account importrootkey")
        console.print("10. Account info")
        console.print("11. Account installpartkey")
        console.print("12. Account list")
        console.print("13. Account marknonparticipating")
        console.print("14. Account multisig")
        console.print("15. Account new")
        console.print("16. Account rename")
        console.print("17. Account renewallpartkeys")
        console.print("18. Account renewpartkey")
        console.print("19. Account rewards")
        console.print("20. Return to Main Menu")

        choice = Prompt.ask("Choose an option", choices=[str(i) for i in range(1, 21)], default="20")
        full_addr = get_default_account()

        if choice == "1":
            node_ops.show_partkey_info_menu()

        elif choice == "2":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "assetdetails", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "3":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "balance", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "4":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "changeonlinestatus", "-a", full_addr, "--status", "online", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "5":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "delete", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "6":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "dump", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "7":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "export", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "8":
            cmd = ["goal", "account", "import", "-i", "/tmp/exported-account.key", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "9":
            cmd = ["goal", "account", "importrootkey", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "10":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "info", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "11":
            cmd = ["goal", "account", "installpartkey", "--partkey", "/tmp/some_partkey.key", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "12":
            cmd = ["goal", "account", "list", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "13":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "marknonparticipating", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "14":
            cmd = ["goal", "account", "multisig", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "15":
            cmd = ["goal", "account", "new", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "16":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "rename", "-a", full_addr, "--name", "NewDefaultName", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "17":
            cmd = ["goal", "account", "renewallpartkeys", "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "18":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "renewpartkey", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "19":
            if not full_addr:
                console.log("[red][ERROR][/red] No default address set.")
                continue
            cmd = ["goal", "account", "rewards", "-a", full_addr, "-d", node_ops.config.NODE_DIR]
            run_goal_command(cmd)

        elif choice == "20":
            console.log("[green][INFO][/green] Returning to Main Menu...")
            break
        else:
            console.log("[red][ERROR][/red] Invalid choice. Please try again.")


def run_goal_command(cmd: list):
    """
    Generic runner for 'goal account' subcommands.
    """
    console.log(f"[blue][INFO][/blue] Running command: {' '.join(cmd)}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        console.print(r.stdout, highlight=True)
    else:
        console.log(f"[red][ERROR][/red] Command failed: {r.stderr}")


###############################################################################
# MAIN MENU & SCRIPT ENTRY
###############################################################################
def show_wallet_list(node_ops: NodeOperations):
    """
    Displays a list of wallets along with their balances and names.
    """
    console.print("\n[bold cyan]Wallet List[/bold cyan]")
    store = load_local_store()
    accounts = store.get("accounts", {})

    if not accounts:
        console.log("[yellow][WARNING][/yellow] No wallets found in the local store.")
        return

    client = node_ops.get_algod_client()

    # Create a table to display wallet information
    table = Table(title="Wallets", show_lines=True)
    table.add_column("Wallet Address", justify="left")
    table.add_column("Wallet Name", justify="center")
    table.add_column("Balance (Algos)", justify="right")

    for address, info in accounts.items():
        name = info.get("name", "")
        try:
            account_info = client.account_info(address)
            balance = account_info.get("amount", 0) / 1_000_000  # Convert microAlgos to Algos
        except Exception as e:
            console.log(f"[red][ERROR][/red] Unable to fetch balance for {address}: {e}")
            balance = "N/A"

        table.add_row(address, name, f"{balance:.6f}" if isinstance(balance, float) else balance)

    console.print(table)
    
def wallet_submenu(node_ops: NodeOperations):
    """
    Wallet Submenu: Handles importing, generating wallets, and displaying wallet lists.
    """
    while True:
        console.print("\n[bold cyan]Wallet[/bold cyan]")
        console.print("1. Import Wallet")
        console.print("2. Generate New Wallet")
        console.print("3. Show Wallet List")
        console.print("4. Return to Main Menu")

        choice = Prompt.ask("Choose an option", choices=["1", "2", "3", "4"], default="4")

        if choice == "1":
            WalletOperations.import_wallet()

        elif choice == "2":
            WalletOperations.generate_new_wallet()

        elif choice == "3":
            show_wallet_list(node_ops)

        elif choice == "4":
            console.log("[green][INFO][/green] Returning to Main Menu...")
            break

        else:
            console.log("[red][ERROR][/red] Invalid choice. Please try again.")

def participation_key_submenu(node_ops: NodeOperations):
    """
    Participation Key Submenu: Handles creating, removing, and using participation keys.
    """
    while True:
        console.print("\n[bold cyan]Participation Keys[/bold cyan]")
        console.print("1. Use Existing Account (Full Address)")
        console.print("2. Generate Participation Key")
        console.print("3. Remove Participation Key")
        console.print("4. Return to Main Menu")

        choice = Prompt.ask("Choose an option", choices=["1", "2", "3", "4"], default="4")

        if choice == "1":
            WalletOperations.use_existing_account()

        elif choice == "2":
            account_address = get_default_account()
            if not account_address:
                console.log("[red][ERROR][/red] No default account set.")
            else:
                node_ops.create_participation_key(account_address)

        elif choice == "3":
            node_ops.remove_participation_key()

        elif choice == "4":
            console.log("[green][INFO][/green] Returning to Main Menu...")
            break

        else:
            console.log("[red][ERROR][/red] Invalid choice. Please try again.")


def main_menu(node_ops: NodeOperations):
    """
    Main Menu. We always use the full address for default accounts.
    """
    while True:
        console.print("\n[bold blue]Main Menu[/bold blue]")
        console.print("1. Wallet")
        console.print("2. Participation Keys")
        console.print("3. Check Node Sync Status")
        console.print("4. Display Account Info")
        console.print("5. Display Merged Detailed PartKeys")
        console.print("6. Count Proposed Blocks")
        console.print("7. Show Detailed PartKey Info")
        console.print("8. Extended Commands Menu")
        console.print("9. Exit")

        choice = Prompt.ask("Choose an option", choices=[str(i) for i in range(1, 10)], default="9")

        if choice == "1":
            wallet_submenu(node_ops)

        elif choice == "2":
            participation_key_submenu(node_ops)

        elif choice == "3":
            node_ops.display_sync_status()

        elif choice == "4":
            account_address = get_default_account()
            WalletOperations.display_account_info(node_ops.get_algod_client(), account_address)

        elif choice == "5":
            node_ops.merge_partkeys_and_show()

        elif choice == "6":
            node_ops.count_proposed_blocks()

        elif choice == "7":
            node_ops.show_partkey_info_menu()

        elif choice == "8":
            extended_commands_menu(node_ops)

        elif choice == "9":
            console.log("[green][INFO][/green] Exiting...")
            break

        else:
            console.log("[red][ERROR][/red] Invalid choice. Please try again.")


def main():
    console.log("[blue][INFO][/blue] Initializing node metrics...")
    cfg = Config()
    node_ops = NodeOperations(cfg)

    # Show default account
    d_acct = get_default_account()
    if d_acct:
        nm = get_account_name(d_acct)
        if nm:
            console.log(f"[green][INFO][/green] Default account loaded: [bold]{d_acct}[/bold] ({nm})")
        else:
            console.log(f"[green][INFO][/green] Default account loaded: [bold]{d_acct}[/bold]")
    else:
        console.log("[yellow][WARNING][/yellow] No default account configured.")

    # Show node sync
    node_ops.display_sync_status()

    # Display merged detailed participation keys (this will also fix truncated defaults)
    node_ops.merge_partkeys_and_show()

    main_menu(node_ops)


if __name__ == "__main__":
    main()