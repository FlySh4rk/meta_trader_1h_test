"""
Train a Random Forest classifier on EURUSD H1 trade dataset.

Phase 2 - Machine Learning Data Pipeline
---------------------------------------
This script:
1) loads `ml_dataset_eurusd_h1.csv`,
2) builds stationary features,
3) performs strict chronological split (80% train, 20% test),
4) trains a RandomForestClassifier,
5) evaluates out-of-sample performance,
6) saves feature importance plot and trained model.
"""

from __future__ import annotations

from pathlib import Path

import joblib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report


# File paths (relative to script working directory).
DATASET_PATH = Path("ml_dataset_eurusd_h1.csv")
MODEL_OUTPUT_PATH = Path("rf_model_eurusd_h1.pkl")
FEATURE_IMPORTANCE_PLOT_PATH = Path("feature_importances.png")

# Fixed feature list requested for model input.
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
    """Load dataset and parse `time` as datetime."""
    if not path.exists():
        raise FileNotFoundError(f"Dataset non trovato: {path.resolve()}")

    df = pd.read_csv(path)
    if "time" not in df.columns:
        raise ValueError("Colonna obbligatoria mancante: 'time'")

    # Parse timestamps explicitly to ensure chronological ordering is correct.
    df["time"] = pd.to_datetime(df["time"], utc=True, errors="coerce")
    if df["time"].isna().any():
        raise ValueError("La colonna 'time' contiene valori non validi/non parsabili.")

    return df


def engineer_stationary_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Create stationary, model-safe features only.

    Absolute prices are never used directly in model input.
    They are only used to create normalized distances/positions.
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

    # Over-extension from long-term mean, normalized by volatility.
    out["dist_ema_atr"] = (out["close"] - out["ema_220"]) / out["atr_14"].replace(0, np.nan)

    # Position inside Bollinger Bands [can go outside 0..1 on band breakouts].
    bb_width = (out["bb_upper"] - out["bb_lower"]).replace(0, np.nan)
    out["bb_position"] = (out["close"] - out["bb_lower"]) / bb_width

    # Binary encodings for categorical fields.
    out["is_trend"] = (out["strategy"].str.lower() == "trend").astype(int)
    out["is_long"] = (out["direction"].str.lower() == "long").astype(int)

    return out


def prepare_xy(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.Series]:
    """Select requested features and target, then clean invalid rows."""
    required_for_model = FEATURE_COLUMNS + [TARGET_COLUMN]
    missing = [col for col in required_for_model if col not in df.columns]
    if missing:
        raise ValueError(f"Colonne mancanti per training: {missing}")

    model_df = df[required_for_model].copy()

    # Replace inf values from edge divisions, then drop incomplete rows.
    model_df = model_df.replace([np.inf, -np.inf], np.nan).dropna()
    if model_df.empty:
        raise ValueError("Nessuna riga valida dopo la pulizia di NaN/inf.")

    x = model_df[FEATURE_COLUMNS]
    y = model_df[TARGET_COLUMN].astype(int)
    return x, y


def chronological_split(
    df: pd.DataFrame,
    x: pd.DataFrame,
    y: pd.Series,
    train_ratio: float = 0.8,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.Series, pd.Series]:
    """Perform strict time-ordered split: first 80% train, last 20% test."""
    # Build a time-index map using only rows that survived model-data cleaning.
    time_map = df.loc[x.index, ["time"]].copy()
    time_map["row_idx"] = time_map.index

    # Sort by time to avoid look-ahead bias if input is unsorted.
    time_map = time_map.sort_values("time")
    ordered_idx = time_map["row_idx"].to_list()

    x_sorted = x.loc[ordered_idx].reset_index(drop=True)
    y_sorted = y.loc[ordered_idx].reset_index(drop=True)

    n_rows = len(x_sorted)
    if n_rows < 10:
        raise ValueError(f"Dataset troppo piccolo per split robusto (righe valide: {n_rows}).")

    split_idx = int(n_rows * train_ratio)
    if split_idx <= 0 or split_idx >= n_rows:
        raise ValueError("Split cronologico non valido: controlla dimensione dataset.")

    x_train = x_sorted.iloc[:split_idx]
    x_test = x_sorted.iloc[split_idx:]
    y_train = y_sorted.iloc[:split_idx]
    y_test = y_sorted.iloc[split_idx:]

    return x_train, x_test, y_train, y_test


def plot_feature_importances(
    model: RandomForestClassifier,
    feature_names: list[str],
    output_path: Path,
) -> None:
    """Plot and save horizontal feature-importance chart."""
    importances = pd.Series(model.feature_importances_, index=feature_names).sort_values(
        ascending=True
    )

    plt.figure(figsize=(10, 6))
    sns.barplot(x=importances.values, y=importances.index, orient="h", palette="viridis")
    plt.title("Random Forest Feature Importances")
    plt.xlabel("Importance")
    plt.ylabel("Feature")
    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()


def main() -> None:
    """End-to-end training pipeline."""
    print("Caricamento dataset...")
    df = load_data(DATASET_PATH)

    print("Feature engineering stazionario...")
    df = engineer_stationary_features(df)

    print("Preparazione X e y...")
    x, y = prepare_xy(df)

    print("Split cronologico 80/20...")
    x_train, x_test, y_train, y_test = chronological_split(df, x, y, train_ratio=0.8)
    print(f"Train rows: {len(x_train)} | Test rows: {len(x_test)}")

    print("Training RandomForestClassifier...")
    model = RandomForestClassifier(
        n_estimators=100,
        max_depth=5,
        random_state=42,
    )
    model.fit(x_train, y_train)

    print("Valutazione out-of-sample...")
    y_pred = model.predict(x_test)
    accuracy = accuracy_score(y_test, y_pred)
    report = classification_report(y_test, y_pred)

    print(f"\nAccuracy (OOS): {accuracy:.4f}")
    print("\nClassification Report:")
    print(report)

    print(f"Salvataggio feature importances: {FEATURE_IMPORTANCE_PLOT_PATH}")
    plot_feature_importances(model, FEATURE_COLUMNS, FEATURE_IMPORTANCE_PLOT_PATH)

    print(f"Salvataggio modello: {MODEL_OUTPUT_PATH}")
    joblib.dump(model, MODEL_OUTPUT_PATH)

    print("\nPipeline completata con successo.")


if __name__ == "__main__":
    main()
