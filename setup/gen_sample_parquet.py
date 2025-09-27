#!/usr/bin/env python3
"""
Generate a small Parquet file with schema:
  id:int, name:string, value:double
Defaults: 100 rows -> ./sample.parquet

Usage:
  python gen_sample_parquet.py [--rows 1000] [--out sample.parquet] [--seed 42]
"""
import argparse, random, string
from pathlib import Path

import pandas as pd

def rand_name(n=6):
    return "".join(random.choices(string.ascii_lowercase, k=n))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=100, help="number of rows")
    ap.add_argument("--out", type=str, default="sample.parquet", help="output file path")
    ap.add_argument("--seed", type=int, default=42, help="random seed")
    args = ap.parse_args()

    random.seed(args.seed)
    rows = [{"id": i, "name": rand_name(), "value": round(random.random()*100, 3)}
            for i in range(1, args.rows + 1)]

    df = pd.DataFrame(rows)
    # dtype hints (optional; Parquet will infer correctly from pandas types)
    df = df.astype({"id": "int32", "name": "string", "value": "float64"})

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    # Use pyarrow engine to write Parquet
    df.to_parquet(out, engine="pyarrow", index=False)
    print(f"Wrote {out} with {len(df):,} rows.")

if __name__ == "__main__":
    main()
