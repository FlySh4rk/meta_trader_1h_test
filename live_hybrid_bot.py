"""
Live Hybrid Bot (Phase 3 - Hybrid Execution)

Master daemon Python che:
1) attende la chiusura di ogni candela H1,
2) calcola le feature come in Phase 2,
3) applica la logica base (trend/range),
4) filtra il segnale con Random Forest,
5) invia ordini a MT5 con SL/TP server-side.
"""

from __future__ import annotations

import logging
from logging.handlers import RotatingFileHandler
import math
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import joblib
import MetaTrader5 as mt5
import numpy as np
import pandas as pd


# --- Config principale ---
SYMBOL = "EURUSD"
TIMEFRAME = mt5.TIMEFRAME_H1
BARS_TO_FETCH = 250
MODEL_PATH = Path("rf_model_eurusd_h1.pkl")
LOG_PATH = Path("live_hybrid_bot.log")
MAGIC_NUMBER = 33001
MAX_SPREAD_POINTS = 20
RISK_PCT_FREE_MARGIN = 0.01
DEVIATION_POINTS = 20

# Feature order: deve matchare ESATTAMENTE il training.
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


@dataclass
class Signal:
    side: str  # "buy" | "sell"
    strategy: str  # "trend" | "range"
    row: pd.Series


def setup_logger() -> logging.Logger:
    logger = logging.getLogger("live_hybrid_bot")
    logger.setLevel(logging.INFO)
    logger.propagate = False

    if logger.handlers:
        return logger

    formatter = logging.Formatter(
        "%(asctime)s | %(levelname)s | %(name)s | %(message)s"
    )
    file_handler = RotatingFileHandler(
        LOG_PATH,
        maxBytes=2_000_000,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)

    stream_handler = logging.StreamHandler()
    stream_handler.setLevel(logging.INFO)
    stream_handler.setFormatter(formatter)

    logger.addHandler(file_handler)
    logger.addHandler(stream_handler)
    return logger


def initialize_mt5(logger: logging.Logger) -> None:
    try:
        if not mt5.initialize():
            raise RuntimeError(f"mt5.initialize() failed: {mt5.last_error()}")

        info = mt5.symbol_info(SYMBOL)
        if info is None:
            raise RuntimeError(f"Simbolo non disponibile: {SYMBOL}")

        if not info.visible:
            ok = mt5.symbol_select(SYMBOL, True)
            if not ok:
                raise RuntimeError(f"Impossibile attivare simbolo: {SYMBOL}")

        logger.info("MT5 inizializzato correttamente per %s", SYMBOL)
    except Exception:
        try:
            mt5.shutdown()
        except Exception:
            pass
        raise


def load_model(logger: logging.Logger) -> Any:
    if not MODEL_PATH.exists():
        raise FileNotFoundError(f"Modello non trovato: {MODEL_PATH.resolve()}")
    model = joblib.load(MODEL_PATH)
    logger.info("Modello caricato da %s", MODEL_PATH.resolve())
    return model


def calculate_atr_wilder(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high = df["high"]
    low = df["low"]
    close = df["close"]
    prev_close = close.shift(1)

    tr = pd.concat(
        [(high - low), (high - prev_close).abs(), (low - prev_close).abs()],
        axis=1,
    ).max(axis=1)

    atr = pd.Series(np.nan, index=df.index, dtype=float)
    if len(tr) < period:
        return atr

    first_idx = period - 1
    atr.iloc[first_idx] = tr.iloc[:period].mean()
    for i in range(first_idx + 1, len(tr)):
        atr.iloc[i] = ((atr.iloc[i - 1] * (period - 1)) + tr.iloc[i]) / period
    return atr


def calculate_rsi_wilder(close: pd.Series, period: int = 14) -> pd.Series:
    delta = close.diff()
    gain = delta.where(delta > 0, 0.0)
    loss = -delta.where(delta < 0, 0.0)

    avg_gain = gain.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()

    rs = avg_gain / avg_loss.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))
    return rsi


def get_data(logger: logging.Logger) -> pd.DataFrame:
    rates = mt5.copy_rates_from_pos(SYMBOL, TIMEFRAME, 0, BARS_TO_FETCH)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"Nessuna barra ricevuta da MT5 per {SYMBOL} H1.")

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df.sort_values("time", inplace=True)
    df.reset_index(drop=True, inplace=True)

    # Indicatori base.
    df["ema_220"] = df["close"].ewm(span=220, adjust=False).mean()
    raw_slope = (df["ema_220"] - df["ema_220"].shift(20)) / 20.0

    df["atr_14"] = calculate_atr_wilder(df, period=14)

    bb_mid = df["close"].rolling(24, min_periods=24).mean()
    bb_std = df["close"].rolling(24, min_periods=24).std(ddof=0)
    df["bb_middle"] = bb_mid
    df["bb_upper"] = bb_mid + (2.3 * bb_std)
    df["bb_lower"] = bb_mid - (2.3 * bb_std)

    # Donchian breakout su storico precedente (esclude barra corrente).
    df["donchian_high_prev"] = df["high"].shift(1).rolling(24, min_periods=24).max()
    df["donchian_low_prev"] = df["low"].shift(1).rolling(24, min_periods=24).min()

    df["rsi_14"] = calculate_rsi_wilder(df["close"], period=14)

    # Feature Phase 2 / ML.
    df["slope_normalized"] = raw_slope / df["atr_14"].replace(0, np.nan)
    df["dist_ema_atr"] = (df["close"] - df["ema_220"]) / df["atr_14"].replace(0, np.nan)
    bb_width = (df["bb_upper"] - df["bb_lower"]).replace(0, np.nan)
    df["bb_position"] = (df["close"] - df["bb_lower"]) / bb_width
    df["ATR_normalized"] = df["atr_14"] / df["close"].replace(0, np.nan)
    df["HourOfDay"] = df["time"].dt.hour.astype(float)
    df["DayOfWeek"] = df["time"].dt.dayofweek.astype(float)

    # Manteniamo tutto: il check segnali usa la candela chiusa [-2].
    logger.info("Barre H1 caricate: %d", len(df))
    return df


def check_signals(df: pd.DataFrame) -> Signal | None:
    # Candela chiusa più recente (ultima è in formazione).
    if len(df) < 50:
        return None

    row = df.iloc[-2]
    if row[["slope_normalized", "atr_14", "bb_upper", "bb_lower", "rsi_14"]].isna().any():
        return None

    slope = float(row["slope_normalized"])
    close = float(row["close"])
    bb_lower = float(row["bb_lower"])
    bb_upper = float(row["bb_upper"])
    rsi = float(row["rsi_14"])
    d_high_prev = float(row["donchian_high_prev"])
    d_low_prev = float(row["donchian_low_prev"])

    # Trend gates.
    trend_long = slope > 0.05 and close > d_high_prev
    trend_short = slope < -0.05 and close < d_low_prev

    # Range gates.
    flat = -0.025 <= slope <= 0.025
    range_long = flat and close <= bb_lower and rsi <= 30
    range_short = flat and close >= bb_upper and rsi >= 70

    if trend_long:
        return Signal(side="buy", strategy="trend", row=row)
    if trend_short:
        return Signal(side="sell", strategy="trend", row=row)
    if range_long:
        return Signal(side="buy", strategy="range", row=row)
    if range_short:
        return Signal(side="sell", strategy="range", row=row)
    return None


def build_feature_row(signal: Signal) -> pd.DataFrame:
    row = signal.row
    features = {
        "slope_normalized": float(row["slope_normalized"]),
        "rsi_14": float(row["rsi_14"]),
        "HourOfDay": float(row["HourOfDay"]),
        "DayOfWeek": float(row["DayOfWeek"]),
        "ATR_normalized": float(row["ATR_normalized"]),
        "dist_ema_atr": float(row["dist_ema_atr"]),
        "bb_position": float(row["bb_position"]),
        "is_trend": 1 if signal.strategy == "trend" else 0,
        "is_long": 1 if signal.side == "buy" else 0,
    }
    return pd.DataFrame([features], columns=FEATURE_COLUMNS)


def clamp_volume(volume: float, info: Any) -> float:
    vmin = info.volume_min
    vmax = info.volume_max
    step = info.volume_step

    if step <= 0:
        return max(vmin, min(volume, vmax))

    steps = math.floor((volume - vmin) / step)
    adjusted = vmin + max(0, steps) * step
    adjusted = max(vmin, min(adjusted, vmax))

    step_digits = 0
    if "." in f"{step:.10f}":
        step_digits = len(f"{step:.10f}".rstrip("0").split(".")[-1])
    return round(adjusted, step_digits)


def calc_position_size(
    logger: logging.Logger,
    symbol_info: Any,
    entry_price: float,
    sl_price: float,
) -> float:
    account = mt5.account_info()
    if account is None:
        raise RuntimeError(f"account_info() failed: {mt5.last_error()}")

    risk_money = account.margin_free * RISK_PCT_FREE_MARGIN
    if risk_money <= 0:
        raise RuntimeError("Margin free non valida per risk sizing.")

    sl_distance = abs(entry_price - sl_price)
    if sl_distance <= 0:
        raise RuntimeError("SL distance non valida (<=0).")

    tick_size = symbol_info.trade_tick_size
    tick_value = symbol_info.trade_tick_value
    if tick_size <= 0 or tick_value <= 0:
        raise RuntimeError("trade_tick_size/trade_tick_value non validi.")

    loss_per_lot = (sl_distance / tick_size) * tick_value
    if loss_per_lot <= 0:
        raise RuntimeError("loss_per_lot non valido.")

    raw_volume = risk_money / loss_per_lot
    volume = clamp_volume(raw_volume, symbol_info)
    logger.info(
        "Sizing -> risk_money=%.2f, loss_per_lot=%.5f, raw=%.5f, final=%.2f",
        risk_money,
        loss_per_lot,
        raw_volume,
        volume,
    )
    return volume


def execute_trade(logger: logging.Logger, signal: Signal) -> None:
    try:
        info = mt5.symbol_info(SYMBOL)
        if info is None:
            logger.error("symbol_info() None per %s", SYMBOL)
            return

        if info.trade_mode == mt5.SYMBOL_TRADE_MODE_DISABLED:
            logger.warning("Trade mode disabilitato per %s", SYMBOL)
            return

        spread_points = info.spread
        if spread_points is None or spread_points > MAX_SPREAD_POINTS:
            logger.info(
                "Spread troppo alto (%s punti) > %d. Skip trade.",
                spread_points,
                MAX_SPREAD_POINTS,
            )
            return

        tick = mt5.symbol_info_tick(SYMBOL)
        if tick is None:
            logger.error("symbol_info_tick() None: %s", mt5.last_error())
            return

        atr = float(signal.row["atr_14"])
        bb_middle = float(signal.row["bb_middle"])
        if np.isnan(atr) or atr <= 0:
            logger.warning("ATR non valida per execution.")
            return

        if signal.side == "buy":
            order_type = mt5.ORDER_TYPE_BUY
            entry_price = float(tick.ask)
            sl_distance = 3.25 * atr if signal.strategy == "trend" else 1.0 * atr
            sl_price = entry_price - sl_distance
            tp_price = bb_middle
        else:
            order_type = mt5.ORDER_TYPE_SELL
            entry_price = float(tick.bid)
            sl_distance = 3.25 * atr if signal.strategy == "trend" else 1.0 * atr
            sl_price = entry_price + sl_distance
            tp_price = bb_middle

        # Validazione base TP lato corretto; evita rifiuti banali lato server.
        if signal.side == "buy" and tp_price <= entry_price:
            logger.info(
                "TP non valido per BUY (tp=%.5f <= entry=%.5f). Skip.",
                tp_price,
                entry_price,
            )
            return
        if signal.side == "sell" and tp_price >= entry_price:
            logger.info(
                "TP non valido per SELL (tp=%.5f >= entry=%.5f). Skip.",
                tp_price,
                entry_price,
            )
            return

        volume = calc_position_size(logger, info, entry_price, sl_price)
        if volume < info.volume_min:
            logger.info(
                "Volume %.2f sotto minimo %.2f: skip trade.",
                volume,
                info.volume_min,
            )
            return

        # Failsafe: evita stacking di posizioni sullo stesso simbolo.
        open_positions = mt5.positions_get(symbol=SYMBOL)
        if open_positions is not None and len(open_positions) > 0:
            logger.info("Posizione già aperta su %s, skip nuova entry.", SYMBOL)
            return

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": SYMBOL,
            "volume": volume,
            "type": order_type,
            "price": entry_price,
            "sl": sl_price,
            "tp": tp_price,
            "deviation": DEVIATION_POINTS,
            "magic": MAGIC_NUMBER,
            "comment": f"hybrid_{signal.strategy}_{signal.side}",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }

        result = mt5.order_send(request)
        if result is None:
            logger.error("order_send() None: %s", mt5.last_error())
            return

        logger.info(
            "order_send retcode=%s | order=%s | deal=%s | price=%.5f | sl=%.5f | tp=%.5f | vol=%.2f",
            result.retcode,
            getattr(result, "order", None),
            getattr(result, "deal", None),
            entry_price,
            sl_price,
            tp_price,
            volume,
        )
    except Exception as exc:
        logger.exception("Errore in execute_trade(): %s", exc)


def seconds_to_next_hour_plus_2s(now_utc: datetime | None = None) -> float:
    now_utc = now_utc or datetime.now(timezone.utc)
    next_hour = now_utc.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
    target = next_hour + timedelta(seconds=2)
    return max(1.0, (target - now_utc).total_seconds())


def process_cycle(logger: logging.Logger, model: Any, last_processed_time: pd.Timestamp | None) -> pd.Timestamp | None:
    try:
        df = get_data(logger)
        closed_row = df.iloc[-2]
        closed_time = closed_row["time"]

        # Evita doppia elaborazione della stessa candela.
        if last_processed_time is not None and closed_time <= last_processed_time:
            logger.info("Candela %s già processata. Nessuna azione.", closed_time)
            return last_processed_time

        signal = check_signals(df)
        if signal is None:
            logger.info("Nessun Base Signal su candela chiusa %s", closed_time)
            return closed_time

        x = build_feature_row(signal)
        if hasattr(model, "feature_names_in_"):
            x = x.reindex(columns=list(model.feature_names_in_))
        else:
            x = x[FEATURE_COLUMNS]

        if x.isna().any().any():
            logger.warning("Feature con NaN su %s, skip.", closed_time)
            return closed_time

        pred = int(model.predict(x)[0])
        logger.info(
            "BaseSignal=%s/%s | Candle=%s | Prediction=%d",
            signal.strategy,
            signal.side,
            closed_time,
            pred,
        )

        if pred == 1:
            execute_trade(logger, signal)
        else:
            logger.info("Trade filtrato dal modello (pred=0).")

        return closed_time
    except Exception as exc:
        logger.exception("Errore in process_cycle(): %s", exc)
        return last_processed_time


def main() -> None:
    logger = setup_logger()
    logger.info("Avvio live_hybrid_bot...")

    model = None
    last_processed_time: pd.Timestamp | None = None

    try:
        initialize_mt5(logger)
        model = load_model(logger)

        while True:
            sleep_seconds = seconds_to_next_hour_plus_2s()
            logger.info("Sleep %.2f sec fino a chiusura prossima H1 + 2s", sleep_seconds)
            time.sleep(sleep_seconds)
            last_processed_time = process_cycle(logger, model, last_processed_time)
    except KeyboardInterrupt:
        logger.info("Arresto manuale ricevuto (KeyboardInterrupt).")
    except Exception as exc:
        logger.exception("Errore fatale nel main loop: %s", exc)
    finally:
        try:
            mt5.shutdown()
        except Exception:
            pass
        logger.info("MT5 shutdown completato.")


if __name__ == "__main__":
    main()

