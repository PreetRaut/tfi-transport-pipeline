"""
tests/test_ingestion.py
━━━━━━━━━━━━━━━━━━━━━━━
Unit tests for the TFI ingestion pipeline.

Run: pytest tests/ -v
"""

import io
import json
import zipfile
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pandas as pd
import pytest

# ── Tests: GTFS Static ────────────────────────────────────────────

class TestGTFSStaticParsing:
    """Tests for ingestion/01_ingest_gtfs_static.py"""

    def _make_zip(self, files: dict) -> bytes:
        """Helper: create in-memory ZIP with given {filename: csv_content}."""
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            for name, content in files.items():
                zf.writestr(name, content)
        return buf.getvalue()

    def test_parse_routes_basic(self):
        """routes.txt should parse to DataFrame with expected columns."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_static import parse_gtfs_file, DTYPE_MAPS

        csv = (
            "route_id,agency_id,route_short_name,route_long_name,route_type\n"
            "100-1,7778,100,Stillorgan - City Centre,3\n"
            "46A-1,7778,46A,Dún Laoghaire - City Centre,3\n"
        )
        zip_bytes = self._make_zip({"routes.txt": csv})
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            df = parse_gtfs_file(zf, "routes", DTYPE_MAPS["routes"])

        assert len(df) == 2
        assert "route_id" in df.columns
        assert "_ingested_at" in df.columns
        assert df["route_type"].iloc[0] == 3

    def test_parse_stops_lat_lon(self):
        """stops.txt: lat/lon should be float, not string."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_static import parse_gtfs_file, DTYPE_MAPS

        csv = (
            "stop_id,stop_name,stop_lat,stop_lon\n"
            "8220DB000001,O'Connell Street,53.3498,-6.2603\n"
        )
        zip_bytes = self._make_zip({"stops.txt": csv})
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            df = parse_gtfs_file(zf, "stops", DTYPE_MAPS["stops"])

        assert df["stop_lat"].dtype == float
        assert df["stop_lon"].dtype == float
        assert abs(df["stop_lat"].iloc[0] - 53.3498) < 0.0001

    def test_missing_file_returns_empty(self):
        """parse_gtfs_file should return empty DataFrame if file is absent."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_static import parse_gtfs_file, DTYPE_MAPS

        zip_bytes = self._make_zip({"agency.txt": "agency_id,agency_name\n1,Test\n"})
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            df = parse_gtfs_file(zf, "routes", DTYPE_MAPS["routes"])

        assert df.empty

    def test_bom_stripped_from_column_names(self):
        """Column names with BOM prefix should be cleaned."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_static import parse_gtfs_file, DTYPE_MAPS

        # BOM character at start of header
        csv = "\ufeffagency_id,agency_name,agency_url,agency_timezone,agency_lang\n1,Dublin Bus,http://dublinbus.ie,Europe/Dublin,en\n"
        zip_bytes = self._make_zip({"agency.txt": csv})
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            df = parse_gtfs_file(zf, "agency", DTYPE_MAPS["agency"])

        assert "agency_id" in df.columns
        assert "\ufeffagency_id" not in df.columns

    def test_validation_fails_empty_df(self):
        """validate_dataframe should return False for empty DataFrame."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_static import validate_dataframe

        result = validate_dataframe("routes", pd.DataFrame())
        assert result is False

    def test_validation_passes_valid_df(self):
        """validate_dataframe should return True for a valid DataFrame."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_static import validate_dataframe

        df = pd.DataFrame({"route_id": ["100-1", "46A-1"], "agency_id": ["7778", "7778"]})
        result = validate_dataframe("routes", df)
        assert result is True


# ── Tests: GTFS Realtime ──────────────────────────────────────────

class TestGTFSRealtimeParsing:
    """Tests for ingestion/02_ingest_gtfs_realtime.py"""

    def _sample_trip_updates(self) -> dict:
        return {
            "entity": [
                {
                    "id": "entity_001",
                    "tripUpdate": {
                        "trip": {
                            "tripId": "trip_001",
                            "routeId": "46A-1",
                            "directionId": 0,
                            "startDate": "20250101",
                            "startTime": "08:00:00",
                            "scheduleRelationship": "SCHEDULED"
                        },
                        "vehicle": {"id": "VH_001"},
                        "stopTimeUpdate": [
                            {
                                "stopSequence": 5,
                                "stopId": "8220DB000001",
                                "arrival":   {"delay": 120, "time": 1735718400, "uncertainty": 30},
                                "departure": {"delay": 90,  "time": 1735718460, "uncertainty": 30},
                                "scheduleRelationship": "SCHEDULED"
                            },
                            {
                                "stopSequence": 6,
                                "stopId": "8220DB000002",
                                "arrival":   {"delay": 60},
                                "departure": {"delay": 60},
                                "scheduleRelationship": "SCHEDULED"
                            }
                        ]
                    }
                }
            ]
        }

    def _sample_vehicle_positions(self) -> dict:
        return {
            "entity": [
                {
                    "id": "vp_001",
                    "vehicle": {
                        "trip": {"tripId": "trip_001", "routeId": "46A-1", "directionId": 0, "startDate": "20250101"},
                        "vehicle": {"id": "VH_001", "label": "VH001"},
                        "position": {"latitude": 53.35, "longitude": -6.26, "bearing": 180.0, "speed": 8.5},
                        "currentStopSequence": 5,
                        "stopId": "8220DB000001",
                        "currentStatus": "IN_TRANSIT_TO",
                        "timestamp": 1735718400,
                        "occupancyStatus": "MANY_SEATS_AVAILABLE"
                    }
                }
            ]
        }

    def test_trip_updates_row_count(self):
        """One entity with 2 stop_time_updates should produce 2 rows."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_trip_updates

        raw = self._sample_trip_updates()
        df  = parse_trip_updates(raw, "2025-01-01T08:00:00Z")
        assert len(df) == 2

    def test_trip_updates_columns(self):
        """TripUpdates DataFrame should have key delay columns."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_trip_updates

        df = parse_trip_updates(self._sample_trip_updates(), "2025-01-01T08:00:00Z")
        for col in ["trip_id", "route_id", "stop_id", "arrival_delay_secs", "departure_delay_secs"]:
            assert col in df.columns, f"Missing column: {col}"

    def test_trip_updates_delay_values(self):
        """Delay values should match the sample data."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_trip_updates

        df = parse_trip_updates(self._sample_trip_updates(), "2025-01-01T08:00:00Z")
        first_stop = df[df["stop_id"] == "8220DB000001"].iloc[0]
        assert first_stop["arrival_delay_secs"] == 120
        assert first_stop["departure_delay_secs"] == 90

    def test_vehicle_positions_row_count(self):
        """One vehicle entity should produce 1 row."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_vehicle_positions

        df = parse_vehicle_positions(self._sample_vehicle_positions(), "2025-01-01T08:00:00Z")
        assert len(df) == 1

    def test_vehicle_positions_lat_lon(self):
        """Vehicle position lat/lon should be numeric."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_vehicle_positions

        df = parse_vehicle_positions(self._sample_vehicle_positions(), "2025-01-01T08:00:00Z")
        assert abs(df["latitude"].iloc[0]  - 53.35) < 0.001
        assert abs(df["longitude"].iloc[0] - (-6.26)) < 0.001

    def test_empty_feed_returns_empty_df(self):
        """Empty entity list should produce empty DataFrame."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_trip_updates

        df = parse_trip_updates({"entity": []}, "2025-01-01T08:00:00Z")
        assert df.empty

    def test_missing_delay_fields_handled(self):
        """Missing arrival/departure dicts should not crash the parser."""
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
        from ingestion.ingest_gtfs_realtime import parse_trip_updates

        raw = {
            "entity": [{
                "id": "e1",
                "tripUpdate": {
                    "trip": {"tripId": "t1", "routeId": "r1"},
                    "vehicle": {},
                    "stopTimeUpdate": [{
                        "stopSequence": 1,
                        "stopId": "s1"
                        # no arrival/departure keys
                    }]
                }
            }]
        }
        df = parse_trip_updates(raw, "ts")
        assert len(df) == 1
        assert pd.isna(df["arrival_delay_secs"].iloc[0]) or df["arrival_delay_secs"].iloc[0] is None
