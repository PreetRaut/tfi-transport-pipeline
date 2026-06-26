-- ================================================================
-- TRANSFORM: Bronze → Silver
-- TFI Transport Analytics Pipeline
-- ================================================================
-- Run after ADF loads bronze tables from ADLS Parquet files.
-- ================================================================

-- ── 1. dim_agency ─────────────────────────────────────────────────
TRUNCATE TABLE silver.dim_agency;
GO

INSERT INTO silver.dim_agency (agency_id, agency_name, agency_timezone, agency_url, operator_type)
SELECT
    COALESCE(agency_id, agency_name)   AS agency_id,
    agency_name,
    agency_timezone,
    agency_url,
    operator_type = CASE
        WHEN agency_name LIKE '%Dublin Bus%'     THEN 'Dublin Bus'
        WHEN agency_name LIKE '%Bus Éireann%'    THEN 'Bus Éireann'
        WHEN agency_name LIKE '%Iarnród%'        THEN 'Irish Rail'
        WHEN agency_name LIKE '%Luas%'           THEN 'Luas'
        WHEN agency_name LIKE '%Go-Ahead%'       THEN 'Go-Ahead Ireland'
        WHEN agency_name LIKE '%Transport%'      THEN 'TFI'
        ELSE 'Other'
    END
FROM bronze.gtfs_agency;
GO

-- ── 2. dim_route ──────────────────────────────────────────────────
TRUNCATE TABLE silver.dim_route;
GO

INSERT INTO silver.dim_route (
    route_id, agency_id, route_short_name, route_long_name,
    route_type, route_type_desc, route_color, is_cross_city, is_commuter
)
SELECT
    route_id,
    COALESCE(agency_id, 'UNKNOWN')  AS agency_id,
    route_short_name,
    route_long_name,
    COALESCE(route_type, 3)         AS route_type,
    route_type_desc = CASE route_type
        WHEN 0 THEN 'Tram'
        WHEN 1 THEN 'Metro'
        WHEN 2 THEN 'Rail'
        WHEN 3 THEN 'Bus'
        WHEN 4 THEN 'Ferry'
        ELSE 'Unknown'
    END,
    route_color,
    is_cross_city = CASE
        WHEN route_long_name LIKE '%City Centre%' OR
             route_long_name LIKE '%Cross City%'  THEN 1 ELSE 0
    END,
    is_commuter = CASE
        WHEN route_type = 2   -- Rail
          OR route_long_name LIKE '%Commuter%'
          OR route_long_name LIKE '%Express%' THEN 1 ELSE 0
    END
FROM bronze.gtfs_routes;
GO

-- ── 3. dim_stop ───────────────────────────────────────────────────
TRUNCATE TABLE silver.dim_stop;
GO

INSERT INTO silver.dim_stop (
    stop_id, stop_name, stop_code, stop_lat, stop_lon,
    zone_id, parent_station, location_type,
    county, is_city_centre, is_interchange, wheelchair_boarding
)
SELECT
    stop_id,
    stop_name,
    stop_code,
    stop_lat,
    stop_lon,
    zone_id,
    parent_station,
    COALESCE(location_type, 0)  AS location_type,
    -- County approximation from bounding boxes (Ireland)
    county = CASE
        WHEN stop_lat BETWEEN 53.25 AND 53.45 AND stop_lon BETWEEN -6.45 AND -6.05 THEN 'Dublin'
        WHEN stop_lat BETWEEN 51.85 AND 52.10 AND stop_lon BETWEEN -8.65 AND -8.35 THEN 'Cork'
        WHEN stop_lat BETWEEN 53.25 AND 53.30 AND stop_lon BETWEEN -9.10 AND -8.95 THEN 'Galway'
        WHEN stop_lat BETWEEN 52.63 AND 52.70 AND stop_lon BETWEEN -8.70 AND -8.58 THEN 'Limerick'
        WHEN stop_lat BETWEEN 52.24 AND 52.28 AND stop_lon BETWEEN -7.15 AND -7.08 THEN 'Waterford'
        ELSE 'Other'
    END,
    -- City centre: tight Dublin bounding box
    is_city_centre = CASE
        WHEN stop_lat BETWEEN 53.33 AND 53.36 AND stop_lon BETWEEN -6.28 AND -6.22 THEN 1 ELSE 0
    END,
    -- Interchange: parent station set = major hub
    is_interchange = CASE WHEN parent_station IS NOT NULL THEN 1 ELSE 0 END,
    wheelchair_boarding
FROM bronze.gtfs_stops;
GO

-- ── 4. dim_date (spine: today - 90 days → today + 30 days) ───────
-- Only inserting rows not already present (safe to re-run)
INSERT INTO silver.dim_date (
    date_key, full_date, year, month, month_name,
    day_of_month, day_of_week, day_name,
    quarter, week_number, is_weekend, is_bank_holiday, period_label
)
SELECT
    CAST(FORMAT(d.full_date, 'yyyyMMdd') AS INT)  AS date_key,
    d.full_date,
    YEAR(d.full_date)                              AS year,
    MONTH(d.full_date)                             AS month,
    DATENAME(MONTH, d.full_date)                   AS month_name,
    DAY(d.full_date)                               AS day_of_month,
    -- ISO day of week: 1=Mon, 7=Sun
    ((DATEPART(WEEKDAY, d.full_date) + 5) % 7) + 1 AS day_of_week,
    DATENAME(WEEKDAY, d.full_date)                 AS day_name,
    DATEPART(QUARTER, d.full_date)                 AS quarter,
    DATEPART(ISO_WEEK, d.full_date)                AS week_number,
    CASE WHEN DATEPART(WEEKDAY, d.full_date) IN (1,7) THEN 1 ELSE 0 END AS is_weekend,
    -- Irish bank holidays 2025 (static list)
    CASE WHEN d.full_date IN (
        '2025-01-01','2025-02-03','2025-04-18','2025-04-21',
        '2025-05-05','2025-06-02','2025-08-04','2025-10-27',
        '2025-12-25','2025-12-26'
    ) THEN 1 ELSE 0 END                            AS is_bank_holiday,
    'Weekday'                                      AS period_label
FROM (
    SELECT DATEADD(DAY, n.n, CAST(GETDATE() AS DATE)) AS full_date
    FROM (
        SELECT TOP 121 ROW_NUMBER() OVER (ORDER BY object_id) - 91 AS n
        FROM sys.objects
    ) n
) d
WHERE NOT EXISTS (
    SELECT 1 FROM silver.dim_date dd
    WHERE dd.date_key = CAST(FORMAT(d.full_date, 'yyyyMMdd') AS INT)
);
GO

-- ── 5. dim_time_of_day (all 1440 minutes of the day) ─────────────
IF NOT EXISTS (SELECT 1 FROM silver.dim_time_of_day)
BEGIN
    WITH mins AS (
        SELECT TOP 1440 (ROW_NUMBER() OVER (ORDER BY object_id) - 1) AS m
        FROM sys.objects
    )
    INSERT INTO silver.dim_time_of_day (time_key, hour, minute, period, is_peak_am, is_peak_pm, is_night)
    SELECT
        m.m / 60 * 100 + m.m % 60   AS time_key,
        m.m / 60                     AS hour,
        m.m % 60                     AS minute,
        period = CASE
            WHEN m.m BETWEEN 420 AND 570 THEN 'AM Peak'    -- 07:00-09:30
            WHEN m.m BETWEEN 1020 AND 1170 THEN 'PM Peak'  -- 17:00-19:30
            WHEN m.m BETWEEN 0 AND 359 THEN 'Night'        -- 00:00-05:59
            ELSE 'Off-Peak'
        END,
        CASE WHEN m.m BETWEEN 420 AND 570  THEN 1 ELSE 0 END,
        CASE WHEN m.m BETWEEN 1020 AND 1170 THEN 1 ELSE 0 END,
        CASE WHEN m.m BETWEEN 0 AND 359     THEN 1 ELSE 0 END
    FROM mins;
END
GO

-- ── 6. fact_scheduled_departures ─────────────────────────────────
TRUNCATE TABLE silver.fact_scheduled_departures;
GO

INSERT INTO silver.fact_scheduled_departures (
    trip_id, route_id, agency_id, service_id, stop_id, stop_sequence,
    date_key, scheduled_arrival_time, scheduled_departure_time,
    arrival_hour, departure_hour, departure_minute,
    time_period, direction_id, pickup_type, drop_off_type, is_timepoint
)
SELECT
    st.trip_id,
    t.route_id,
    r.agency_id,
    t.service_id,
    st.stop_id,
    st.stop_sequence,
    -- Use today as a proxy date key (schedules are cyclical)
    CAST(FORMAT(GETDATE(), 'yyyyMMdd') AS INT)       AS date_key,
    st.arrival_time,
    st.departure_time,
    -- Parse hour from HH:MM:SS (handles >24:00 overnight services)
    CAST(LEFT(st.arrival_time,   2) AS INT)          AS arrival_hour,
    CAST(LEFT(st.departure_time, 2) AS INT)          AS departure_hour,
    CAST(SUBSTRING(st.departure_time, 4, 2) AS INT)  AS departure_minute,
    -- Time period from departure hour
    time_period = CASE
        WHEN CAST(LEFT(st.departure_time, 2) AS INT) BETWEEN 7  AND 9  THEN 'AM Peak'
        WHEN CAST(LEFT(st.departure_time, 2) AS INT) BETWEEN 17 AND 19 THEN 'PM Peak'
        WHEN CAST(LEFT(st.departure_time, 2) AS INT) BETWEEN 0  AND 5  THEN 'Night'
        ELSE 'Off-Peak'
    END,
    t.direction_id,
    st.pickup_type,
    st.drop_off_type,
    CASE WHEN COALESCE(st.timepoint, 1) = 1 THEN 1 ELSE 0 END
FROM bronze.gtfs_stop_times st
INNER JOIN bronze.gtfs_trips t  ON t.trip_id  = st.trip_id
INNER JOIN bronze.gtfs_routes r ON r.route_id = t.route_id
WHERE st.departure_time IS NOT NULL
  AND LEN(st.departure_time) >= 5;  -- guard against malformed rows
GO

-- ── 7. fact_realtime_delays ───────────────────────────────────────
-- Incremental merge — RT data grows every 60 seconds
MERGE silver.fact_realtime_delays AS target
USING (
    SELECT
        TRY_CONVERT(DATETIME2,
            REPLACE(REPLACE(fetched_at, 'T', ' '), 'Z', ''))    AS fetched_at_ts,
        CAST(LEFT(REPLACE(fetched_at,'T',''),8) AS INT)          AS fetched_date_key,
        CAST(SUBSTRING(REPLACE(fetched_at,'T',''), 10, 2) AS INT) AS fetched_hour,
        trip_id,
        route_id,
        stop_id,
        stop_sequence,
        direction_id,
        vehicle_id,
        arrival_delay_secs,
        departure_delay_secs,
        schedule_relationship,
        -- Delay band classification
        delay_band = CASE
            WHEN ABS(arrival_delay_secs) <= 60      THEN 'On-Time'
            WHEN arrival_delay_secs BETWEEN 60 AND 300  THEN 'Minor'
            WHEN arrival_delay_secs BETWEEN 300 AND 900 THEN 'Moderate'
            WHEN arrival_delay_secs > 900               THEN 'Severe'
            WHEN arrival_delay_secs < -60               THEN 'Early'
            ELSE 'Unknown'
        END
    FROM bronze.rt_trip_updates
    WHERE fetched_at IS NOT NULL
) AS source
ON  target.trip_id        = source.trip_id
AND target.stop_id        = source.stop_id
AND target.fetched_at_ts  = source.fetched_at_ts
WHEN NOT MATCHED THEN INSERT (
    fetched_at_ts, fetched_date_key, fetched_hour,
    trip_id, route_id, stop_id, stop_sequence, direction_id,
    vehicle_id, arrival_delay_secs, departure_delay_secs,
    delay_band, schedule_relationship
) VALUES (
    source.fetched_at_ts, source.fetched_date_key, source.fetched_hour,
    source.trip_id, source.route_id, source.stop_id, source.stop_sequence, source.direction_id,
    source.vehicle_id, source.arrival_delay_secs, source.departure_delay_secs,
    source.delay_band, source.schedule_relationship
);
GO

-- ── 8. fact_vehicle_positions ─────────────────────────────────────
INSERT INTO silver.fact_vehicle_positions (
    fetched_at_ts, fetched_date_key, fetched_hour,
    vehicle_id, vehicle_label, trip_id, route_id, direction_id,
    latitude, longitude, bearing, speed_mps,
    current_stop_id, current_status, congestion_level, occupancy_status
)
SELECT
    TRY_CONVERT(DATETIME2, REPLACE(REPLACE(fetched_at,'T',' '),'Z','')) AS fetched_at_ts,
    CAST(LEFT(REPLACE(fetched_at,'T',''),8) AS INT)                     AS fetched_date_key,
    CAST(SUBSTRING(REPLACE(fetched_at,'T',''), 10, 2) AS INT)           AS fetched_hour,
    vehicle_id,
    vehicle_label,
    trip_id,
    route_id,
    direction_id,
    latitude,
    longitude,
    bearing,
    speed_mps,
    current_stop_id,
    current_status,
    congestion_level,
    occupancy_status
FROM bronze.rt_vehicle_positions
WHERE NOT EXISTS (
    SELECT 1
    FROM silver.fact_vehicle_positions fvp
    WHERE fvp.vehicle_id     = bronze.rt_vehicle_positions.vehicle_id
      AND fvp.fetched_at_ts  = TRY_CONVERT(DATETIME2,
              REPLACE(REPLACE(bronze.rt_vehicle_positions.fetched_at,'T',' '),'Z',''))
);
GO

PRINT 'Silver layer populated.';
GO
