"""
Vectorized out-of-sample backtest for EURUSD H1 Random Forest filter.

This script:
1) Loads the dataset and model used in training.
2) Recreates the exact same engineered features used by the model.
3) Applies the same strict chronological 80/20 split.
4) Runs OOS predictions on the test set.
5) Simulates baseline vs AI-filtered PnL and plots both equity curves.
"""

from __future__ import annotations

from pathlib import Path

import joblib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


# Input/output paths
DATASET_PATH = Path("ml_dataset_eurusd_h1.csv")
MODEL_PATH = Path("rf_model_eurusd_h1.pkl")
EQUITY_PLOT_PATH = Path("equity_curve_comparison.png")

# Model feature schema (must match training)
FEATURE_COLUMNS = [
    "slope_normalized",
    "rsi_14",
    "HourOfDay",
    "DayOfWeek",
    "ATR_normalized",
    "dist_ema_atr",
    "bb_position",
    "is_trend",
    "is_long",
]
TARGET_COLUMN = "y"


def load_data(path: Path) -> pd.DataFrame:
    """Load dataset and parse time column as UTC datetime."""
    if not path.exists():
        raise FileNotFoundError(f"Dataset non trovato: {path.resolve()}")

    df = pd.read_csv(path)
    if "time" not in df.columns:
        raise ValueError("Colonna obbligatoria mancante: 'time'")

    df["time"] = pd.to_datetime(df["time"], utc=True, errors="coerce")
    if df["time"].isna().any():
        raise ValueError("La colonna 'time' contiene valori non parsabili.")

    return df


def engineer_stationary_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Rebuild stationary features exactly as done in model training.
    """
    required_cols = [
        "close",
        "ema_220",
        "atr_14",
        "bb_lower",
        "bb_upper",
        "strategy",
        "direction",
    ]
    missing = [col for col in required_cols if col not in df.columns]
    if missing:
        raise ValueError(f"Colonne mancanti per feature engineering: {missing}")

    out = df.copy()

    # Distance from EMA normalized by ATR.
    out["dist_ema_atr"] = (out["close"] - out["ema_220"]) / out["atr_14"].replace(0, np.nan)

    # Relative position inside Bollinger bands.
    bb_width = (out["bb_upper"] - out["bb_lower"]).replace(0, np.nan)
    out["bb_position"] = (out["close"] - out["bb_lower"]) / bb_width

    # Binary encodings.
    out["is_trend"] = (out["strategy"].str.lower() == "trend").astype(int)
    out["is_long"] = (out["direction"].str.lower() == "long").astype(int)

    return out


def prepare_xy(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.Series]:
    """Select model features and target; remove invalid rows."""
    required = FEATURE_COLUMNS + [TARGET_COLUMN]
    missing = [col for col in required if col not in df.columns]
    if missing:
        raise ValueError(f"Colonne mancanti per modello: {missing}")

    model_df = df[required].copy()
    model_df = model_df.replace([np.inf, -np.inf], np.nan).dropna()
    if model_df.empty:
        raise ValueError("Nessuna riga valida dopo pulizia NaN/inf.")

    x = model_df[FEATURE_COLUMNS]
    y = model_df[TARGET_COLUMN].astype(int)
    return x, y


def chronological_split(
    df: pd.DataFrame,
    x: pd.DataFrame,
    y: pd.Series,
    train_ratio: float = 0.8,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.Series, pd.Series, list[int]]:
    """
    Same split logic used in training:
    - keep only cleaned rows
    - sort by time
    - first 80% train, last 20% test
    """
    time_map = df.loc[x.index, ["time"]].copy()
    time_map["row_idx"] = time_map.index
    time_map = time_map.sort_values("time")
    ordered_idx = time_map["row_idx"].to_list()

    x_sorted = x.loc[ordered_idx].reset_index(drop=True)
    y_sorted = y.loc[ordered_idx].reset_index(drop=True)

    n_rows = len(x_sorted)
    if n_rows < 10:
        raise ValueError(f"Dataset troppo piccolo per split robusto (righe: {n_rows}).")

    split_idx = int(n_rows * train_ratio)
    if split_idx <= 0 or split_idx >= n_rows:
        raise ValueError("Split cronologico non valido.")

    x_train = x_sorted.iloc[:split_idx]
    x_test = x_sorted.iloc[split_idx:]
    y_train = y_sorted.iloc[:split_idx]
    y_test = y_sorted.iloc[split_idx:]

    # Return ordered original indices to align extra columns for PnL simulation.
    ordered_test_idx = ordered_idx[split_idx:]
    return x_train, x_test, y_train, y_test, ordered_test_idx


def compute_trade_pnl_points(test_df: pd.DataFrame) -> pd.Series:
    """
    Approximate per-trade PnL in price points according to provided rules.

    Rules:
    - range + y=1 -> +abs(close - bb_middle)
    - range + y=0 -> -1.0 * atr_14
    - trend + y=1 -> +2.0 * atr_14
    - trend + y=0 -> -3.25 * atr_14
    """
    required_cols = ["strategy", "y", "close", "bb_middle", "atr_14"]
    missing = [col for col in required_cols if col not in test_df.columns]
    if missing:
        raise ValueError(f"Colonne mancanti per simulazione PnL: {missing}")

    out = pd.Series(0.0, index=test_df.index, dtype=float)

    range_mask = test_df["strategy"].str.lower() == "range"
    trend_mask = test_df["strategy"].str.lower() == "trend"
    win_mask = test_df["y"].astype(int) == 1
    loss_mask = ~win_mask

    # Range winners: distance to middle band (absolute, direction-agnostic).
    out.loc[range_mask & win_mask] = (
        test_df.loc[range_mask & win_mask, "close"]
        - test_df.loc[range_mask & win_mask, "bb_middle"]
    ).abs()

    # Range losers: fixed stop of 1 ATR.
    out.loc[range_mask & loss_mask] = -1.0 * test_df.loc[range_mask & loss_mask, "atr_14"]

    # Trend winners: trailing stop estimate of +2 ATR.
    out.loc[trend_mask & win_mask] = 2.0 * test_df.loc[trend_mask & win_mask, "atr_14"]

    # Trend losers: fixed stop of -3.25 ATR.
    out.loc[trend_mask & loss_mask] = -3.25 * test_df.loc[trend_mask & loss_mask, "atr_14"]

    return out


def profit_factor(pnl: pd.Series) -> float:
    """Compute profit factor = gross_profit / gross_loss_abs."""
    gross_profit = pnl[pnl > 0].sum()
    gross_loss_abs = -pnl[pnl < 0].sum()
    if gross_loss_abs == 0:
        return np.inf if gross_profit > 0 else 0.0
    return float(gross_profit / gross_loss_abs)


def main() -> None:
    """Run OOS backtest and produce chart + summary metrics."""
    print("Caricamento dataset e modello...")
    df = load_data(DATASET_PATH)
    if not MODEL_PATH.exists():
        raise FileNotFoundError(f"Modello non trovato: {MODEL_PATH.resolve()}")
    model = joblib.load(MODEL_PATH)

    print("Feature engineering identico al training...")
    df = engineer_stationary_features(df)

    print("Preparazione X/y e split cronologico 80/20...")
    x, y = prepare_xy(df)
    _, x_test, _, y_test, test_idx = chronological_split(df, x, y, train_ratio=0.8)

    print(f"Righe test OOS: {len(x_test)}")

    print("Predizione modello su OOS...")
    y_pred = model.predict(x_test)
    y_pred = pd.Series(y_pred, index=x_test.index).astype(int)

    # Build the aligned test frame with all columns needed for PnL simulation.
    test_df = df.loc[test_idx].copy().reset_index(drop=True)
    test_df["y"] = y_test.reset_index(drop=True).astype(int)
    test_df["y_pred"] = y_pred.reset_index(drop=True).astype(int)

    print("Simulazione PnL baseline vs AI filter...")
    per_trade_pnl = compute_trade_pnl_points(test_df)

    # Baseline: always take every trade.
    baseline_step_pnl = per_trade_pnl.copy()
    baseline_equity = baseline_step_pnl.cumsum()

    # AI filtered: take trade only when model says 1, else skip (0 PnL).
    ai_step_pnl = per_trade_pnl.where(test_df["y_pred"] == 1, 0.0)
    ai_equity = ai_step_pnl.cumsum()

    # Save equity curve comparison.
    plt.figure(figsize=(12, 6))
    plt.plot(baseline_equity.values, label="Baseline (All Trades)", linewidth=2)
    plt.plot(ai_equity.values, label="AI Filtered (y_pred=1 only)", linewidth=2)
    plt.title("Out-of-Sample Equity Curve Comparison - EURUSD H1")
    plt.xlabel("Trade Index (chronological OOS)")
    plt.ylabel("Cumulative PnL (points)")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(EQUITY_PLOT_PATH, dpi=150)
    plt.close()

    # Metrics for AI filtered strategy.
    taken_mask = test_df["y_pred"] == 1
    skipped_mask = ~taken_mask
    taken_count = int(taken_mask.sum())
    skipped_count = int(skipped_mask.sum())

    ai_taken_outcomes = test_df.loc[taken_mask, "y"].astype(int)
    wins_taken = int((ai_taken_outcomes == 1).sum())
    win_rate = (wins_taken / taken_count) if taken_count > 0 else 0.0

    total_pnl_ai = float(ai_step_pnl.sum())
    pf_ai = profit_factor(ai_step_pnl)

    print("\n=== AI Filtered Strategy Metrics (OOS) ===")
    print(f"Trades Taken:   {taken_count}")
    print(f"Trades Skipped: {skipped_count}")
    print(f"Win Rate:       {win_rate:.2%}")
    print(f"Total PnL:      {total_pnl_ai:.6f} points")
    print(f"Profit Factor:  {pf_ai:.4f}" if np.isfinite(pf_ai) else "Profit Factor:  inf")

    print(f"\nGrafico salvato in: {EQUITY_PLOT_PATH.resolve()}")


if __name__ == "__main__":
    main()
