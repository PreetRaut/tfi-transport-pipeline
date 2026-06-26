# 🚌 TFI Ireland — Real-Time Transport Analytics Pipeline

[![Azure](https://img.shields.io/badge/Azure-Data%20Factory-0078D4?logo=microsoftazure)](https://azure.microsoft.com)
[![Azure SQL](https://img.shields.io/badge/Azure-SQL%20Database-CC2927?logo=microsoftazure)](https://azure.microsoft.com/en-us/products/azure-sql)
[![ADLS Gen2](https://img.shields.io/badge/Azure-Data%20Lake%20Gen2-0078D4?logo=microsoftazure)](https://azure.microsoft.com/en-us/products/storage/data-lake-storage)
[![NTA API](https://img.shields.io/badge/NTA-GTFS--Realtime%20API-009B48)](https://developer.nationaltransport.ie)
[![Tableau](https://img.shields.io/badge/Tableau-Public-E97627?logo=tableau)](https://public.tableau.com)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python)](https://python.org)
[![Tests](https://img.shields.io/badge/Tests-pytest-green)](tests/)

An end-to-end **real-time cloud analytics pipeline** for Irish public transport, built on Azure free tier. Ingests live bus and rail data from the **National Transport Authority (NTA) GTFS-Realtime API**, processes it through a **Bronze / Silver / Gold medallion architecture**, and surfaces delay, reliability, and network KPIs in a **Tableau Public dashboard**.

---

## Architecture

```
╔══════════════════════════════════════════════════════════════════════╗
║  DATA SOURCES                                                        ║
║                                                                      ║
║  NTA GTFS-Static (weekly ZIP)     NTA GTFS-Realtime API (every 60s) ║
║  transportforireland.ie            developer.nationaltransport.ie    ║
║  ├─ agency.txt                     ├─ /v2/TripUpdates                ║
║  ├─ routes.txt   (432 routes)      │    arrival / departure delays   ║
║  ├─ trips.txt                      └─ /v2/Vehicles                   ║
║  ├─ stops.txt    (10,456 stops)         GPS positions + speed        ║
║  ├─ stop_times.txt                                                   ║
║  └─ calendar.txt                                                     ║
╚══════════════╤═══════════════════════════════╤════════════════════════╝
               │  Python ingestion scripts     │  Python ingestion scripts
               │  01_ingest_gtfs_static.py     │  02_ingest_gtfs_realtime.py
               ▼                               ▼
╔══════════════════════════════════════════════════════════════════════╗
║  AZURE DATA LAKE STORAGE Gen2  (bronze container)                    ║
║  gtfs_static/agency/*.parquet     gtfs_realtime/trip_updates/*.parquet ║
║  gtfs_static/routes/*.parquet     gtfs_realtime/vehicle_positions/*.parquet ║
║  gtfs_static/stops/*.parquet                                         ║
║  gtfs_static/stop_times/*.parquet  ← timestamped snapshots every 60s ║
╚══════════════╤═══════════════════════════════════════════════════════╝
               │  Azure Data Factory
               │  pl_01_ingest_gtfs_static  (weekly trigger)
               │  pl_02_ingest_realtime     (every 5 min trigger)
               ▼
╔══════════════════════════════════════════════════════════════════════╗
║  AZURE SQL DATABASE                                                  ║
║                                                                      ║
║  ┌─ BRONZE schema ──────────────────────────────────────────────┐   ║
║  │  gtfs_agency    gtfs_routes    gtfs_trips    gtfs_stops       │   ║
║  │  gtfs_stop_times  gtfs_calendar  gtfs_calendar_dates          │   ║
║  │  rt_trip_updates  rt_vehicle_positions                        │   ║
║  └───────────────────────────────────────────────────────────────┘   ║
║                          │ usp_load_silver                           ║
║  ┌─ SILVER schema ───────▼───────────────────────────────────────┐   ║
║  │  dim_agency   dim_route   dim_stop   dim_date   dim_time_of_day│   ║
║  │  fact_scheduled_departures   ← schedule backbone               │   ║
║  │  fact_realtime_delays        ← every delay observation         │   ║
║  │  fact_vehicle_positions      ← every GPS ping                  │   ║
║  └───────────────────────────────────────────────────────────────┘   ║
║                          │ usp_load_gold                             ║
║  ┌─ GOLD schema ─────────▼───────────────────────────────────────┐   ║
║  │  route_daily_performance    stop_delay_hotspot                 │   ║
║  │  hourly_network_pattern     operator_weekly_scorecard          │   ║
║  │  route_type_summary         delay_trend_daily                  │   ║
║  │  ── Views ──────────────────────────────────────────────────── │   ║
║  │  vw_route_performance   vw_delay_heatmap   vw_stop_map         │   ║
║  │  vw_operator_comparison  vw_network_kpi    vw_delay_trend      │   ║
║  └───────────────────────────────────────────────────────────────┘   ║
╚══════════════╤═══════════════════════════════════════════════════════╝
               │  Tableau Public (Extract)
               ▼
╔══════════════════════════════════════════════════════════════════════╗
║  TABLEAU PUBLIC DASHBOARD  (5 sheets + 1 dashboard)                  ║
║  Network Overview │ Route Reliability │ Delay Heatmap                ║
║  Stop Map         │ Operator Comparison │ 30-Day Trend               ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## Data Sources

| Source | Type | Frequency | Content |
|--------|------|-----------|---------|
| [NTA GTFS Static](https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip) | ZIP (no key) | Weekly | 432 routes, 10,456 stops, full schedule |
| [NTA GTFS-R TripUpdates v2](https://developer.nationaltransport.ie) | REST API (free key) | Every 60s | Live arrival/departure delays per stop |
| [NTA GTFS-R VehiclePositions v2](https://developer.nationaltransport.ie) | REST API (free key) | Every 60s | GPS positions, speed, occupancy status |

**Operators covered:** Dublin Bus · Bus Éireann · Go-Ahead Ireland · Luas · Iarnród Éireann

---

## Project Structure

```
tfi-transport-pipeline/
├── ingestion/
│   ├── 01_ingest_gtfs_static.py      # Download & parse NTA GTFS Static ZIP
│   └── 02_ingest_gtfs_realtime.py    # Poll NTA GTFS-R API, flatten to Parquet
├── sql/
│   ├── schema/
│   │   ├── 01_bronze_schema.sql      # Raw landing tables
│   │   ├── 02_silver_schema.sql      # Cleaned star schema (dims + facts)
│   │   └── 03_gold_schema.sql        # Aggregated reporting tables
│   ├── transforms/
│   │   ├── 01_bronze_to_silver.sql   # ELT: parse, enrich, type-cast
│   │   └── 02_silver_to_gold.sql     # Aggregate KPIs for Tableau
│   └── views/
│       └── gold_views.sql            # 6 analytical views (Tableau ready)
├── adf_pipeline/
│   └── pipeline_arm_template.json    # ADF ARM template (2 pipelines + 2 triggers)
├── tableau/
│   ├── TABLEAU_SETUP.md              # Connection guide + calculated fields
│   └── screenshots/                  # Dashboard page exports (add after build)
├── tests/
│   └── test_ingestion.py             # pytest unit tests (12 tests)
├── data/sample/                      # Auto-generated CSV samples (gitignored)
├── .env.example                      # Credentials template
├── .gitignore
├── requirements.txt
└── README.md
```

---

## Quick Start

### Prerequisites
- Mac + VS Code
- Python 3.11+
- Azure free account → [azure.microsoft.com/free](https://azure.microsoft.com/free)
- NTA API key → [developer.nationaltransport.ie](https://developer.nationaltransport.ie)

### 1 — Clone & install
```bash
git clone https://github.com/YOUR_USERNAME/tfi-transport-pipeline.git
cd tfi-transport-pipeline
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

### 2 — Configure credentials
```bash
cp .env.example .env
# Edit .env with your NTA API key + Azure credentials
```

### 3 — Run tests
```bash
pytest tests/ -v
# 12 tests should pass without any Azure credentials
```

### 4 — Ingest GTFS Static (no key needed)
```bash
python ingestion/01_ingest_gtfs_static.py --local-only
# Downloads ~25MB ZIP, parses 7 feed files, saves samples to data/sample/
```

### 5 — Ingest one Realtime snapshot
```bash
python ingestion/02_ingest_gtfs_realtime.py --runs 1
# Fetches one TripUpdates + VehiclePositions snapshot
```

### 6 — Run SQL scripts (VS Code mssql extension)
```
sql/schema/01_bronze_schema.sql
sql/schema/02_silver_schema.sql
sql/schema/03_gold_schema.sql
sql/transforms/01_bronze_to_silver.sql
sql/transforms/02_silver_to_gold.sql
sql/views/gold_views.sql
```

### 7 — Import ADF pipeline
See `adf_pipeline/` — deploy ARM template to ADF Studio, activate both triggers.

### 8 — Build Tableau dashboard
See `tableau/TABLEAU_SETUP.md`

---

## Azure Setup (Free Tier — €0)

| Resource | SKU | Cost |
|---------|-----|------|
| ADLS Gen2 | LRS, <5 GB | Free |
| Azure SQL Database | Free tier (32 GB) | €0 |
| Azure Data Factory | 5 free activities/month | €0 |
| **NTA API** | Free (registered key) | **€0** |
| **Total** | | **€0** |

---

## Key Analytical Questions Answered

- Which Dublin Bus routes are most delayed during AM peak?
- How does on-time performance vary by hour of day and day of week?
- Which bus stops are chronic delay hotspots? (map view)
- How do Dublin Bus, Bus Éireann, and Go-Ahead compare in reliability?
- What is the 7-day rolling trend in network punctuality?
- How does Rail performance compare to Bus?

---

## Skills Demonstrated

| Category | Technologies |
|----------|-------------|
| Cloud infrastructure | Azure ADLS Gen2, Azure Data Factory, Azure SQL |
| Data architecture | Medallion (Bronze / Silver / Gold), Star schema |
| API integration | REST API, GTFS / GTFS-Realtime protocol, Protobuf JSON |
| ETL / ELT | ADF Copy Activity, T-SQL stored procedures, MERGE statements |
| Advanced SQL | Window functions, CTEs, computed columns, MERGE, Views |
| Python | pandas, pyarrow, requests, azure-storage-file-datalake |
| Testing | pytest, unit tests, mock API responses |
| BI & reporting | Tableau Public, calculated fields, map visuals, Extract mode |
| DevOps | Git, ARM templates, .env credential management |

---

## Author

**Preet** — MSc Computer Science (Data Science & AI), University College Dublin  
[LinkedIn](https://linkedin.com/in/YOUR_PROFILE) · [GitHub](https://github.com/YOUR_USERNAME) · [Tableau Public](https://public.tableau.com/YOUR_PROFILE)

## Live Dashboard

🔗 **[View on Tableau Public](https://public.tableau.com/shared/77NG73Q6R)**

Built from real NTA GTFS data:
- 10,218 bus & rail stops mapped across Ireland
- 1,218 live vehicle position snapshots
- 404 routes across 7 operators
- Azure SQL Bronze/Silver/Gold pipeline
