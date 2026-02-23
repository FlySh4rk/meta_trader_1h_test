import argparse
import io
import re
import sys
import unicodedata
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType


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


def normalize_text(value: object) -> str:
    if value is None:
        return ""
    text = str(value).strip().lower()
    text = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in text if not unicodedata.combining(ch))


def to_float_mt5(value: object) -> float:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return 0.0
    s = str(value).strip().replace("\xa0", "").replace(" ", "")
    if s == "":
        return 0.0
    s = s.replace(",", ".")
    s = re.sub(r"[^0-9.\-+]", "", s)
    if s in {"", "-", "+", ".", "-.", "+."}:
        return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0


def to_int_safe(value: object) -> Optional[int]:
    if value is None:
        return None
    s = str(value).strip()
    if s == "":
        return None
    s = re.sub(r"[^\d\-+]", "", s)
    if s in {"", "-", "+"}:
        return None
    try:
        return int(s)
    except ValueError:
        return None


def detect_encoding(csv_path: Path) -> str:
    encodings = ["utf-8-sig", "cp1252", "latin-1", "utf-16"]
    for enc in encodings:
        try:
            with open(csv_path, "r", encoding=enc, errors="strict") as f:
                f.read(4096)
            return enc
        except Exception:
            continue
    return "latin-1"


def find_deals_header(lines: List[str]) -> int:
    marker_keywords = ("affari", "deals")
    header_keywords = (
        "ordine",
        "order",
        "direzione",
        "direction",
        "profitto",
        "profit",
    )

    marker_idx = -1
    for i, line in enumerate(lines):
        norm = normalize_text(line)
        if any(k in norm for k in marker_keywords):
            marker_idx = i
            break

    search_start = marker_idx if marker_idx >= 0 else 0
    for i in range(search_start, min(len(lines), search_start + 120)):
        cols = [normalize_text(x) for x in lines[i].split(";")]
        joined = " ".join(cols)
        if all(k in joined for k in header_keywords[:3]) and ("profitto" in joined or "profit" in joined):
            return i

    for i, line in enumerate(lines):
        cols = [normalize_text(x) for x in line.split(";")]
        joined = " ".join(cols)
        if ("ordine" in joined or "order" in joined) and ("direzione" in joined or "direction" in joined) and (
            "profitto" in joined or "profit" in joined
        ):
            return i

    raise ValueError("Impossibile trovare header della sezione Affari/Deals nel report MT5.")


def map_column_indexes(header_row: List[str]) -> Dict[str, int]:
    normalized = [normalize_text(c) for c in header_row]

    def find_idx(candidates: Tuple[str, ...], required: bool = True) -> Optional[int]:
        for i, name in enumerate(normalized):
            if any(c in name for c in candidates):
                return i
        if required:
            raise ValueError(f"Colonna richiesta non trovata. Cercavo una di: {candidates}")
        return None

    return {
        "time": find_idx(("ora", "time"), required=False),
        "deal": find_idx(("affare", "deal"), required=False),
        "order": find_idx(("ordine", "order"), required=True),
        "direction": find_idx(("direzione", "direction"), required=True),
        "profit": find_idx(("profitto", "profit"), required=True),
        "swap": find_idx(("swap",), required=False),
        "commission": find_idx(("commission", "commissioni"), required=False),
        "position": find_idx(("posizione", "position"), required=False),
        "symbol": find_idx(("simbolo", "symbol"), required=False),
        "type": find_idx(("tipo", "type"), required=False),
    }


def parse_mt5_deals(report_path: Path) -> pd.DataFrame:
    try:
        encoding = detect_encoding(report_path)
        with open(report_path, "r", encoding=encoding, errors="replace") as f:
            lines = [ln.rstrip("\n\r") for ln in f]

        header_idx = find_deals_header(lines)
        header_raw = [h.strip() for h in lines[header_idx].split(";")]
        col_idx = map_column_indexes(header_raw)

        rows: List[Dict[str, object]] = []
        for raw in lines[header_idx + 1 :]:
            if raw.strip() == "":
                continue
            parts = [p.strip() for p in raw.split(";")]
            if len(parts) < 4:
                continue

            # Stop when a new section starts (single-word section title + mostly empty columns).
            filled = [p for p in parts if p != ""]
            if len(filled) <= 2 and len(parts) >= 6:
                first = normalize_text(parts[0]) if parts else ""
                if first and first not in {"in", "out"} and to_int_safe(first) is None:
                    break

            max_needed = max(i for i in col_idx.values() if i is not None)
            if len(parts) <= max_needed:
                continue

            order_val = to_int_safe(parts[col_idx["order"]])
            direction_val = normalize_text(parts[col_idx["direction"]])
            if order_val is None:
                continue
            if direction_val not in {"in", "out"}:
                if "entrata" in direction_val:
                    direction_val = "in"
                elif "uscita" in direction_val:
                    direction_val = "out"
                else:
                    continue

            profit_val = to_float_mt5(parts[col_idx["profit"]])
            swap_val = to_float_mt5(parts[col_idx["swap"]]) if col_idx["swap"] is not None else 0.0
            comm_val = to_float_mt5(parts[col_idx["commission"]]) if col_idx["commission"] is not None else 0.0
            net_profit_val = profit_val + swap_val + comm_val

            row = {
                "order": order_val,
                "direction": direction_val,
                "net_profit": net_profit_val,
                "profit": profit_val,
                "swap": swap_val,
                "commission": comm_val,
                "position_id": to_int_safe(parts[col_idx["position"]]) if col_idx["position"] is not None else None,
                "symbol": parts[col_idx["symbol"]] if col_idx["symbol"] is not None else "",
                "type": parts[col_idx["type"]] if col_idx["type"] is not None else "",
                "time": parts[col_idx["time"]] if col_idx["time"] is not None else "",
            }
            rows.append(row)

        if not rows:
            raise ValueError("Nessuna riga deals valida trovata nel report MT5.")

        deals_df = pd.DataFrame(rows)
        return deals_df
    except Exception as exc:
        raise RuntimeError(f"Errore durante il parsing del report MT5 '{report_path}': {exc}") from exc


def map_entry_ticket_to_target(deals_df: pd.DataFrame) -> pd.DataFrame:
    # Preferred: by explicit position_id if available.
    if "position_id" in deals_df.columns and deals_df["position_id"].notna().any():
        grouped = deals_df.groupby("position_id", dropna=True, sort=False)
        mapped_rows = []
        for pos_id, grp in grouped:
            g = grp.reset_index(drop=True)
            entry_candidates = g[g["direction"] == "in"]
            if entry_candidates.empty:
                continue
            entry_ticket = int(entry_candidates.iloc[0]["order"])
            out_rows = g[g["direction"] == "out"]
            if out_rows.empty:
                continue
            final_net = float(out_rows["net_profit"].sum())
            mapped_rows.append({"Ticket": entry_ticket, "final_net_profit": final_net, "y": int(final_net > 0)})
        if mapped_rows:
            return pd.DataFrame(mapped_rows).drop_duplicates(subset=["Ticket"], keep="first")

    # Fallback: sequential netting by symbol with running open positions (FIFO).
    mapped_rows = []
    working = deals_df.copy()
    if "symbol" not in working.columns:
        working["symbol"] = ""

    for symbol, grp in working.groupby("symbol", dropna=False, sort=False):
        open_entries: List[int] = []
        for _, row in grp.iterrows():
            direction = row["direction"]
            order = int(row["order"])
            net_p = float(row["net_profit"])
            if direction == "in":
                open_entries.append(order)
            elif direction == "out":
                if open_entries:
                    entry_ticket = open_entries.pop(0)
                    mapped_rows.append(
                        {
                            "Ticket": entry_ticket,
                            "final_net_profit": net_p,
                            "y": int(net_p > 0),
                        }
                    )

    if not mapped_rows:
        raise RuntimeError("Impossibile creare mapping Ticket->target dal report MT5 (nessuna coppia in/out valida).")

    return pd.DataFrame(mapped_rows).drop_duplicates(subset=["Ticket"], keep="first")


def load_feature_dataset(dataset_path: Path) -> pd.DataFrame:
    try:
        df = pd.read_csv(dataset_path)
    except Exception:
        # Fallback for locale variants.
        df = pd.read_csv(dataset_path, sep=";")

    missing = [c for c in ["Ticket", *FEATURE_COLUMNS] if c not in df.columns]
    if missing:
        raise ValueError(f"Colonne mancanti in dataset feature: {missing}")

    df = df.copy()
    df["Ticket"] = pd.to_numeric(df["Ticket"], errors="coerce").astype("Int64")
    for col in FEATURE_COLUMNS:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


def train_and_export(
    dataset_path: Path,
    report_path: Path,
    onnx_output_path: Path,
) -> None:
    deals_df = parse_mt5_deals(report_path)
    targets_df = map_entry_ticket_to_target(deals_df)
    features_df = load_feature_dataset(dataset_path)

    merged = features_df.merge(targets_df[["Ticket", "y"]], on="Ticket", how="left")
    merged = merged.dropna(subset=FEATURE_COLUMNS + ["y"]).copy()
    merged["y"] = merged["y"].astype(int)

    if merged.empty:
        raise RuntimeError("Merge vuoto: nessun Ticket del dataset feature ha target nel report MT5.")

    print(f"Merged dataset shape: {merged.shape}")

    X = merged[FEATURE_COLUMNS].astype(np.float32)
    y = merged["y"].astype(int)

    split_idx = int(len(merged) * 0.8)
    if split_idx <= 0 or split_idx >= len(merged):
        raise RuntimeError(
            f"Split cronologico non valido. Righe totali={len(merged)}, split_idx={split_idx}."
        )

    X_train, X_test = X.iloc[:split_idx], X.iloc[split_idx:]
    y_train, y_test = y.iloc[:split_idx], y.iloc[split_idx:]

    model = RandomForestClassifier(
        n_estimators=100,
        max_depth=5,
        min_samples_leaf=2,
        class_weight="balanced",
        random_state=42,
    )
    model.fit(X_train, y_train)

    y_pred = model.predict(X_test)
    acc = accuracy_score(y_test, y_pred)
    print(f"Test accuracy: {acc:.6f}")
    print("Classification report:")
    print(classification_report(y_test, y_pred, digits=4))

    # --- INIZIO DELLA MODIFICA NUCLEARE ---
    initial_type = [("float_input", FloatTensorType([None, 9]))]
    
    # 1. Aggiungiamo zipmap: False per rimuovere le strutture a dizionario complesse
    onnx_model = convert_sklearn(
        model, 
        initial_types=initial_type, 
        target_opset=12,
        options={type(model): {'zipmap': False}}
    )

    # 2. Amputiamo fisicamente il secondo output (le probabilità) dal modello
    onnx_model.graph.output.pop()
    # --- FINE DELLA MODIFICA NUCLEARE ---

    with open(onnx_output_path, "wb") as f:
        f.write(onnx_model.SerializeToString())
    print(f"ONNX model NUCLEARE salvato in: {onnx_output_path}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train RF model with MT5 ground-truth PnL and export to ONNX."
    )
    parser.add_argument(
        "--dataset",
        type=Path,
        default=Path("MT5_ML_Dataset.csv"),
        help="Percorso a MT5_ML_Dataset.csv",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=Path("ReportTester-101668240_backtest_gpusd.csv"),
        help="Percorso al report MT5 backtest CSV",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("rf_gbpusd_h1.onnx"),
        help="Percorso file ONNX di output",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        train_and_export(
            dataset_path=args.dataset,
            report_path=args.report,
            onnx_output_path=args.output,
        )
        return 0
    except Exception as exc:
        print(f"[ERRORE] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())