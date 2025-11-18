"""Translate price predictions into PropAMM parameter updates."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

FEE_BASE = 1_000_000


@dataclass
class CurveSnapshot:
    """Represents the latest on-chain configuration for a trading pair."""

    concentration: int
    mult_x: int
    mult_y: int
    spread: int
    target_x: int
    target_y: int


@dataclass
class CurveUpdatePlan:
    """Instructions for updating PropAMM parameters."""

    mult_x: int
    mult_y: int
    concentration: int
    spread: Optional[int] = None
    target_x: Optional[int] = None
    target_y: Optional[int] = None


class SignalEngine:
    """Convert off-chain predictions into actionable on-chain updates."""

    def __init__(
        self,
        *,
        price_tolerance: float = 0.001,
        volatility_threshold: float = 0.02,
        concentration_widen_factor: float = 0.5,
        spread_step: int = 500,
        concentration_bounds: tuple[int, int] = (1_000_000, 200_000_000),
    ) -> None:
        self.price_tolerance = price_tolerance
        self.volatility_threshold = volatility_threshold
        self.concentration_widen_factor = concentration_widen_factor
        self.spread_step = spread_step
        self.concentration_bounds = concentration_bounds

    def build_plan(
        self,
        snapshot: CurveSnapshot,
        *,
        predicted_price: float,
        current_price: float,
        realized_volatility: float,
    ) -> CurveUpdatePlan:
        """Derive a curve adjustment from price/volatility signals."""

        if current_price <= 0:
            raise ValueError("Current price must be positive")

        price_ratio = predicted_price / current_price
        deviation = abs(price_ratio - 1)

        mult_x = snapshot.mult_x
        mult_y = snapshot.mult_y
        concentration = snapshot.concentration

        if deviation > self.price_tolerance:
            mult_y = max(1, int(snapshot.mult_y * price_ratio))

        new_spread: Optional[int] = None
        if realized_volatility > self.volatility_threshold:
            concentration = int(snapshot.concentration * self.concentration_widen_factor)
            lower, upper = self.concentration_bounds
            concentration = max(lower, min(concentration, upper))
            new_spread = min(FEE_BASE, snapshot.spread + self.spread_step)
        else:
            concentration = max(
                self.concentration_bounds[0],
                min(snapshot.concentration, self.concentration_bounds[1]),
            )

        target_x = snapshot.target_x
        target_y = snapshot.target_y
        if deviation > self.price_tolerance and snapshot.target_y > 0:
            target_y = int(snapshot.target_y * price_ratio)

        rebalance_x: Optional[int] = None
        rebalance_y: Optional[int] = None
        if target_x != snapshot.target_x or target_y != snapshot.target_y:
            rebalance_x = target_x
            rebalance_y = target_y

        return CurveUpdatePlan(
            mult_x=mult_x,
            mult_y=mult_y,
            concentration=concentration,
            spread=new_spread,
            target_x=rebalance_x,
            target_y=rebalance_y,
        )
