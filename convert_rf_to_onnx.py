"""
Converti un modello scikit-learn Random Forest (.pkl) in ONNX (.onnx)
per integrazione diretta in MetaTrader 5 (MQL5).

Uso:
    python convert_rf_to_onnx.py
"""

from pathlib import Path

import joblib
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType


# Ordine CRITICO delle feature attese dal modello.
# MQL5 deve passare l'array in questo ordine esatto.
FEATURE_ORDER = [
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


def main() -> None:
    """Carica il modello .pkl, lo converte in ONNX e salva il file risultante."""
    pkl_path = Path("rf_model_eurusd_h1.pkl")
    onnx_path = Path("rf_eurusd_h1.onnx")

    if not pkl_path.exists():
        raise FileNotFoundError(
            f"File modello non trovato: {pkl_path.resolve()}\n"
            "Assicurati di eseguire lo script nella cartella corretta."
        )

    # 1) Carica il modello addestrato in formato pickle.
    model = joblib.load(pkl_path)

    # 2) Definisci il tipo input ONNX: batch variabile, 9 feature float.
    initial_types = [("float_input", FloatTensorType([None, 9]))]

    # 3) Converti il modello sklearn in ONNX.
    # target_opset=12 e' una scelta compatibile con runtime ONNX standard.
    onnx_model = convert_sklearn(
        model,
        initial_types=initial_types,
        target_opset=12,
    )

    # 4) Salva il modello ONNX serializzato su file.
    onnx_path.write_bytes(onnx_model.SerializeToString())

    # 5) Stampa a console l'ordine ESATTO delle feature (requisito MT5).
    print("\n=== FEATURE ORDER (MQL5 -> ONNX) ===")
    for idx, feature_name in enumerate(FEATURE_ORDER, start=1):
        print(f"{idx}. {feature_name}")
    print("\nAs list:", FEATURE_ORDER)
    print(f"\nConversione completata: {onnx_path.resolve()}")


if __name__ == "__main__":
    main()
