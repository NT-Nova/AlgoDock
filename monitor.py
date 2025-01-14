#!/usr/bin/env python3

import os
import time
from datetime import datetime
from algosdk.v2client import algod
from rich.console import Console
from rich.live import Live
from rich.table import Table
from rich.panel import Panel
from rich.layout import Layout

# Configuration
class Config:
    NODE_DIR = os.getenv("NODE_DIR", "/algod/data")
    ALGOD_ADDRESS = os.getenv("ALGOD_ADDRESS", "http://localhost:4001")
    ALGOD_TOKEN_PATH = os.getenv("ALGOD_TOKEN_PATH", f"{NODE_DIR}/algod.token")
    WALLET_ADDRESS = os.getenv("WALLET_ADDRESS", None)

    @staticmethod
    def get_algod_token():
        if os.getenv("ALGOD_TOKEN"):
            return os.getenv("ALGOD_TOKEN")
        if os.path.exists(Config.ALGOD_TOKEN_PATH):
            with open(Config.ALGOD_TOKEN_PATH, "r") as file:
                return file.read().strip()
        raise FileNotFoundError("Algod token not found in environment or token file.")

# Helpers
def get_algod_client():
    try:
        return algod.AlgodClient(Config.get_algod_token(), Config.ALGOD_ADDRESS)
    except Exception as e:
        raise RuntimeError(f"Failed to initialize Algod client: {e}")

def fetch_node_status(client):
    try:
        return client.status()
    except Exception as e:
        raise RuntimeError(f"Failed to fetch node status: {e}")

def fetch_account_info(client, wallet_address):
    try:
        return client.account_info(wallet_address)
    except Exception as e:
        raise RuntimeError(f"Failed to fetch account info: {e}")

# Dashboard Sections
def create_node_status_table(status):
    table = Table(title="Node Status", box="SIMPLE")
    table.add_column("Metric", style="bold blue", justify="left")
    table.add_column("Value", style="bold green", justify="right")
    table.add_row("Last Round", str(status.get("last-round", "N/A")))
    table.add_row("Time Since Last Round", f"{status.get('time-since-last-round', 'N/A')} ms")
    table.add_row("Catchup Time", f"{status.get('catchup-time', 'N/A')} ms")
    table.add_row("Sync Status", "Synchronized" if status.get("catchup-time", 0) == 0 else "Catching Up")
    return table

def create_wallet_status_table(account_info):
    balance = account_info.get("amount", 0) / 1_000_000  # Convert microAlgos to Algos
    rewards = account_info.get("rewards", 0) / 1_000_000
    table = Table(title="Wallet Status", box="SIMPLE")
    table.add_column("Metric", style="bold blue", justify="left")
    table.add_column("Value", style="bold green", justify="right")
    table.add_row("Wallet Address", Config.WALLET_ADDRESS or "N/A")
    table.add_row("Balance (Algos)", f"{balance:.6f}")
    table.add_row("Rewards (Algos)", f"{rewards:.6f}")
    return table

def create_block_metrics_table(client, last_round):
    try:
        block_info = client.block_info(last_round)
        transactions = block_info.get("block", {}).get("txns", [])
        tx_count = len(transactions)
        table = Table(title=f"Block {last_round} Metrics", box="SIMPLE")
        table.add_column("Metric", style="bold blue", justify="left")
        table.add_column("Value", style="bold green", justify="right")
        table.add_row("Block Creator", block_info.get("block", {}).get("proposer", "N/A"))
        table.add_row("Transactions in Block", str(tx_count))
        return table
    except Exception as e:
        table = Table(title=f"Block {last_round} Metrics", box="SIMPLE")
        table.add_column("Error", style="bold red")
        table.add_row(str(e))
        return table

# Real-Time Dashboard
def render_dashboard():
    layout = Layout()
    layout.split_column(
        Layout(name="node_status", size=10),
        Layout(name="wallet_status", size=10),
        Layout(name="block_metrics", size=10),
    )

    client = get_algod_client()

    with Live(layout, refresh_per_second=1):
        while True:
            try:
                # Fetch Node and Wallet Data
                node_status = fetch_node_status(client)
                account_info = fetch_account_info(client, Config.WALLET_ADDRESS) if Config.WALLET_ADDRESS else None
                last_round = node_status.get("last-round", 0)

                # Update Layout Sections
                layout["node_status"].update(Panel(create_node_status_table(node_status), title="Node Status"))
                if account_info:
                    layout["wallet_status"].update(Panel(create_wallet_status_table(account_info), title="Wallet Status"))
                layout["block_metrics"].update(Panel(create_block_metrics_table(client, last_round), title="Block Metrics"))

            except Exception as e:
                layout["node_status"].update(Panel(f"[red]Error: {e}[/red]", title="Error"))
                layout["wallet_status"].update(Panel(f"[red]Error: {e}[/red]", title="Error"))
                layout["block_metrics"].update(Panel(f"[red]Error: {e}[/red]", title="Error"))
            
            time.sleep(1)  # Update every second

if __name__ == "__main__":
    console = Console()
    try:
        console.log("[green][INFO][/green] Starting Algorand Node Monitor...")
        render_dashboard()
    except Exception as e:
        console.log(f"[red][CRITICAL][/red] {e}")