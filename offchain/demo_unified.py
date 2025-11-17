"""End-to-end demo that links the predictor to PropAMM updates.

The script is self-contained and uses synthetic OHLCV data so it can be run
without external downloads. It trains the predictor, generates a signal,
converts that into curve update instructions, and encodes the transactions
that would be sent on-chain.

Usage:
    python offchain/demo_unified.py
"""

from __future__ import annotations

from dataclasses import asdict
from typing import Iterable

import numpy as np
import pandas as pd
from web3 import Web3

from prediction import CryptoPricePredictor, CurveSnapshot, SignalEngine, prepare_training_frame
from update_bot import PROP_AMM_ABI


def _synthetic_ohlcv(periods: int = 240, *, seed: int = 7) -> pd.DataFrame:
    """Generate a gentle random walk for OHLCV prices."""

    rng = np.random.default_rng(seed)
    timestamps = pd.date_range("2023-01-01", periods=periods, freq="H", tz="UTC")

    drift = 0.0005
    volatility = 0.01
    returns = rng.normal(drift, volatility, size=periods)
    price = 1400 * np.exp(np.cumsum(returns))

    highs = price * (1 + rng.uniform(0, 0.002, size=periods))
    lows = price * (1 - rng.uniform(0, 0.002, size=periods))
    opens = np.concatenate([[price[0]], price[:-1]])
    closes = price
    volume = rng.uniform(800, 1200, size=periods)

    return pd.DataFrame(
        {
            "timestamp": timestamps,
            "open": opens,
            "high": highs,
            "low": lows,
            "close": closes,
            "volume": volume,
        }
    )


def _realized_volatility(closing_prices: Iterable[float]) -> float:
    """Annualized realized volatility approximation using hourly data."""

    series = pd.Series(closing_prices)
    log_returns = np.log(series).diff().dropna()
    return float(log_returns.std() * np.sqrt(24))


def _build_contract() -> tuple[Web3, any]:
    """Return a Web3 shim and contract object for ABI encoding."""

    w3 = Web3()
    dummy_address = Web3.to_checksum_address("0x" + "12" * 20)
    contract = w3.eth.contract(address=dummy_address, abi=PROP_AMM_ABI)
    return w3, contract


def _encode_actions(contract, pair_id: bytes, plan) -> dict:
    update_curve = contract.get_function_by_name("updateCurveParams")(
        pair_id, plan.mult_x, plan.mult_y, plan.concentration
    )._encode_transaction_data()

    actions = {
        "updateCurveParams": {
            "to": contract.address,
            "data": update_curve,
            "args": {
                "pairId": pair_id.hex(),
                "multX": plan.mult_x,
                "multY": plan.mult_y,
                "concentration": plan.concentration,
            },
        }
    }

    if plan.spread is not None:
        actions["setSpread"] = {
            "to": contract.address,
            "data": contract.get_function_by_name("setSpread")(pair_id, plan.spread)._encode_transaction_data(),
            "args": {"pairId": pair_id.hex(), "spread": plan.spread},
        }

    if plan.target_x is not None and plan.target_y is not None:
        actions["rebalanceLiquidity"] = {
            "to": contract.address,
            "data": contract.get_function_by_name("rebalanceLiquidity")(
                pair_id, plan.target_x, plan.target_y
            )._encode_transaction_data(),
            "args": {
                "pairId": pair_id.hex(),
                "targetX": plan.target_x,
                "targetY": plan.target_y,
            },
        }

    return actions


def main() -> None:
    print("▶️ Generating synthetic OHLCV sample...")
    ohlcv = _synthetic_ohlcv()
    feature_frame = prepare_training_frame(ohlcv)

    print("▶️ Training predictor...")
    predictor = CryptoPricePredictor()
    predictor.fit(feature_frame)

    result = predictor.predict_next(feature_frame.tail(48))
    current_price = float(ohlcv["close"].iloc[-1])
    vol = _realized_volatility(ohlcv["close"].tail(48))

    print("▶️ Building on-chain update plan from signal...")
    snapshot = CurveSnapshot(
        concentration=1_000_000,
        mult_x=1_000_000_000_000_000_000,
        mult_y=1_000_000_000_000_000_000,
        spread=0,
        target_x=100 * 10**18,
        target_y=int(current_price * 100 * 10**6),
    )
    engine = SignalEngine()
    plan = engine.build_plan(
        snapshot,
        predicted_price=result.predicted_price,
        current_price=current_price,
        realized_volatility=vol,
    )

    w3, contract = _build_contract()
    pair_id = w3.keccak(text="WETH/USDC")
    actions = _encode_actions(contract, pair_id, plan)

    print("\n=== Prediction ===")
    print(f"Current close       : {current_price:0.2f}")
    print(f"Predicted next close: {result.predicted_price:0.2f}")
    print(f"Expected return     : {result.expected_return:.6f}")
    print(f"Validation RMSE     : {result.rmse:.6f}")
    print(f"Realized vol (24h)  : {vol:.6f}\n")

    print("=== Curve Update Plan ===")
    for key, value in asdict(plan).items():
        print(f"{key:15}: {value}")

    print("\n=== Encoded Transactions ===")
    for name, payload in actions.items():
        print(f"{name}: to={payload['to']} data={payload['data']}")
        print(f"      args={payload['args']}")


if __name__ == "__main__":
    main()
