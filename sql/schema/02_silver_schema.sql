-- ================================================================
-- SILVER SCHEMA  ·  TFI Transport Analytics Pipeline
-- ================================================================
-- Cleaned, typed, enriched tables. Star schema design.
-- Business rules applied. Ready for analytical queries.
-- ================================================================

GO

-- ── DIMENSIONS ───────────────────────────────────────────────────

DROP TABLE IF EXISTS silver.dim_agency;
GO
CREATE TABLE silver.dim_agency (
    agency_id       NVARCHAR(100) NOT NULL PRIMARY KEY,
    agency_name     NVARCHAR(200) NOT NULL,
    agency_timezone NVARCHAR(100),
    agency_url      NVARCHAR(500),
    -- Enriched
    operator_type   NVARCHAR(50),   -- 'Dublin Bus' | 'Bus Éireann' | 'Irish Rail' | 'Luas' | 'Go-Ahead'
    _updated_at     DATETIME2 NOT NULL DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS silver.dim_route;
GO
CREATE TABLE silver.dim_route (
    route_id         NVARCHAR(100) NOT NULL PRIMARY KEY,
    agency_id        NVARCHAR(100) NOT NULL,
    route_short_name NVARCHAR(50),
    route_long_name  NVARCHAR(500),
    route_type       INT           NOT NULL,
    route_type_desc  NVARCHAR(50),   -- derived: 'Bus' | 'Rail' | 'Tram' | 'Ferry'
    route_color      NVARCHAR(10),
    is_cross_city    BIT           NOT NULL DEFAULT 0,
    is_commuter      BIT           NOT NULL DEFAULT 0,
    _updated_at      DATETIME2     NOT NULL DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS silver.dim_stop;
GO
CREATE TABLE silver.dim_stop (
    stop_id             NVARCHAR(100) NOT NULL PRIMARY KEY,
    stop_name           NVARCHAR(500),
    stop_code           NVARCHAR(50),
    stop_lat            FLOAT,
    stop_lon            FLOAT,
    zone_id             NVARCHAR(50),
    parent_station      NVARCHAR(100),
    location_type       INT,
    -- Enriched
    county              NVARCHAR(100),  -- derived from lat/lon bounding boxes
    is_city_centre      BIT NOT NULL DEFAULT 0,
    is_interchange      BIT NOT NULL DEFAULT 0,
    wheelchair_boarding INT,
    _updated_at         DATETIME2 NOT NULL DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS silver.dim_date;
GO
CREATE TABLE silver.dim_date (
    date_key      INT          NOT NULL PRIMARY KEY,  -- YYYYMMDD
    full_date     DATE         NOT NULL,
    year          INT          NOT NULL,
    month         INT          NOT NULL,
    month_name    NVARCHAR(20) NOT NULL,
    day_of_month  INT          NOT NULL,
    day_of_week   INT          NOT NULL,  -- 1=Mon…7=Sun
    day_name      NVARCHAR(20) NOT NULL,
    quarter       INT          NOT NULL,
    week_number   INT          NOT NULL,
    is_weekend    BIT          NOT NULL DEFAULT 0,
    is_bank_holiday BIT        NOT NULL DEFAULT 0,
    period_label  NVARCHAR(30) NOT NULL   -- 'AM Peak' / 'Off-Peak' / 'PM Peak' / 'Night'
);
GO

DROP TABLE IF EXISTS silver.dim_time_of_day;
GO
CREATE TABLE silver.dim_time_of_day (
    time_key      INT          NOT NULL PRIMARY KEY,  -- HHMM
    hour          INT          NOT NULL,
    minute        INT          NOT NULL,
    period        NVARCHAR(20) NOT NULL,
    -- AM Peak: 07:00-09:30 | PM Peak: 17:00-19:30 | Night: 00:00-06:00
    is_peak_am    BIT          NOT NULL DEFAULT 0,
    is_peak_pm    BIT          NOT NULL DEFAULT 0,
    is_night      BIT          NOT NULL DEFAULT 0
);
GO

-- ── FACTS ─────────────────────────────────────────────────────────

DROP TABLE IF EXISTS silver.fact_scheduled_departures;
GO
CREATE TABLE silver.fact_scheduled_departures (
    departure_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
    trip_id           NVARCHAR(200) NOT NULL,
    route_id          NVARCHAR(100) NOT NULL,
    agency_id         NVARCHAR(100),
    service_id        NVARCHAR(100),
    stop_id           NVARCHAR(100) NOT NULL,
    stop_sequence     INT           NOT NULL,
    date_key          INT           NOT NULL,
    -- Scheduled times parsed from HH:MM:SS strings
    scheduled_arrival_time   NVARCHAR(20),
    scheduled_departure_time NVARCHAR(20),
    arrival_hour      INT,
    departure_hour    INT,
    departure_minute  INT,
    time_period       NVARCHAR(20),   -- AM Peak / PM Peak / Off-Peak / Night
    direction_id      INT,
    pickup_type       INT,
    drop_off_type     INT,
    is_timepoint      BIT NOT NULL DEFAULT 1,
    _loaded_at        DATETIME2 NOT NULL DEFAULT GETDATE()
);
GO
CREATE INDEX ix_silver_sched_route    ON silver.fact_scheduled_departures (route_id);
CREATE INDEX ix_silver_sched_stop     ON silver.fact_scheduled_departures (stop_id);
CREATE INDEX ix_silver_sched_datekey  ON silver.fact_scheduled_departures (date_key);
CREATE INDEX ix_silver_sched_hour     ON silver.fact_scheduled_departures (departure_hour);
GO

DROP TABLE IF EXISTS silver.fact_realtime_delays;
GO
CREATE TABLE silver.fact_realtime_delays (
    delay_id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    fetched_at_ts         DATETIME2     NOT NULL,
    fetched_date_key      INT           NOT NULL,
    fetched_hour          INT           NOT NULL,
    trip_id               NVARCHAR(200),
    route_id              NVARCHAR(100),
    agency_id             NVARCHAR(100),
    stop_id               NVARCHAR(100),
    stop_sequence         INT,
    direction_id          INT,
    vehicle_id            NVARCHAR(200),
    arrival_delay_secs    INT,
    departure_delay_secs  INT,
    arrival_delay_mins    AS (CAST(arrival_delay_secs / 60.0 AS DECIMAL(8,2))),
    departure_delay_mins  AS (CAST(departure_delay_secs / 60.0 AS DECIMAL(8,2))),
    delay_band            NVARCHAR(30),  -- 'On-Time' / 'Minor' / 'Moderate' / 'Severe'
    schedule_relationship NVARCHAR(50),
    _loaded_at            DATETIME2 NOT NULL DEFAULT GETDATE()
);
GO
CREATE INDEX ix_silver_delay_route    ON silver.fact_realtime_delays (route_id);
CREATE INDEX ix_silver_delay_stop     ON silver.fact_realtime_delays (stop_id);
CREATE INDEX ix_silver_delay_datekey  ON silver.fact_realtime_delays (fetched_date_key);
GO

DROP TABLE IF EXISTS silver.fact_vehicle_positions;
GO
CREATE TABLE silver.fact_vehicle_positions (
    position_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
    fetched_at_ts     DATETIME2     NOT NULL,
    fetched_date_key  INT           NOT NULL,
    fetched_hour      INT           NOT NULL,
    vehicle_id        NVARCHAR(200),
    vehicle_label     NVARCHAR(200),
    trip_id           NVARCHAR(200),
    route_id          NVARCHAR(100),
    direction_id      INT,
    latitude          FLOAT,
    longitude         FLOAT,
    bearing           FLOAT,
    speed_kmh         AS (CAST(speed_mps * 3.6 AS DECIMAL(6,1))),
    speed_mps         FLOAT,
    current_stop_id   NVARCHAR(100),
    current_status    NVARCHAR(50),
    congestion_level  NVARCHAR(50),
    occupancy_status  NVARCHAR(50),
    _loaded_at        DATETIME2 NOT NULL DEFAULT GETDATE()
);
GO
CREATE INDEX ix_silver_vp_route    ON silver.fact_vehicle_positions (route_id);
CREATE INDEX ix_silver_vp_datekey  ON silver.fact_vehicle_positions (fetched_date_key);
GO

PRINT 'Silver schema created.';
GO
