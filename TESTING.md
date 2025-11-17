# Testing Guide

This repository has two primary test flows:

1. **On-chain contract tests (Foundry)** – exercises the PropAMM Solidity contracts.
2. **Off-chain prediction + AMM demo** – runs the unified Python simulation that stitches the predictor and transaction encoding together.

## Prerequisites

- **On-chain tests**: [Foundry](https://book.getfoundry.sh/getting-started/installation) installed (`foundryup`), plus standard build toolchain (Rust/curl) used by Foundry.
- **Off-chain demo**: Python 3.10+ with `venv`; dependencies listed in `offchain/requirements.txt`.

## Running on-chain tests

1. Install dependencies:
   ```bash
   forge install
   ```
2. Run the full Foundry suite:
   ```bash
   forge test
   ```
3. For verbose traces:
   ```bash
   forge test -vvv
   ```
4. Optional: test against a local node (Anvil):
   ```bash
   anvil
   # in a second terminal
   forge test --fork-url http://localhost:8545
   ```

## Running the off-chain unified demo

This demo exercises the price predictor and curve update logic end-to-end without needing a live RPC endpoint.

1. Create and activate a virtual environment:
   ```bash
   python -m venv .venv
   source .venv/bin/activate
   ```
2. Install Python dependencies:
   ```bash
   pip install -r offchain/requirements.txt
   ```
3. Execute the demo:
   ```bash
   python offchain/demo_unified.py
   ```

The script generates synthetic OHLCV data, trains the `CryptoPricePredictor`, produces a `CurveUpdatePlan` via the `SignalEngine`, and prints the encoded PropAMM transactions (`updateCurveParams`, `setSpread`, and `rebalanceLiquidity`).
