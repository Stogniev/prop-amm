"""Data loading and feature engineering helpers used by the update bot."""

from __future__ import annotations

from pathlib import Path
from typing import Iterable, Tuple

import numpy as np
import pandas as pd


def load_market_data(csv_path: Path | str) -> pd.DataFrame:
    """Load OHLCV data from a CSV file.

    The helper mirrors the data preparation workflow in the
    Cryptocurrency-Price-Prediction project by:

    * parsing dates
    * normalising column names
    * sorting records chronologically
    * casting numeric columns to floating point precision
    """

    path = Path(csv_path)
    if not path.exists():
        raise FileNotFoundError(f"Market data not found: {path}")

    df = pd.read_csv(path)
    df.columns = [col.strip().lower() for col in df.columns]

    date_column = None
    for candidate in ("timestamp", "date", "time"):
        if candidate in df.columns:
            date_column = candidate
            break
    if date_column is None:
        raise ValueError("CSV must include a timestamp/date column")

    df[date_column] = pd.to_datetime(df[date_column], utc=True)
    df = df.sort_values(date_column).reset_index(drop=True)

    numeric_columns = [
        col
        for col in ("open", "high", "low", "close", "volume")
        if col in df.columns
    ]
    for col in numeric_columns:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    df = df.dropna(subset=numeric_columns)
    return df


def _rolling_features(frame: pd.DataFrame, windows: Iterable[int]) -> pd.DataFrame:
    """Compute rolling mean, std and RSI-like oscillators."""

    result = frame.copy()
    log_return = np.log(result["close"]).diff()
    result["log_return"] = log_return
    result["abs_log_return"] = log_return.abs()

    for window in windows:
        if window <= 1:
            continue
        result[f"close_mean_{window}"] = result["close"].rolling(window).mean()
        result[f"close_std_{window}"] = result["close"].rolling(window).std()
        result[f"volume_mean_{window}"] = result["volume"].rolling(window).mean()
        result[f"volume_std_{window}"] = result["volume"].rolling(window).std()

        delta = result["close"].diff()
        gain = delta.clip(lower=0)
        loss = (-delta).clip(lower=0)
        avg_gain = gain.rolling(window).mean()
        avg_loss = loss.rolling(window).mean()
        rs = avg_gain / (avg_loss + 1e-9)
        result[f"rsi_{window}"] = 100 - (100 / (1 + rs))

    return result


def prepare_training_frame(
    market_data: pd.DataFrame,
    target_horizon: int = 1,
    feature_windows: Tuple[int, ...] = (6, 12, 24, 48),
) -> pd.DataFrame:
    """Return a clean feature frame with a forward looking price target."""

    if "close" not in market_data.columns:
        raise ValueError("Market data must contain a 'close' column")

    enriched = _rolling_features(market_data, feature_windows)
    enriched["target"] = enriched["close"].shift(-target_horizon)
    enriched["target_return"] = (enriched["target"] - enriched["close"]) / enriched["close"]

    feature_cols = [col for col in enriched.columns if col not in {"target", "target_return"}]
    enriched = enriched.dropna(subset=feature_cols + ["target", "target_return"])
    return enriched
