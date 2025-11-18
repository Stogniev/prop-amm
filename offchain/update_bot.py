"""Off-chain automation entrypoint for updating PropAMM parameters."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import List

from eth_account import Account
from eth_account.signers.local import LocalAccount
from hexbytes import HexBytes
from web3 import Web3

from prediction import (
    CryptoPricePredictor,
    CurveSnapshot,
    CurveUpdatePlan,
    SignalEngine,
    load_market_data,
    prepare_training_frame,
)


PROP_AMM_ABI = json.loads(
    """
    [
        {
            "inputs": [
                {
                    "internalType": "bytes32",
                    "name": "pairId",
                    "type": "bytes32"
                },
                {
                    "internalType": "uint256",
                    "name": "newMultX",
                    "type": "uint256"
                },
                {
                    "internalType": "uint256",
                    "name": "newMultY",
                    "type": "uint256"
                },
                {
                    "internalType": "uint256",
                    "name": "newConcentration",
                    "type": "uint256"
                }
            ],
            "name": "updateCurveParams",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
        },
        {
            "inputs": [
                {
                    "internalType": "bytes32",
                    "name": "pairId",
                    "type": "bytes32"
                },
                {
                    "internalType": "uint256",
                    "name": "newSpread",
                    "type": "uint256"
                }
            ],
            "name": "setSpread",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
        },
        {
            "inputs": [
                {
                    "internalType": "bytes32",
                    "name": "pairId",
                    "type": "bytes32"
                },
                {
                    "internalType": "uint256",
                    "name": "newTargetX",
                    "type": "uint256"
                },
                {
                    "internalType": "uint256",
                    "name": "newTargetY",
                    "type": "uint256"
                }
            ],
            "name": "rebalanceLiquidity",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
        },
        {
            "inputs": [
                {
                    "internalType": "bytes32",
                    "name": "pairId",
                    "type": "bytes32"
                }
            ],
            "name": "getParametersWithTimestamp",
            "outputs": [
                {
                    "components": [
                        {
                            "internalType": "uint256",
                            "name": "concentration",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "multX",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "multY",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "baseInvariant",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "feeRate",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "spread",
                            "type": "uint256"
                        }
                    ],
                    "internalType": "struct PropAMM.PairParameters",
                    "name": "params",
                    "type": "tuple"
                },
                {
                    "internalType": "uint64",
                    "name": "blockTimestamp",
                    "type": "uint64"
                },
                {
                    "internalType": "uint64",
                    "name": "blockNumber",
                    "type": "uint64"
                }
            ],
            "stateMutability": "view",
            "type": "function"
        },
        {
            "inputs": [
                {
                    "internalType": "bytes32",
                    "name": "pairId",
                    "type": "bytes32"
                }
            ],
            "name": "getPair",
            "outputs": [
                {
                    "components": [
                        {
                            "internalType": "contract IERC20",
                            "name": "tokenX",
                            "type": "address"
                        },
                        {
                            "internalType": "contract IERC20",
                            "name": "tokenY",
                            "type": "address"
                        },
                        {
                            "internalType": "uint256",
                            "name": "reserveX",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "reserveY",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint256",
                            "name": "targetX",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint8",
                            "name": "xRetainDecimals",
                            "type": "uint8"
                        },
                        {
                            "internalType": "uint8",
                            "name": "yRetainDecimals",
                            "type": "uint8"
                        },
                        {
                            "internalType": "bool",
                            "name": "targetYBasedLock",
                            "type": "bool"
                        },
                        {
                            "internalType": "uint256",
                            "name": "targetYReference",
                            "type": "uint256"
                        },
                        {
                            "internalType": "bool",
                            "name": "exists",
                            "type": "bool"
                        }
                    ],
                    "internalType": "struct PropAMM.TradingPair",
                    "name": "pair",
                    "type": "tuple"
                }
            ],
            "stateMutability": "view",
            "type": "function"
        }
    ]
    """
)


@dataclass
class BotConfig:
    rpc_url: str
    contract_address: str
    pair_id: HexBytes
    private_key: str
    dry_run: bool = False


class PropAMMBot:
    """Utility responsible for querying and updating the PropAMM contract."""

    def __init__(self, web3: Web3, config: BotConfig) -> None:
        self.web3 = web3
        self.config = config
        self.account: LocalAccount = Account.from_key(config.private_key)
        self.contract = web3.eth.contract(address=Web3.to_checksum_address(config.contract_address), abi=PROP_AMM_ABI)

    def fetch_snapshot(self) -> CurveSnapshot:
        params, _, _ = self.contract.functions.getParametersWithTimestamp(self.config.pair_id).call()
        pair = self.contract.functions.getPair(self.config.pair_id).call()
        return CurveSnapshot(
            concentration=int(params[0]),
            mult_x=int(params[1]),
            mult_y=int(params[2]),
            spread=int(params[5]),
            target_x=int(pair[4]),
            target_y=int(pair[8]),
        )

    def execute_plan(self, plan: CurveUpdatePlan) -> List[str]:
        """Submit the update transactions, returning their hashes."""

        if self.config.dry_run:
            return []

        nonce = self.web3.eth.get_transaction_count(self.account.address)
        gas_price = self.web3.eth.gas_price
        tx_hashes: List[str] = []

        def _send(tx_builder, current_nonce: int) -> str:
            tx = tx_builder.build_transaction(
                {
                    "from": self.account.address,
                    "nonce": current_nonce,
                    "gas": 400000,
                    "gasPrice": gas_price,
                }
            )
            signed = self.account.sign_transaction(tx)
            tx_hash = self.web3.eth.send_raw_transaction(signed.rawTransaction)
            return tx_hash.hex()

        update_tx = self.contract.functions.updateCurveParams(
            self.config.pair_id,
            int(plan.mult_x),
            int(plan.mult_y),
            int(plan.concentration),
        )
        tx_hashes.append(_send(update_tx, nonce))
        nonce += 1

        if plan.spread is not None:
            spread_tx = self.contract.functions.setSpread(
                self.config.pair_id,
                int(plan.spread),
            )
            tx_hashes.append(_send(spread_tx, nonce))
            nonce += 1

        if plan.target_x is not None and plan.target_y is not None:
            rebalance_tx = self.contract.functions.rebalanceLiquidity(
                self.config.pair_id,
                int(plan.target_x),
                int(plan.target_y),
            )
            tx_hashes.append(_send(rebalance_tx, nonce))

        return tx_hashes


def compute_realized_volatility(feature_frame, window: int = 24) -> float:
    """Approximate realised volatility from log returns."""

    log_returns = feature_frame["log_return"].tail(window)
    if log_returns.empty:
        return 0.0

    return float(log_returns.std() * math.sqrt(window))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PropAMM off-chain market making bot")
    parser.add_argument("--rpc-url", required=True, help="JSON-RPC endpoint")
    parser.add_argument("--contract", required=True, help="PropAMM contract address")
    parser.add_argument("--pair-id", required=True, help="Pair identifier (hex string)")
    parser.add_argument("--private-key", required=True, help="Private key of authorised market maker")
    parser.add_argument("--data", required=True, help="CSV file with OHLCV data")
    parser.add_argument("--dry-run", action="store_true", help="Skip sending transactions")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    market_data = load_market_data(Path(args.data))
    training_frame = prepare_training_frame(market_data)

    predictor = CryptoPricePredictor()
    predictor.fit(training_frame)
    prediction_frame = training_frame.tail(128)
    prediction = predictor.predict_next(prediction_frame)
    current_price = float(prediction_frame["close"].iloc[-1])
    realized_vol = compute_realized_volatility(prediction_frame)

    engine = SignalEngine()

    web3 = Web3(Web3.HTTPProvider(args.rpc_url))

    config = BotConfig(
        rpc_url=args.rpc_url,
        contract_address=args.contract,
        pair_id=HexBytes(args.pair_id),
        private_key=args.private_key,
        dry_run=args.dry_run,
    )

    bot = PropAMMBot(web3, config)
    snapshot = bot.fetch_snapshot()
    plan = engine.build_plan(
        snapshot,
        predicted_price=prediction.predicted_price,
        current_price=current_price,
        realized_volatility=realized_vol,
    )

    if args.dry_run:
        print("Predicted price:", prediction.predicted_price)
        print("Expected return:", prediction.expected_return)
        print("RMSE:", prediction.rmse)
        print("Planned update:", plan)
        return

    tx_hashes = bot.execute_plan(plan)
    for tx in tx_hashes:
        print("Submitted transaction:", tx)


if __name__ == "__main__":
    main()
