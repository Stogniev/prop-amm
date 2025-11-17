# Off-Chain Price Prediction Module

This directory hosts a Python implementation of the off-chain automation layer that keeps the PropAMM curves aligned with external markets. The design borrows ideas from the [Cryptocurrency-Price-Prediction](https://github.com/Dat-TG/Cryptocurrency-Price-Prediction) project while adapting the code to feed curve updates into the Solidity contract introduced in this repository.

The workflow is broken into three primary components:

1. **Data & Feature Engineering** – `prediction/data.py` handles ingestion of OHLCV market data, performs smoothing and computes derived indicators similar to the feature pipeline in the referenced repository.
2. **Model Training & Inference** – `prediction/model.py` implements a `CryptoPricePredictor` that can train an ensemble model on the engineered features and generate rolling price forecasts.
3. **Signal Translation & Execution** – `prediction/signal_engine.py` translates price/volatility signals into AMM parameter adjustments, while `update_bot.py` demonstrates how to submit these updates to the on-chain contract.

To install dependencies for the off-chain module run:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r offchain/requirements.txt
```

You can then train a model and broadcast curve updates with:

```bash
python offchain/update_bot.py \
    --pair-id 0x... \
    --rpc-url https://your.node \
    --private-key 0xYOUR_KEY \
    --data data/BTCUSDT.csv
```

> **Note**: The script assumes a JSON-RPC endpoint compatible with `web3.py` and that the calling key is authorized as the market maker in the PropAMM contract. The default model is intentionally lightweight so it can be run frequently by an automated strategy; feel free to swap in more advanced architectures (e.g., LSTM/GRU) following the API exposed by `CryptoPricePredictor`.

## Unified AMM + Prediction demo

To see the full loop in action without hitting a live RPC endpoint, run the self-contained demo:

```bash
python offchain/demo_unified.py
```

The script synthesizes OHLCV data, trains the `CryptoPricePredictor`, derives a `CurveUpdatePlan` via `SignalEngine`, and prints the encoded transaction payloads (`updateCurveParams`, `setSpread`, and `rebalanceLiquidity` when applicable) that would be sent to `PropAMM`.
