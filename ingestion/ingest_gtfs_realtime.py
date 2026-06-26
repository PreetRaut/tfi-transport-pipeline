"""
02_ingest_gtfs_realtime.py
━━━━━━━━━━━━━━━━━━━━━━━━━━
Polls the NTA GTFS-Realtime v2 API at a configurable interval,
parses protobuf TripUpdates and VehiclePositions, flattens to
DataFrames, and appends to ADLS Gen2 (bronze container) as
timestamped Parquet files.

API        : https://api.nationaltransport.ie/gtfsr/v2/
Register   : https://developer.nationaltransport.ie/
Feed docs  : https://gtfs.org/documentation/realtime/reference/

Endpoints used
──────────────
  GET /gtfsr/v2/TripUpdates        → stop arrival/departure predictions
  GET /gtfsr/v2/Vehicles           → real-time vehicle positions

Usage
─────
  python ingestion/02_ingest_gtfs_realtime.py
  python ingestion/02_ingest_gtfs_realtime.py --runs 1   # single snapshot
  python ingestion/02_ingest_gtfs_realtime.py --interval 60 --runs 60
"""

import argparse
import io
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

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
BASE_URL        = "https://api.nationaltransport.ie/gtfsr/v2"
TRIP_UPDATES_EP = f"{BASE_URL}/TripUpdates"
VEHICLES_EP     = f"{BASE_URL}/Vehicles"
ADLS_CONTAINER  = "bronze"
DEFAULT_INTERVAL_SECS = 60
DEFAULT_RUNS          = 1   # set to 0 for infinite loop


def get_api_key() -> str:
    key = os.getenv("NTA_API_KEY")
    if not key:
        log.error("NTA_API_KEY not set in .env — register at developer.nationaltransport.ie")
        sys.exit(1)
    return key


def fetch_gtfsr_json(endpoint: str, api_key: str) -> Optional[dict]:
    """Fetch GTFS-R feed as JSON (format=json query param)."""
    headers = {"x-api-key": api_key, "Cache-Control": "no-cache"}
    params  = {"format": "json"}
    try:
        resp = requests.get(endpoint, headers=headers, params=params, timeout=30)
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.HTTPError as e:
        log.error("HTTP error fetching %s: %s", endpoint, e)
        return None
    except requests.exceptions.Timeout:
        log.error("Timeout fetching %s", endpoint)
        return None
    except Exception as e:
        log.error("Unexpected error fetching %s: %s", endpoint, e)
        return None


def parse_trip_updates(raw: dict, fetched_at: str) -> pd.DataFrame:
    """
    Flatten GTFS-R TripUpdates protobuf JSON into a tabular DataFrame.

    Each row = one stop_time_update within a trip.
    """
    records = []
    for entity in raw.get("entity", []):
        tu = entity.get("tripUpdate", {})
        trip = tu.get("trip", {})

        trip_id    = trip.get("tripId", "")
        route_id   = trip.get("routeId", "")
        direction  = trip.get("directionId")
        start_date = trip.get("startDate", "")
        start_time = trip.get("startTime", "")
        schedule_rel = trip.get("scheduleRelationship", "")

        vehicle = tu.get("vehicle", {})
        vehicle_id = vehicle.get("id", "")

        for stu in tu.get("stopTimeUpdate", []):
            arrival   = stu.get("arrival", {})
            departure = stu.get("departure", {})
            records.append({
                "fetched_at":            fetched_at,
                "entity_id":             entity.get("id", ""),
                "trip_id":               trip_id,
                "route_id":              route_id,
                "direction_id":          direction,
                "start_date":            start_date,
                "start_time":            start_time,
                "schedule_relationship": schedule_rel,
                "vehicle_id":            vehicle_id,
                "stop_id":               stu.get("stopId", ""),
                "stop_sequence":         stu.get("stopSequence"),
                "arrival_delay_secs":    arrival.get("delay"),
                "arrival_time_unix":     arrival.get("time"),
                "arrival_uncertainty":   arrival.get("uncertainty"),
                "departure_delay_secs":  departure.get("delay"),
                "departure_time_unix":   departure.get("time"),
                "departure_uncertainty": departure.get("uncertainty"),
                "stu_schedule_rel":      stu.get("scheduleRelationship", ""),
            })

    df = pd.DataFrame(records)
    log.info("  TripUpdates: %d stop-level records from %d entities",
             len(df), len(raw.get("entity", [])))
    return df


def parse_vehicle_positions(raw: dict, fetched_at: str) -> pd.DataFrame:
    """
    Flatten GTFS-R VehiclePositions JSON into a tabular DataFrame.

    Each row = one vehicle snapshot.
    """
    records = []
    for entity in raw.get("entity", []):
        vp = entity.get("vehicle", {})
        trip    = vp.get("trip", {})
        pos     = vp.get("position", {})
        vehicle = vp.get("vehicle", {})

        records.append({
            "fetched_at":       fetched_at,
            "entity_id":        entity.get("id", ""),
            "vehicle_id":       vehicle.get("id", ""),
            "vehicle_label":    vehicle.get("label", ""),
            "trip_id":          trip.get("tripId", ""),
            "route_id":         trip.get("routeId", ""),
            "direction_id":     trip.get("directionId"),
            "start_date":       trip.get("startDate", ""),
            "latitude":         pos.get("latitude"),
            "longitude":        pos.get("longitude"),
            "bearing":          pos.get("bearing"),
            "speed_mps":        pos.get("speed"),
            "current_stop_seq": vp.get("currentStopSequence"),
            "current_stop_id":  vp.get("stopId", ""),
            "current_status":   vp.get("currentStatus", ""),
            "timestamp_unix":   vp.get("timestamp"),
            "congestion_level": vp.get("congestionLevel", ""),
            "occupancy_status": vp.get("occupancyStatus", ""),
        })

    df = pd.DataFrame(records)
    log.info("  VehiclePositions: %d vehicles", len(df))
    return df


def save_parquet_local(df: pd.DataFrame, feed: str, ts: str) -> Path:
    """Save Parquet snapshot locally for inspection."""
    out = Path(f"data/sample/realtime_{feed}_{ts}.parquet")
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out, index=False, engine="pyarrow")
    log.info("  Saved locally → %s", out)
    return out


def upload_to_adls(df: pd.DataFrame, folder: str, filename: str) -> None:
    """Append timestamped Parquet snapshot to ADLS Gen2."""
    account = os.getenv("ADLS_ACCOUNT_NAME")
    key     = os.getenv("ADLS_ACCOUNT_KEY")

    if not account or not key:
        log.warning("  ADLS credentials not set — skipping upload")
        return

    try:
        from azure.storage.filedatalake import DataLakeServiceClient
    except ImportError:
        log.warning("  azure-storage-file-datalake not installed — skipping upload")
        return

    svc = DataLakeServiceClient(
        account_url=f"https://{account}.dfs.core.windows.net",
        credential=key,
    )
    fs = svc.get_file_system_client(ADLS_CONTAINER)
    try:
        fs.create_file_system()
    except Exception:
        pass

    buf = io.BytesIO()
    df.to_parquet(buf, index=False, engine="pyarrow")
    buf.seek(0)
    data = buf.read()

    remote_path = f"gtfs_realtime/{folder}/{filename}"
    fc = fs.get_file_client(remote_path)
    fc.upload_data(data, overwrite=True)
    log.info("  Uploaded → %s  (%.1f KB)", remote_path, len(data) / 1024)


def run_once(api_key: str, ts: str) -> None:
    log.info("\n── Snapshot at %s ──", ts)

    # TripUpdates
    log.info("Fetching TripUpdates…")
    raw_tu = fetch_gtfsr_json(TRIP_UPDATES_EP, api_key)
    if raw_tu:
        df_tu = parse_trip_updates(raw_tu, ts)
        if not df_tu.empty:
            fname = f"trip_updates_{ts}.parquet"
            save_parquet_local(df_tu, "trip_updates", ts)
            upload_to_adls(df_tu, "trip_updates", fname)

    # Vehicle Positions
    log.info("Fetching VehiclePositions…")
    raw_vp = fetch_gtfsr_json(VEHICLES_EP, api_key)
    if raw_vp:
        df_vp = parse_vehicle_positions(raw_vp, ts)
        if not df_vp.empty:
            fname = f"vehicle_positions_{ts}.parquet"
            save_parquet_local(df_vp, "vehicle_positions", ts)
            upload_to_adls(df_vp, "vehicle_positions", fname)


def main(interval: int, runs: int) -> None:
    log.info("=" * 60)
    log.info("  TFI GTFS-Realtime Ingestion Pipeline")
    log.info("  Interval: %ds  |  Runs: %s", interval, runs if runs else "∞")
    log.info("=" * 60)

    api_key  = get_api_key()
    count    = 0

    while True:
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_once(api_key, ts)
        count += 1

        if runs and count >= runs:
            break

        log.info("Sleeping %ds before next poll…", interval)
        time.sleep(interval)

    log.info("\nCompleted %d run(s).", count)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Ingest NTA GTFS-Realtime data")
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL_SECS,
                        help="Polling interval in seconds (default: 60)")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS,
                        help="Number of polling runs (0 = infinite, default: 1)")
    args = parser.parse_args()
    main(interval=args.interval, runs=args.runs)
