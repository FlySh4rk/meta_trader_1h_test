#!/usr/bin/env python3
"""
Phase 2 - Data Pipeline & Regime Analysis

Script standalone per:
1) connettersi a MetaTrader 5;
2) scaricare storico EURUSD H1 (5 anni, con fallback a 50.000 barre);
3) replicare la matematica del filtro regime MQL5:
   - EMA(220)
   - slope su 20 periodi: (EMA_t - EMA_{t-20}) / 20
   - ATR(14) (Wilder by default)
   - slope_normalized = raw_slope / ATR
4) pulire NaN;
5) analizzare distribuzione con quantili e grafico Histogram+KDE.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import sys

import matplotlib.pyplot as plt
import MetaTrader5 as mt5
import numpy as np
import pandas as pd
import seaborn as sns


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Regime analysis H1 per EURUSD replicando logica MQL5."
    )
    parser.add_argument("--symbol", type=str, default="EURUSD", help="Simbolo MT5.")
    parser.add_argument(
        "--years",
        type=int,
        default=5,
        help="Anni di storico da scaricare con copy_rates_range.",
    )
    parser.add_argument(
        "--bars-fallback",
        type=int,
        default=50_000,
        help="Numero barre fallback se copy_rates_range non restituisce dati.",
    )
    parser.add_argument(
        "--ema-period", type=int, default=220, help="Periodo EMA (MQL5)."
    )
    parser.add_argument(
        "--slope-lookback", type=int, default=20, help="Lookback slope (MQL5)."
    )
    parser.add_argument(
        "--atr-period", type=int, default=14, help="Periodo ATR (MQL5)."
    )
    parser.add_argument(
        "--atr-method",
        type=str,
        choices=["wilder", "sma"],
        default="wilder",
        help="Metodo ATR: Wilder (default) o rolling SMA.",
    )
    parser.add_argument(
        "--save-plot",
        type=str,
        default="slope_normalized_distribution.png",
        help="Path file immagine da salvare.",
    )
    return parser.parse_args()


def initialize_mt5() -> None:
    if not mt5.initialize():
        error = mt5.last_error()
        raise RuntimeError(f"Impossibile inizializzare MetaTrader5. last_error={error}")


def fetch_h1_data(symbol: str, years: int, bars_fallback: int) -> pd.DataFrame:
    utc_to = datetime.now(timezone.utc)
    utc_from = utc_to - timedelta(days=365 * years)

    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_H1, utc_from, utc_to)

    # Fallback robusto: se il broker non restituisce 5 anni completi via range,
    # prova direttamente l'ultima finestra di N barre.
    if rates is None or len(rates) == 0:
        rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_H1, 0, bars_fallback)

    if rates is None or len(rates) == 0:
        raise RuntimeError(
            f"Nessun dato ricevuto da MT5 per {symbol} su TIMEFRAME_H1."
        )

    df = pd.DataFrame(rates)
    if "time" not in df.columns:
        raise RuntimeError("Dati MT5 senza colonna 'time'.")

    # Converte epoch seconds -> datetime UTC.
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df.sort_values("time", inplace=True)
    df.reset_index(drop=True, inplace=True)

    return df


def calculate_atr(
    df: pd.DataFrame, period: int = 14, method: str = "wilder"
) -> pd.Series:
    high = df["high"]
    low = df["low"]
    close = df["close"]
    prev_close = close.shift(1)

    tr_components = pd.concat(
        [
            (high - low),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    )
    true_range = tr_components.max(axis=1)

    if method == "sma":
        return true_range.rolling(window=period, min_periods=period).mean()

    # Wilder esatto:
    # ATR_t = (ATR_{t-1} * (period-1) + TR_t) / period
    atr = pd.Series(np.nan, index=df.index, dtype=float)
    if len(true_range) < period:
        return atr

    first_atr_idx = period - 1
    atr.iloc[first_atr_idx] = true_range.iloc[:period].mean()

    for i in range(first_atr_idx + 1, len(true_range)):
        atr.iloc[i] = ((atr.iloc[i - 1] * (period - 1)) + true_range.iloc[i]) / period

    return atr


def calculate_regime_features(
    df: pd.DataFrame,
    ema_period: int,
    slope_lookback: int,
    atr_period: int,
    atr_method: str,
) -> pd.DataFrame:
    out = df.copy()

    # EMA MQL5 equivalente con adjust=False.
    out["ema"] = out["close"].ewm(span=ema_period, adjust=False).mean()

    # slope MQL5: (EMA_t - EMA_{t-lookback}) / lookback
    out["price_diff"] = out["ema"] - out["ema"].shift(slope_lookback)
    out["raw_slope"] = out["price_diff"] / float(slope_lookback)

    # ATR(14)
    out["atr"] = calculate_atr(out, period=atr_period, method=atr_method)

    # In MQL5 slope e ATR vengono entrambi scalati per _Point:
    # (raw_slope/_Point) / (atr/_Point) = raw_slope/atr
    out["slope_normalized"] = out["raw_slope"] / out["atr"]

    out = out.dropna().reset_index(drop=True)
    return out


def print_quantiles(series: pd.Series) -> None:
    req = {
        "5%": 0.05,
        "10%": 0.10,
        "20%": 0.20,
        "80%": 0.80,
        "90%": 0.90,
        "95%": 0.95,
    }

    print("\nQuantili richiesti per slope_normalized:")
    for label, q in req.items():
        value = series.quantile(q)
        print(f"  {label:>3} : {value: .6f}")

    # Quantili extra per suggerire soglie operative.
    q15 = series.quantile(0.15)
    q30 = series.quantile(0.30)
    q70 = series.quantile(0.70)
    q85 = series.quantile(0.85)

    print("\nSuggerimento soglie (data-driven):")
    print(
        f"  Strong Trend (bottom/top 15%): slope_normalized <= {q15: .6f}"
        f"  OR  >= {q85: .6f}"
    )
    print(
        f"  Flat/Noise (middle 40%): {q30: .6f} <= slope_normalized <= {q70: .6f}"
    )


def plot_distribution(series: pd.Series, save_path: str) -> None:
    sns.set_theme(style="whitegrid", context="talk")
    fig, ax = plt.subplots(figsize=(14, 8))

    sns.histplot(
        series,
        bins=120,
        kde=True,
        stat="density",
        color="steelblue",
        edgecolor="white",
        linewidth=0.3,
        alpha=0.70,
        ax=ax,
    )

    q15 = series.quantile(0.15)
    q30 = series.quantile(0.30)
    q70 = series.quantile(0.70)
    q85 = series.quantile(0.85)

    ax.axvline(q15, color="crimson", linestyle="--", linewidth=1.8, label="Q15")
    ax.axvline(q85, color="crimson", linestyle="--", linewidth=1.8, label="Q85")
    ax.axvline(q30, color="darkorange", linestyle=":", linewidth=1.8, label="Q30")
    ax.axvline(q70, color="darkorange", linestyle=":", linewidth=1.8, label="Q70")

    ax.set_title("Distribuzione slope_normalized (EMA220 slope/ATR14) - EURUSD H1")
    ax.set_xlabel("slope_normalized")
    ax.set_ylabel("Density")
    ax.legend()

    fig.tight_layout()
    fig.savefig(save_path, dpi=170)
    print(f"\nGrafico salvato in: {save_path}")

    # Mostra il grafico in esecuzione interattiva.
    plt.show()


def main() -> int:
    args = parse_args()

    connected = False
    try:
        initialize_mt5()
        connected = True

        symbol_info = mt5.symbol_info(args.symbol)
        if symbol_info is None:
            raise RuntimeError(
                f"Il simbolo {args.symbol} non è disponibile sul terminale MT5."
            )

        if not symbol_info.visible:
            if not mt5.symbol_select(args.symbol, True):
                raise RuntimeError(f"Impossibile attivare il simbolo {args.symbol}.")

        df = fetch_h1_data(args.symbol, args.years, args.bars_fallback)
        print(f"Dati scaricati: {len(df):,} barre H1 per {args.symbol}.")
        print(f"Range temporale: {df['time'].iloc[0]} -> {df['time'].iloc[-1]}")

        features = calculate_regime_features(
            df=df,
            ema_period=args.ema_period,
            slope_lookback=args.slope_lookback,
            atr_period=args.atr_period,
            atr_method=args.atr_method,
        )

        if features.empty:
            raise RuntimeError("Nessun dato dopo dropna(). Controllare periodi/serie.")

        print(f"Righe valide dopo feature engineering + dropna(): {len(features):,}")
        print_quantiles(features["slope_normalized"])
        plot_distribution(features["slope_normalized"], save_path=args.save_plot)

        return 0

    except Exception as exc:
        print(f"\nERRORE: {exc}", file=sys.stderr)
        return 1

    finally:
        # Shutdown pulito della connessione MT5.
        if connected:
            mt5.shutdown()
            print("\nConnessione MT5 chiusa correttamente.")


if __name__ == "__main__":
    raise SystemExit(main())

