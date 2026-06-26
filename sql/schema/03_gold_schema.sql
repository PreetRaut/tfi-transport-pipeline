-- ================================================================
-- GOLD SCHEMA  ·  TFI Transport Analytics Pipeline
-- ================================================================
-- Aggregated, report-ready tables consumed directly by Tableau Public.
-- Pre-aggregated to reduce query complexity.
-- ================================================================

GO

-- ── 1. Route Performance Summary ─────────────────────────────────
-- One row per route per day. Core KPI table.
DROP TABLE IF EXISTS gold.route_daily_performance;
GO
CREATE TABLE gold.route_daily_performance (
    date_key                INT           NOT NULL,
    route_id                NVARCHAR(100) NOT NULL,
    route_short_name        NVARCHAR(50),
    route_long_name         NVARCHAR(500),
    agency_name             NVARCHAR(200),
    route_type_desc         NVARCHAR(50),
    -- Scheduled service
    total_scheduled_trips   INT,
    total_scheduled_stops   INT,
    -- Delay metrics (from realtime)
    total_delay_observations INT,
    avg_arrival_delay_mins  DECIMAL(8,2),
    avg_departure_delay_mins DECIMAL(8,2),
    pct_on_time             DECIMAL(5,2),  -- arrival delay <= 1 min
    pct_minor_delay         DECIMAL(5,2),  -- 1-5 mins late
    pct_moderate_delay      DECIMAL(5,2),  -- 5-15 mins late
    pct_severe_delay        DECIMAL(5,2),  -- >15 mins late
    max_delay_mins          DECIMAL(8,2),
    -- Vehicle activity
    active_vehicles         INT,
    avg_speed_kmh           DECIMAL(6,1),
    _refreshed_at           DATETIME2 NOT NULL DEFAULT GETDATE(),
    PRIMARY KEY (date_key, route_id)
);
GO

-- ── 2. Stop Delay Hotspots ────────────────────────────────────────
-- Aggregate delays by stop for map visualisation.
DROP TABLE IF EXISTS gold.stop_delay_hotspot;
GO
CREATE TABLE gold.stop_delay_hotspot (
    stop_id                 NVARCHAR(100) NOT NULL,
    stop_name               NVARCHAR(500),
    stop_lat                FLOAT,
    stop_lon                FLOAT,
    county                  NVARCHAR(100),
    is_city_centre          BIT,
    date_key                INT           NOT NULL,
    total_observations      INT,
    avg_arrival_delay_mins  DECIMAL(8,2),
    pct_on_time             DECIMAL(5,2),
    worst_route             NVARCHAR(100),  -- route with worst avg delay at this stop
    _refreshed_at           DATETIME2 NOT NULL DEFAULT GETDATE(),
    PRIMARY KEY (stop_id, date_key)
);
GO

-- ── 3. Hourly Demand & Delay Pattern ─────────────────────────────
-- Hour-of-day patterns across the whole network.
DROP TABLE IF EXISTS gold.hourly_network_pattern;
GO
CREATE TABLE gold.hourly_network_pattern (
    date_key                INT          NOT NULL,
    hour_of_day             INT          NOT NULL,
    time_period             NVARCHAR(20) NOT NULL,
    day_name                NVARCHAR(20),
    is_weekend              BIT,
    -- Scheduled
    scheduled_departures    INT,
    -- Realtime
    delay_observations      INT,
    avg_delay_mins          DECIMAL(8,2),
    pct_on_time             DECIMAL(5,2),
    active_vehicles         INT,
    avg_speed_kmh           DECIMAL(6,1),
    _refreshed_at           DATETIME2 NOT NULL DEFAULT GETDATE(),
    PRIMARY KEY (date_key, hour_of_day)
);
GO

-- ── 4. Operator Scorecard ─────────────────────────────────────────
-- One row per operator per week.
DROP TABLE IF EXISTS gold.operator_weekly_scorecard;
GO
CREATE TABLE gold.operator_weekly_scorecard (
    week_start_date         DATE          NOT NULL,
    week_label              NVARCHAR(20)  NOT NULL,  -- e.g. '2025-W22'
    agency_name             NVARCHAR(200) NOT NULL,
    operator_type           NVARCHAR(50),
    route_count             INT,
    total_delay_obs         INT,
    avg_delay_mins          DECIMAL(8,2),
    pct_on_time             DECIMAL(5,2),
    pct_severe_delay        DECIMAL(5,2),
    reliability_score       DECIMAL(5,2),  -- composite 0-100
    reliability_band        NVARCHAR(20),  -- 'Excellent' / 'Good' / 'Fair' / 'Poor'
    _refreshed_at           DATETIME2 NOT NULL DEFAULT GETDATE(),
    PRIMARY KEY (week_start_date, agency_name)
);
GO

-- ── 5. Route Type Summary ─────────────────────────────────────────
-- Bus vs Rail vs Tram comparison.
DROP TABLE IF EXISTS gold.route_type_summary;
GO
CREATE TABLE gold.route_type_summary (
    date_key                INT          NOT NULL,
    route_type_desc         NVARCHAR(50) NOT NULL,
    route_count             INT,
    trip_count              INT,
    delay_observations      INT,
    avg_delay_mins          DECIMAL(8,2),
    pct_on_time             DECIMAL(5,2),
    active_vehicles         INT,
    avg_speed_kmh           DECIMAL(6,1),
    _refreshed_at           DATETIME2 NOT NULL DEFAULT GETDATE(),
    PRIMARY KEY (date_key, route_type_desc)
);
GO

-- ── 6. Delay Trend (rolling 30 days) ─────────────────────────────
DROP TABLE IF EXISTS gold.delay_trend_daily;
GO
CREATE TABLE gold.delay_trend_daily (
    date_key                INT          NOT NULL PRIMARY KEY,
    full_date               DATE         NOT NULL,
    day_name                NVARCHAR(20),
    is_weekend              BIT,
    total_observations      INT,
    avg_delay_mins          DECIMAL(8,2),
    pct_on_time             DECIMAL(5,2),
    rolling_7d_avg_delay    DECIMAL(8,2),  -- populated via window function
    rolling_7d_pct_on_time  DECIMAL(5,2),
    _refreshed_at           DATETIME2 NOT NULL DEFAULT GETDATE()
);
GO

PRINT 'Gold schema created.';
GO
