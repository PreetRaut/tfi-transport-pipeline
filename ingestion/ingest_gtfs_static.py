"""
01_ingest_gtfs_static.py
━━━━━━━━━━━━━━━━━━━━━━━━
Downloads the NTA GTFS Static schedule ZIP from Transport for Ireland,
parses the relevant feed files, validates schemas, and uploads each
table to Azure Data Lake Storage Gen2 (bronze container) as Parquet.

Source  : https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip
Docs    : https://gtfs.org/documentation/schedule/reference/
Licence : Public Sector Information (PSI) Licence

Files extracted
───────────────
  agency.txt       → bronze/gtfs_static/agency/
  routes.txt       → bronze/gtfs_static/routes/
  trips.txt        → bronze/gtfs_static/trips/
  stops.txt        → bronze/gtfs_static/stops/
  stop_times.txt   → bronze/gtfs_static/stop_times/
  calendar.txt     → bronze/gtfs_static/calendar/
  calendar_dates.txt → bronze/gtfs_static/calendar_dates/

Usage
─────
  python ingestion/01_ingest_gtfs_static.py [--local-only]
  --local-only  : skip ADLS upload (useful for local dev / CI)
"""

import argparse
import io
import logging
import os
import sys
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import requests
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ── Constants ────────────────────────────────────────────────────────────────
GTFS_STATIC_URL = (
    "https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip"
)
LOCAL_CACHE_PATH = Path("data/sample/gtfs_static_latest.zip")
ADLS_CONTAINER   = "bronze"

# Column dtype maps — cast on read to avoid mixed-type warnings
DTYPE_MAPS = {
    "agency":    {"agency_id": str, "agency_name": str, "agency_url": str,
                  "agency_timezone": str, "agency_lang": str},
    "routes":    {"route_id": str, "agency_id": str, "route_short_name": str,
                  "route_long_name": str, "route_type": "Int64", "route_color": str,
                  "route_text_color": str, "route_desc": str},
    "trips":     {"route_id": str, "service_id": str, "trip_id": str,
                  "trip_headsign": str, "direction_id": "Int64", "shape_id": str,
                  "block_id": str},
    "stops":     {"stop_id": str, "stop_name": str, "stop_lat": float,
                  "stop_lon": float, "stop_code": str, "zone_id": str,
                  "parent_station": str, "location_type": "Int64",
                  "wheelchair_boarding": "Int64"},
    "stop_times": {"trip_id": str, "arrival_time": str, "departure_time": str,
                   "stop_id": str, "stop_sequence": "Int64",
                   "pickup_type": "Int64", "drop_off_type": "Int64",
                   "shape_dist_traveled": float, "timepoint": "Int64"},
    "calendar":  {"service_id": str, "monday": "Int64", "tuesday": "Int64",
                  "wednesday": "Int64", "thursday": "Int64", "friday": "Int64",
                  "saturday": "Int64", "sunday": "Int64",
                  "start_date": str, "end_date": str},
    "calendar_dates": {"service_id": str, "date": str, "exception_type": "Int64"},
}


def download_gtfs_zip(url: str, cache_path: Path) -> bytes:
    """Download GTFS ZIP, cache locally to avoid repeated large downloads."""
    cache_path.parent.mkdir(parents=True, exist_ok=True)

    # Use cache if it exists and is less than 24 hours old
    if cache_path.exists():
        age_hours = (time.time() - cache_path.stat().st_mtime) / 3600
        if age_hours < 24:
            log.info("Using cached GTFS ZIP (%.1f hours old)", age_hours)
            return cache_path.read_bytes()

    log.info("Downloading GTFS Static from %s", url)
    start = time.time()
    resp  = requests.get(url, timeout=120, stream=True)
    resp.raise_for_status()

    data  = resp.content
    elapsed = time.time() - start
    log.info("Downloaded %.1f MB in %.1fs", len(data) / 1_048_576, elapsed)

    cache_path.write_bytes(data)
    log.info("Cached to %s", cache_path)
    return data


def parse_gtfs_file(zf: zipfile.ZipFile, filename: str, dtypes: dict) -> pd.DataFrame:
    """Read a single .txt file from the ZIP into a DataFrame."""
    txt_name = f"{filename}.txt"
    available = zf.namelist()

    # Some feeds nest files in a subdirectory
    candidates = [n for n in available if n.endswith(txt_name)]
    if not candidates:
        log.warning("  %s not found in ZIP (available: %s)", txt_name, available[:5])
        return pd.DataFrame()

    with zf.open(candidates[0]) as f:
        df = pd.read_csv(
            f,
            dtype=dtypes,
            low_memory=False,
            on_bad_lines="warn",
        )

    # Strip BOM from column names (common in GTFS files)
    df.columns = [c.lstrip("\ufeff").strip() for c in df.columns]
    # Add audit column
    df["_ingested_at"] = datetime.now(timezone.utc).isoformat()
    log.info("  %-20s  %6d rows  %d cols", txt_name, len(df), len(df.columns))
    return df


def validate_dataframe(name: str, df: pd.DataFrame) -> bool:
    """Run basic quality checks. Returns True if passes."""
    if df.empty:
        log.error("  FAIL: %s is empty", name)
        return False

    null_pct = df.isnull().mean().max() * 100
    if null_pct > 50:
        log.warning("  WARN: %s has columns with >50%% nulls", name)

    log.info("  PASS: %s  (nulls max %.1f%%)", name, null_pct)
    return True


def upload_parquet_to_adls(df: pd.DataFrame, folder: str, filename: str) -> bool:
    """Upload DataFrame as Parquet to ADLS Gen2. Returns False on skip."""
    account = os.getenv("ADLS_ACCOUNT_NAME")
    key     = os.getenv("ADLS_ACCOUNT_KEY")

    if not account or not key:
        log.warning("  ADLS credentials not set — skipping upload of %s", filename)
        return False

    try:
        from azure.storage.filedatalake import DataLakeServiceClient
    except ImportError:
        log.warning("  azure-storage-file-datalake not installed — skipping upload")
        return False

    svc = DataLakeServiceClient(
        account_url=f"https://{account}.dfs.core.windows.net",
        credential=key,
    )
    fs = svc.get_file_system_client(ADLS_CONTAINER)

    # Create container if needed
    try:
        fs.create_file_system()
    except Exception:
        pass

    buf = io.BytesIO()
    df.to_parquet(buf, index=False, engine="pyarrow")
    buf.seek(0)
    data = buf.read()

    remote_path = f"gtfs_static/{folder}/{filename}"
    fc = fs.get_file_client(remote_path)
    fc.upload_data(data, overwrite=True)

    log.info("  Uploaded → abfss://%s@%s.dfs.core.windows.net/%s  (%.1f KB)",
             ADLS_CONTAINER, account, remote_path, len(data) / 1024)
    return True


def save_local_sample(df: pd.DataFrame, name: str, n: int = 500) -> None:
    """Save a small CSV sample for local inspection / GitHub."""
    out = Path(f"data/sample/{name}_sample.csv")
    out.parent.mkdir(parents=True, exist_ok=True)
    df.head(n).to_csv(out, index=False)
    log.info("  Sample saved → %s", out)


def main(local_only: bool = False) -> None:
    log.info("=" * 60)
    log.info("  TFI GTFS Static Ingestion Pipeline")
    log.info("  %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    log.info("=" * 60)

    # 1. Download
    raw_bytes = download_gtfs_zip(GTFS_STATIC_URL, LOCAL_CACHE_PATH)

    # 2. Parse
    results = {}
    with zipfile.ZipFile(io.BytesIO(raw_bytes)) as zf:
        log.info("\nParsing GTFS files…")
        for feed_name, dtypes in DTYPE_MAPS.items():
            df = parse_gtfs_file(zf, feed_name, dtypes)
            results[feed_name] = df

    # 3. Validate + Upload
    log.info("\nValidating and uploading…")
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    all_passed = True

    for name, df in results.items():
        log.info("── %s ──", name)
        ok = validate_dataframe(name, df)
        all_passed = all_passed and ok

        if not df.empty:
            save_local_sample(df, name)
            if not local_only:
                upload_parquet_to_adls(df, name, f"{name}_{ts}.parquet")

    # 4. Summary
    log.info("\n" + "=" * 60)
    log.info("  SUMMARY")
    log.info("=" * 60)
    for name, df in results.items():
        log.info("  %-20s  %6d rows", name, len(df))

    total_rows = sum(len(df) for df in results.values())
    log.info("  %-20s  %6d rows total", "ALL FILES", total_rows)
    log.info("  Status: %s", "✓ PASSED" if all_passed else "✗ WARNINGS")
    log.info("=" * 60)

    if not all_passed:
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Ingest NTA GTFS Static data")
    parser.add_argument("--local-only", action="store_true",
                        help="Skip ADLS upload (local dev mode)")
    args = parser.parse_args()
    main(local_only=args.local_only)
