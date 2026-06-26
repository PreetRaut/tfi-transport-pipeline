-- ================================================================
-- BRONZE SCHEMA  ·  TFI Transport Analytics Pipeline
-- ================================================================
-- Raw landing tables. Mirror source exactly.
-- No transformations, no business logic.
-- Loaded by ADF from ADLS Gen2 Parquet files.
-- ================================================================

-- ── GTFS STATIC ──────────────────────────────────────────────────

DROP TABLE IF EXISTS bronze.gtfs_agency;
CREATE TABLE bronze.gtfs_agency (
    agency_id       NVARCHAR(100),
    agency_name     NVARCHAR(200) NOT NULL,
    agency_url      NVARCHAR(500),
    agency_timezone NVARCHAR(100),
    agency_lang     NVARCHAR(10),
    _ingested_at    NVARCHAR(50),
    _loaded_at      DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.gtfs_routes;
CREATE TABLE bronze.gtfs_routes (
    route_id         NVARCHAR(100) NOT NULL,
    agency_id        NVARCHAR(100),
    route_short_name NVARCHAR(50),
    route_long_name  NVARCHAR(500),
    route_type       INT,
    route_color      NVARCHAR(10),
    route_text_color NVARCHAR(10),
    route_desc       NVARCHAR(1000),
    _ingested_at     NVARCHAR(50),
    _loaded_at       DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.gtfs_trips;
CREATE TABLE bronze.gtfs_trips (
    route_id         NVARCHAR(100),
    service_id       NVARCHAR(100),
    trip_id          NVARCHAR(200) NOT NULL,
    trip_headsign    NVARCHAR(500),
    direction_id     INT,
    shape_id         NVARCHAR(200),
    block_id         NVARCHAR(200),
    _ingested_at     NVARCHAR(50),
    _loaded_at       DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.gtfs_stops;
CREATE TABLE bronze.gtfs_stops (
    stop_id              NVARCHAR(100) NOT NULL,
    stop_name            NVARCHAR(500),
    stop_lat             FLOAT,
    stop_lon             FLOAT,
    stop_code            NVARCHAR(50),
    zone_id              NVARCHAR(50),
    parent_station       NVARCHAR(100),
    location_type        INT,
    wheelchair_boarding  INT,
    _ingested_at         NVARCHAR(50),
    _loaded_at           DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.gtfs_stop_times;
CREATE TABLE bronze.gtfs_stop_times (
    trip_id              NVARCHAR(200) NOT NULL,
    arrival_time         NVARCHAR(20),
    departure_time       NVARCHAR(20),
    stop_id              NVARCHAR(100) NOT NULL,
    stop_sequence        INT           NOT NULL,
    pickup_type          INT,
    drop_off_type        INT,
    shape_dist_traveled  FLOAT,
    timepoint            INT,
    _ingested_at         NVARCHAR(50),
    _loaded_at           DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.gtfs_calendar;
CREATE TABLE bronze.gtfs_calendar (
    service_id   NVARCHAR(100) NOT NULL,
    monday       INT,
    tuesday      INT,
    wednesday    INT,
    thursday     INT,
    friday       INT,
    saturday     INT,
    sunday       INT,
    start_date   NVARCHAR(20),
    end_date     NVARCHAR(20),
    _ingested_at NVARCHAR(50),
    _loaded_at   DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.gtfs_calendar_dates;
CREATE TABLE bronze.gtfs_calendar_dates (
    service_id      NVARCHAR(100) NOT NULL,
    date            NVARCHAR(20)  NOT NULL,
    exception_type  INT,
    _ingested_at    NVARCHAR(50),
    _loaded_at      DATETIME2 NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS bronze.rt_trip_updates;
CREATE TABLE bronze.rt_trip_updates (
    fetched_at             NVARCHAR(50)  NOT NULL,
    entity_id              NVARCHAR(200),
    trip_id                NVARCHAR(200),
    route_id               NVARCHAR(100),
    direction_id           INT,
    start_date             NVARCHAR(20),
    start_time             NVARCHAR(20),
    schedule_relationship  NVARCHAR(50),
    vehicle_id             NVARCHAR(200),
    stop_id                NVARCHAR(100),
    stop_sequence          INT,
    arrival_delay_secs     INT,
    arrival_time_unix      BIGINT,
    arrival_uncertainty    INT,
    departure_delay_secs   INT,
    departure_time_unix    BIGINT,
    departure_uncertainty  INT,
    stu_schedule_rel       NVARCHAR(50),
    _loaded_at             DATETIME2 NOT NULL DEFAULT GETDATE()
);
CREATE INDEX ix_bronze_rt_tu_route   ON bronze.rt_trip_updates (route_id);
CREATE INDEX ix_bronze_rt_tu_fetched ON bronze.rt_trip_updates (fetched_at);

DROP TABLE IF EXISTS bronze.rt_vehicle_positions;
CREATE TABLE bronze.rt_vehicle_positions (
    fetched_at        NVARCHAR(50)  NOT NULL,
    entity_id         NVARCHAR(200),
    vehicle_id        NVARCHAR(200),
    vehicle_label     NVARCHAR(200),
    trip_id           NVARCHAR(200),
    route_id          NVARCHAR(100),
    direction_id      INT,
    start_date        NVARCHAR(20),
    latitude          FLOAT,
    longitude         FLOAT,
    bearing           FLOAT,
    speed_mps         FLOAT,
    current_stop_seq  INT,
    current_stop_id   NVARCHAR(100),
    current_status    NVARCHAR(50),
    timestamp_unix    BIGINT,
    congestion_level  NVARCHAR(50),
    occupancy_status  NVARCHAR(50),
    _loaded_at        DATETIME2 NOT NULL DEFAULT GETDATE()
);
CREATE INDEX ix_bronze_rt_vp_route   ON bronze.rt_vehicle_positions (route_id);
CREATE INDEX ix_bronze_rt_vp_fetched ON bronze.rt_vehicle_positions (fetched_at);

PRINT 'Bronze schema created.';
