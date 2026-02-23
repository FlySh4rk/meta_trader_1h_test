"""
Build ML dataset from reconstructed MT5 EA signals (EURUSD H1).

Output:
    ml_dataset_eurusd_h1.csv

Requirements covered:
1) Download last 5 years of EURUSD H1 data from MT5.
2) Recreate EA features:
   - EMA220, 20-period slope, ATR14, slope_normalized
   - Bollinger Bands (24, 2.3)
   - RSI14
   - Donchian Channel (24)
   - HourOfDay, DayOfWeek, ATR_normalized (ATR14 / ATR14_MA100)
3) Simulate Range/Trend long+short entry signals.
4) Forward label each signal with trade-style outcome.
5) Export clean dataset and print class balance.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

import MetaTrader5 as mt5
import numpy as np
import pandas as pd


# ----------------------------
# Configuration
# ----------------------------
SYMBOL = "EURUSD"
TIMEFRAME = mt5.TIMEFRAME_H1
YEARS_BACK = 5
OUTPUT_CSV = "ml_dataset_eurusd_h1.csv"

# Strategy thresholds
RANGE_SLOPE_MIN = -0.025
RANGE_SLOPE_MAX = 0.025
TREND_SLOPE_MIN = 0.05
TREND_SLOPE_MAX = -0.05


@dataclass
class Signal:
    """Container for one reconstructed signal event."""

    index: int
    timestamp: pd.Timestamp
    strategy: str       # "range" or "trend"
    direction: str      # "long" or "short"
    entry: float
    atr: float
    bb_middle: float


def compute_rsi(close: pd.Series, period: int = 14) -> pd.Series:
    """Wilder RSI implementation."""
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)

    avg_gain = gain.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()

    rs = avg_gain / avg_loss.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))
    return rsi


def compute_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """ATR (Wilder) from OHLC."""
    high = df["high"]
    low = df["low"]
    close = df["close"]
    prev_close = close.shift(1)

    tr = pd.concat(
        [
            high - low,
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)

    atr = tr.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()
    return atr


def add_features(df: pd.DataFrame) -> pd.DataFrame:
    """Add all requested features to dataframe."""
    out = df.copy()

    # EMA220
    out["ema_220"] = out["close"].ewm(span=220, adjust=False).mean()

    # 20-period slope of EMA220, normalized by ATR14
    out["slope_20"] = (out["ema_220"] - out["ema_220"].shift(20)) / 20.0
    out["atr_14"] = compute_atr(out, period=14)
    out["slope_normalized"] = out["slope_20"] / out["atr_14"]

    # Bollinger Bands (24, 2.3)
    bb_period = 24
    bb_std_mult = 2.3
    out["bb_middle"] = out["close"].rolling(bb_period, min_periods=bb_period).mean()
    bb_std = out["close"].rolling(bb_period, min_periods=bb_period).std(ddof=0)
    out["bb_upper"] = out["bb_middle"] + bb_std_mult * bb_std
    out["bb_lower"] = out["bb_middle"] - bb_std_mult * bb_std

    # RSI14
    out["rsi_14"] = compute_rsi(out["close"], period=14)

    # Donchian 24 built from previous candles to avoid look-ahead bias
    dc_period = 24
    out["donchian_upper"] = (
        out["high"].rolling(dc_period, min_periods=dc_period).max().shift(1)
    )
    out["donchian_lower"] = (
        out["low"].rolling(dc_period, min_periods=dc_period).min().shift(1)
    )

    # Time features
    out["HourOfDay"] = out["time"].dt.hour
    out["DayOfWeek"] = out["time"].dt.dayofweek

    # ATR normalized by ATR MA100
    out["atr_ma_100"] = out["atr_14"].rolling(100, min_periods=100).mean()
    out["ATR_normalized"] = out["atr_14"] / out["atr_ma_100"]

    return out


def build_signals(df: pd.DataFrame) -> list[Signal]:
    """Reconstruct all range/trend long+short signals."""
    signals: list[Signal] = []

    # Range signals
    range_long_mask = (
        (df["low"] <= df["bb_lower"])
        & (df["rsi_14"] < 20)
        & (df["slope_normalized"] >= RANGE_SLOPE_MIN)
        & (df["slope_normalized"] <= RANGE_SLOPE_MAX)
    )

    range_short_mask = (
        (df["high"] >= df["bb_upper"])
        & (df["rsi_14"] > 80)
        & (df["slope_normalized"] >= RANGE_SLOPE_MIN)
        & (df["slope_normalized"] <= RANGE_SLOPE_MAX)
    )

    # Trend signals
    trend_long_mask = (
        (df["close"] > df["donchian_upper"])
        & (df["slope_normalized"] > TREND_SLOPE_MIN)
    )

    trend_short_mask = (
        (df["close"] < df["donchian_lower"])
        & (df["slope_normalized"] < TREND_SLOPE_MAX)
    )

    for i, row in df[range_long_mask].iterrows():
        signals.append(
            Signal(
                index=i,
                timestamp=row["time"],
                strategy="range",
                direction="long",
                entry=row["close"],
                atr=row["atr_14"],
                bb_middle=row["bb_middle"],
            )
        )

    for i, row in df[range_short_mask].iterrows():
        signals.append(
            Signal(
                index=i,
                timestamp=row["time"],
                strategy="range",
                direction="short",
                entry=row["close"],
                atr=row["atr_14"],
                bb_middle=row["bb_middle"],
            )
        )

    for i, row in df[trend_long_mask].iterrows():
        signals.append(
            Signal(
                index=i,
                timestamp=row["time"],
                strategy="trend",
                direction="long",
                entry=row["close"],
                atr=row["atr_14"],
                bb_middle=row["bb_middle"],
            )
        )

    for i, row in df[trend_short_mask].iterrows():
        signals.append(
            Signal(
                index=i,
                timestamp=row["time"],
                strategy="trend",
                direction="short",
                entry=row["close"],
                atr=row["atr_14"],
                bb_middle=row["bb_middle"],
            )
        )

    signals.sort(key=lambda s: s.index)
    return signals


def label_range_trade(signal: Signal, df: pd.DataFrame) -> Optional[int]:
    """
    Forward-label a range trade.

    TP = Middle BB at entry
    SL = 1.0 * ATR at entry

    Returns:
        1 if TP hits first,
        0 if SL hits first,
        None if neither is hit before data end.
    """
    entry = signal.entry
    atr = signal.atr
    tp = signal.bb_middle

    if signal.direction == "long":
        sl = entry - atr
    else:
        sl = entry + atr

    future = df.iloc[signal.index + 1 :]
    for _, bar in future.iterrows():
        high = bar["high"]
        low = bar["low"]

        if signal.direction == "long":
            tp_hit = high >= tp
            sl_hit = low <= sl
        else:
            tp_hit = low <= tp
            sl_hit = high >= sl

        # In same-candle conflicts, use conservative ordering: SL first.
        if sl_hit and tp_hit:
            return 0
        if sl_hit:
            return 0
        if tp_hit:
            return 1

    return None


def label_trend_trade(signal: Signal, df: pd.DataFrame) -> Optional[int]:
    """
    Forward-label a trend trade.

    Rules:
    - Initial SL = 3.25 * ATR
    - Trailing distance = 2.0 * ATR
    - Label=1 when trailing stop is in profit (beyond entry) and then hit
      before initial SL.
    - Label=0 when initial SL is hit first.
    - None if unresolved before data end.
    """
    entry = signal.entry
    atr = signal.atr
    trail_dist = 2.0 * atr

    if signal.direction == "long":
        initial_sl = entry - 3.25 * atr
        best_high = entry
        trailing_stop = entry - trail_dist

        future = df.iloc[signal.index + 1 :]
        for _, bar in future.iterrows():
            high = bar["high"]
            low = bar["low"]

            # Update trailing stop from most favorable excursion.
            if high > best_high:
                best_high = high
                trailing_stop = best_high - trail_dist

            # If initial SL is touched, losing outcome.
            if low <= initial_sl:
                return 0

            # Positive trailing stop means locked-in profit.
            if trailing_stop > entry and low <= trailing_stop:
                return 1

    else:
        initial_sl = entry + 3.25 * atr
        best_low = entry
        trailing_stop = entry + trail_dist

        future = df.iloc[signal.index + 1 :]
        for _, bar in future.iterrows():
            high = bar["high"]
            low = bar["low"]

            if low < best_low:
                best_low = low
                trailing_stop = best_low + trail_dist

            if high >= initial_sl:
                return 0

            if trailing_stop < entry and high >= trailing_stop:
                return 1

    return None


def label_signal(signal: Signal, df: pd.DataFrame) -> Optional[int]:
    """Dispatch labeling by strategy type."""
    if signal.strategy == "range":
        return label_range_trade(signal, df)
    if signal.strategy == "trend":
        return label_trend_trade(signal, df)
    return None


def build_dataset(df: pd.DataFrame, signals: list[Signal]) -> pd.DataFrame:
    """Create final supervised dataset rows (X + y) for all labeled signals."""
    records: list[dict] = []

    feature_cols = [
        "time",
        "open",
        "high",
        "low",
        "close",
        "tick_volume",
        "ema_220",
        "slope_20",
        "atr_14",
        "slope_normalized",
        "bb_upper",
        "bb_middle",
        "bb_lower",
        "rsi_14",
        "donchian_upper",
        "donchian_lower",
        "HourOfDay",
        "DayOfWeek",
        "ATR_normalized",
    ]

    for s in signals:
        y = label_signal(s, df)
        if y is None:
            continue

        row = df.iloc[s.index]
        rec = {c: row[c] for c in feature_cols}
        rec["strategy"] = s.strategy
        rec["direction"] = s.direction
        rec["y"] = int(y)
        records.append(rec)

    dataset = pd.DataFrame.from_records(records)
    dataset = dataset.dropna().reset_index(drop=True)
    return dataset


def download_data(symbol: str, timeframe: int, years_back: int) -> pd.DataFrame:
    """Download OHLCV history from MT5."""
    utc_to = datetime.now(timezone.utc)
    utc_from = utc_to - timedelta(days=365 * years_back)

    rates = mt5.copy_rates_range(symbol, timeframe, utc_from, utc_to)
    if rates is None or len(rates) == 0:
        raise RuntimeError(
            f"Nessun dato ricevuto da MT5 per {symbol} timeframe={timeframe}."
        )

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    return df


def main() -> None:
    """Main execution pipeline."""
    if not mt5.initialize():
        raise RuntimeError(f"MT5 initialize() fallita: {mt5.last_error()}")

    try:
        if not mt5.symbol_select(SYMBOL, True):
            raise RuntimeError(f"symbol_select() fallita per {SYMBOL}: {mt5.last_error()}")

        print(f"Scarico {YEARS_BACK} anni di dati {SYMBOL} H1...")
        raw = download_data(SYMBOL, TIMEFRAME, YEARS_BACK)
        print(f"Bar scaricate: {len(raw)}")

        feat = add_features(raw)
        feat = feat.dropna().reset_index(drop=True)
        print(f"Bar dopo feature engineering + dropna: {len(feat)}")

        signals = build_signals(feat)
        print(f"Segnali ricostruiti: {len(signals)}")

        dataset = build_dataset(feat, signals)
        dataset.to_csv(OUTPUT_CSV, index=False)

        print(f"Dataset esportato in: {OUTPUT_CSV}")
        print(f"Righe finali: {len(dataset)}")

        class_balance = dataset["y"].value_counts().sort_index()
        print("\nClass balance (y=0, y=1):")
        print(class_balance)

    finally:
        # Always close MT5 terminal connection.
        mt5.shutdown()


if __name__ == "__main__":
    main()
