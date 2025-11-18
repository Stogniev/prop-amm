"""Machine learning model inspired by the Cryptocurrency-Price-Prediction repo."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_squared_error
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import MinMaxScaler


@dataclass
class PredictionResult:
    """Container returned by :meth:`CryptoPricePredictor.predict_next`."""

    predicted_price: float
    expected_return: float
    rmse: float


class CryptoPricePredictor:
    """A lightweight ensemble model suitable for frequent re-training."""

    def __init__(
        self,
        feature_columns: Sequence[str] | None = None,
        *,
        random_state: int = 7,
        n_estimators: int = 400,
        max_depth: int | None = 8,
        test_size: float = 0.2,
    ) -> None:
        self._feature_columns = list(feature_columns) if feature_columns else None
        self._scaler = MinMaxScaler()
        self._model = RandomForestRegressor(
            n_estimators=n_estimators,
            max_depth=max_depth,
            random_state=random_state,
            n_jobs=-1,
        )
        self._test_size = test_size
        self._rmse = np.nan
        self._is_fitted = False

    @property
    def rmse(self) -> float:
        """Return the last computed validation RMSE."""

        return float(self._rmse)

    def fit(self, frame: pd.DataFrame) -> None:
        """Train the model on a feature engineered frame."""

        if "target_return" not in frame.columns:
            raise ValueError("Frame must contain a 'target_return' column")

        features = frame.drop(columns=["target", "target_return"], errors="ignore")
        features = features.select_dtypes(include=[np.number])
        if features.empty:
            raise ValueError("Feature frame must contain at least one numeric column")

        targets = frame["target_return"]

        if self._feature_columns is None:
            self._feature_columns = list(features.columns)
        else:
            missing = set(self._feature_columns) - set(features.columns)
            if missing:
                raise ValueError(f"Missing features required by the model: {sorted(missing)}")
            features = features[self._feature_columns]

        x_train, x_val, y_train, y_val = train_test_split(
            features,
            targets,
            test_size=self._test_size,
            shuffle=False,
        )

        x_train_scaled = self._scaler.fit_transform(x_train)
        x_val_scaled = self._scaler.transform(x_val)

        self._model.fit(x_train_scaled, y_train)
        predictions = self._model.predict(x_val_scaled)
        try:
            # Newer sklearn exposes ``squared`` to return RMSE directly.
            self._rmse = mean_squared_error(y_val, predictions, squared=False)
        except TypeError:
            # Older sklearn lacks the ``squared`` kwarg; compute RMSE manually.
            self._rmse = float(np.sqrt(mean_squared_error(y_val, predictions)))
        self._is_fitted = True

    def predict_next(self, frame: pd.DataFrame) -> PredictionResult:
        """Predict the next step price using the latest feature window."""

        if not self._is_fitted:
            raise RuntimeError("Model must be fitted before calling predict_next")

        required_columns = set(self._feature_columns or [])
        required_columns.update({"close"})
        missing = required_columns - set(frame.columns)
        if missing:
            raise ValueError(f"Frame is missing required columns: {sorted(missing)}")

        features = frame[self._feature_columns]
        latest_scaled = self._scaler.transform(features)
        returns = self._model.predict(latest_scaled)
        expected_return = float(returns[-1])
        predicted_price = float(frame["close"].iloc[-1] * (1 + expected_return))

        return PredictionResult(
            predicted_price=predicted_price,
            expected_return=expected_return,
            rmse=self.rmse,
        )
