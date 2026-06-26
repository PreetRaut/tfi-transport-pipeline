-- ================================================================
-- TRANSFORM: Silver → Gold
-- TFI Transport Analytics Pipeline
-- ================================================================

-- ── 1. route_daily_performance ────────────────────────────────────
MERGE gold.route_daily_performance AS target
USING (
    SELECT
        d.fetched_date_key                                                  AS date_key,
        r.route_id,
        r.route_short_name,
        r.route_long_name,
        a.agency_name,
        r.route_type_desc,
        -- Scheduled trips (distinct count)
        sched.total_scheduled_trips,
        sched.total_scheduled_stops,
        -- Delay metrics
        COUNT(d.delay_id)                                                   AS total_delay_observations,
        AVG(CAST(d.arrival_delay_secs AS FLOAT) / 60.0)                    AS avg_arrival_delay_mins,
        AVG(CAST(d.departure_delay_secs AS FLOAT) / 60.0)                  AS avg_departure_delay_mins,
        CAST(SUM(CASE WHEN d.delay_band = 'On-Time' THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                        AS pct_on_time,
        CAST(SUM(CASE WHEN d.delay_band = 'Minor'    THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                        AS pct_minor_delay,
        CAST(SUM(CASE WHEN d.delay_band = 'Moderate' THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                        AS pct_moderate_delay,
        CAST(SUM(CASE WHEN d.delay_band = 'Severe'   THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                        AS pct_severe_delay,
        MAX(CAST(d.arrival_delay_secs AS FLOAT) / 60.0)                    AS max_delay_mins,
        -- Vehicle activity
        vp.active_vehicles,
        vp.avg_speed_kmh
    FROM silver.fact_realtime_delays d
    INNER JOIN silver.dim_route r ON r.route_id = d.route_id
    LEFT  JOIN silver.dim_agency a ON a.agency_id = r.agency_id
    -- Scheduled counts subquery
    LEFT JOIN (
        SELECT route_id,
               COUNT(DISTINCT trip_id)     AS total_scheduled_trips,
               COUNT(stop_id)              AS total_scheduled_stops
        FROM silver.fact_scheduled_departures
        GROUP BY route_id
    ) sched ON sched.route_id = d.route_id
    -- Vehicle speed subquery
    LEFT JOIN (
        SELECT route_id,
               fetched_date_key,
               COUNT(DISTINCT vehicle_id)                            AS active_vehicles,
               AVG(CAST(speed_mps * 3.6 AS DECIMAL(6,1)))           AS avg_speed_kmh
        FROM silver.fact_vehicle_positions
        WHERE speed_mps IS NOT NULL AND speed_mps > 0
        GROUP BY route_id, fetched_date_key
    ) vp ON vp.route_id = d.route_id AND vp.fetched_date_key = d.fetched_date_key
    GROUP BY
        d.fetched_date_key, r.route_id, r.route_short_name, r.route_long_name,
        a.agency_name, r.route_type_desc,
        sched.total_scheduled_trips, sched.total_scheduled_stops,
        vp.active_vehicles, vp.avg_speed_kmh
) AS source
ON target.date_key = source.date_key AND target.route_id = source.route_id
WHEN MATCHED THEN UPDATE SET
    avg_arrival_delay_mins   = source.avg_arrival_delay_mins,
    avg_departure_delay_mins = source.avg_departure_delay_mins,
    pct_on_time              = source.pct_on_time,
    pct_minor_delay          = source.pct_minor_delay,
    pct_moderate_delay       = source.pct_moderate_delay,
    pct_severe_delay         = source.pct_severe_delay,
    max_delay_mins           = source.max_delay_mins,
    active_vehicles          = source.active_vehicles,
    avg_speed_kmh            = source.avg_speed_kmh,
    _refreshed_at            = GETDATE()
WHEN NOT MATCHED THEN INSERT (
    date_key, route_id, route_short_name, route_long_name, agency_name, route_type_desc,
    total_scheduled_trips, total_scheduled_stops, total_delay_observations,
    avg_arrival_delay_mins, avg_departure_delay_mins,
    pct_on_time, pct_minor_delay, pct_moderate_delay, pct_severe_delay, max_delay_mins,
    active_vehicles, avg_speed_kmh
) VALUES (
    source.date_key, source.route_id, source.route_short_name, source.route_long_name,
    source.agency_name, source.route_type_desc,
    source.total_scheduled_trips, source.total_scheduled_stops, source.total_delay_observations,
    source.avg_arrival_delay_mins, source.avg_departure_delay_mins,
    source.pct_on_time, source.pct_minor_delay, source.pct_moderate_delay,
    source.pct_severe_delay, source.max_delay_mins,
    source.active_vehicles, source.avg_speed_kmh
);
GO

-- ── 2. stop_delay_hotspot ─────────────────────────────────────────
MERGE gold.stop_delay_hotspot AS target
USING (
    SELECT
        s.stop_id,
        s.stop_name,
        s.stop_lat,
        s.stop_lon,
        s.county,
        s.is_city_centre,
        d.fetched_date_key                                              AS date_key,
        COUNT(d.delay_id)                                               AS total_observations,
        AVG(CAST(d.arrival_delay_secs AS FLOAT) / 60.0)                AS avg_arrival_delay_mins,
        CAST(SUM(CASE WHEN d.delay_band = 'On-Time' THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                    AS pct_on_time,
        -- Worst route at this stop
        (   SELECT TOP 1 d2.route_id
            FROM silver.fact_realtime_delays d2
            WHERE d2.stop_id = d.stop_id AND d2.fetched_date_key = d.fetched_date_key
            GROUP BY d2.route_id
            ORDER BY AVG(CAST(d2.arrival_delay_secs AS FLOAT)) DESC
        )                                                               AS worst_route
    FROM silver.fact_realtime_delays d
    INNER JOIN silver.dim_stop s ON s.stop_id = d.stop_id
    GROUP BY s.stop_id, s.stop_name, s.stop_lat, s.stop_lon,
             s.county, s.is_city_centre, d.fetched_date_key
) AS source
ON target.stop_id = source.stop_id AND target.date_key = source.date_key
WHEN MATCHED THEN UPDATE SET
    avg_arrival_delay_mins = source.avg_arrival_delay_mins,
    pct_on_time            = source.pct_on_time,
    worst_route            = source.worst_route,
    _refreshed_at          = GETDATE()
WHEN NOT MATCHED THEN INSERT (
    stop_id, stop_name, stop_lat, stop_lon, county, is_city_centre,
    date_key, total_observations, avg_arrival_delay_mins, pct_on_time, worst_route
) VALUES (
    source.stop_id, source.stop_name, source.stop_lat, source.stop_lon,
    source.county, source.is_city_centre,
    source.date_key, source.total_observations,
    source.avg_arrival_delay_mins, source.pct_on_time, source.worst_route
);
GO

-- ── 3. hourly_network_pattern ─────────────────────────────────────
MERGE gold.hourly_network_pattern AS target
USING (
    SELECT
        d.fetched_date_key                                              AS date_key,
        d.fetched_hour                                                  AS hour_of_day,
        t.period                                                        AS time_period,
        dd.day_name,
        dd.is_weekend,
        sched.scheduled_departures,
        COUNT(d.delay_id)                                               AS delay_observations,
        AVG(CAST(d.arrival_delay_secs AS FLOAT) / 60.0)                AS avg_delay_mins,
        CAST(SUM(CASE WHEN d.delay_band = 'On-Time' THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                    AS pct_on_time,
        vp.active_vehicles,
        vp.avg_speed_kmh
    FROM silver.fact_realtime_delays d
    LEFT JOIN silver.dim_time_of_day t  ON t.hour = d.fetched_hour AND t.minute = 0
    LEFT JOIN silver.dim_date dd        ON dd.date_key = d.fetched_date_key
    LEFT JOIN (
        SELECT departure_hour, COUNT(*) AS scheduled_departures
        FROM silver.fact_scheduled_departures
        GROUP BY departure_hour
    ) sched ON sched.departure_hour = d.fetched_hour
    LEFT JOIN (
        SELECT fetched_date_key, fetched_hour,
               COUNT(DISTINCT vehicle_id)                AS active_vehicles,
               AVG(CAST(speed_mps * 3.6 AS DECIMAL(6,1))) AS avg_speed_kmh
        FROM silver.fact_vehicle_positions
        WHERE speed_mps IS NOT NULL AND speed_mps > 0
        GROUP BY fetched_date_key, fetched_hour
    ) vp ON vp.fetched_date_key = d.fetched_date_key AND vp.fetched_hour = d.fetched_hour
    GROUP BY d.fetched_date_key, d.fetched_hour, t.period, dd.day_name, dd.is_weekend,
             sched.scheduled_departures, vp.active_vehicles, vp.avg_speed_kmh
) AS source
ON target.date_key = source.date_key AND target.hour_of_day = source.hour_of_day
WHEN MATCHED THEN UPDATE SET
    avg_delay_mins   = source.avg_delay_mins,
    pct_on_time      = source.pct_on_time,
    active_vehicles  = source.active_vehicles,
    avg_speed_kmh    = source.avg_speed_kmh,
    _refreshed_at    = GETDATE()
WHEN NOT MATCHED THEN INSERT (
    date_key, hour_of_day, time_period, day_name, is_weekend,
    scheduled_departures, delay_observations, avg_delay_mins, pct_on_time,
    active_vehicles, avg_speed_kmh
) VALUES (
    source.date_key, source.hour_of_day, source.time_period, source.day_name, source.is_weekend,
    source.scheduled_departures, source.delay_observations, source.avg_delay_mins, source.pct_on_time,
    source.active_vehicles, source.avg_speed_kmh
);
GO

-- ── 4. operator_weekly_scorecard ─────────────────────────────────
MERGE gold.operator_weekly_scorecard AS target
USING (
    SELECT
        DATEADD(DAY, 1 - DATEPART(WEEKDAY, dd.full_date), dd.full_date) AS week_start_date,
        FORMAT(DATEADD(DAY, 1 - DATEPART(WEEKDAY, dd.full_date), dd.full_date),
               'yyyy-W') + RIGHT('0' + CAST(DATEPART(ISO_WEEK, dd.full_date) AS NVARCHAR), 2)
                                                                         AS week_label,
        a.agency_name,
        a.operator_type,
        COUNT(DISTINCT r.route_id)                                       AS route_count,
        COUNT(d.delay_id)                                                AS total_delay_obs,
        AVG(CAST(d.arrival_delay_secs AS FLOAT) / 60.0)                  AS avg_delay_mins,
        CAST(SUM(CASE WHEN d.delay_band = 'On-Time' THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                      AS pct_on_time,
        CAST(SUM(CASE WHEN d.delay_band = 'Severe'  THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                      AS pct_severe_delay
    FROM silver.fact_realtime_delays d
    INNER JOIN silver.dim_route  r  ON r.route_id  = d.route_id
    INNER JOIN silver.dim_agency a  ON a.agency_id = r.agency_id
    INNER JOIN silver.dim_date   dd ON dd.date_key = d.fetched_date_key
    GROUP BY
        DATEADD(DAY, 1 - DATEPART(WEEKDAY, dd.full_date), dd.full_date),
        FORMAT(DATEADD(DAY, 1 - DATEPART(WEEKDAY, dd.full_date), dd.full_date),
               'yyyy-W') + RIGHT('0' + CAST(DATEPART(ISO_WEEK, dd.full_date) AS NVARCHAR), 2),
        a.agency_name, a.operator_type
) AS source
ON target.week_start_date = source.week_start_date AND target.agency_name = source.agency_name
WHEN MATCHED THEN UPDATE SET
    total_delay_obs  = source.total_delay_obs,
    avg_delay_mins   = source.avg_delay_mins,
    pct_on_time      = source.pct_on_time,
    pct_severe_delay = source.pct_severe_delay,
    reliability_score = CAST(source.pct_on_time * 0.7
                           + (100 - COALESCE(source.pct_severe_delay, 0)) * 0.3 AS DECIMAL(5,2)),
    reliability_band = CASE
        WHEN source.pct_on_time >= 90 THEN 'Excellent'
        WHEN source.pct_on_time >= 75 THEN 'Good'
        WHEN source.pct_on_time >= 60 THEN 'Fair'
        ELSE 'Poor'
    END,
    _refreshed_at    = GETDATE()
WHEN NOT MATCHED THEN INSERT (
    week_start_date, week_label, agency_name, operator_type, route_count,
    total_delay_obs, avg_delay_mins, pct_on_time, pct_severe_delay,
    reliability_score, reliability_band
) VALUES (
    source.week_start_date, source.week_label, source.agency_name, source.operator_type,
    source.route_count, source.total_delay_obs, source.avg_delay_mins, source.pct_on_time,
    source.pct_severe_delay,
    CAST(source.pct_on_time * 0.7 + (100 - COALESCE(source.pct_severe_delay, 0)) * 0.3 AS DECIMAL(5,2)),
    CASE
        WHEN source.pct_on_time >= 90 THEN 'Excellent'
        WHEN source.pct_on_time >= 75 THEN 'Good'
        WHEN source.pct_on_time >= 60 THEN 'Fair'
        ELSE 'Poor'
    END
);
GO

-- ── 5. delay_trend_daily ─────────────────────────────────────────
MERGE gold.delay_trend_daily AS target
USING (
    SELECT
        d.fetched_date_key                                              AS date_key,
        dd.full_date,
        dd.day_name,
        dd.is_weekend,
        COUNT(d.delay_id)                                               AS total_observations,
        AVG(CAST(d.arrival_delay_secs AS FLOAT) / 60.0)                AS avg_delay_mins,
        CAST(SUM(CASE WHEN d.delay_band = 'On-Time' THEN 1 ELSE 0 END) * 100.0
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                    AS pct_on_time
    FROM silver.fact_realtime_delays d
    INNER JOIN silver.dim_date dd ON dd.date_key = d.fetched_date_key
    GROUP BY d.fetched_date_key, dd.full_date, dd.day_name, dd.is_weekend
) AS source
ON target.date_key = source.date_key
WHEN MATCHED THEN UPDATE SET
    total_observations = source.total_observations,
    avg_delay_mins     = source.avg_delay_mins,
    pct_on_time        = source.pct_on_time,
    -- Rolling 7-day avg (window function as subquery for MERGE compatibility)
    rolling_7d_avg_delay = (
        SELECT AVG(CAST(d2.arrival_delay_secs AS FLOAT) / 60.0)
        FROM silver.fact_realtime_delays d2
        WHERE d2.fetched_date_key BETWEEN source.date_key - 6 AND source.date_key
    ),
    _refreshed_at = GETDATE()
WHEN NOT MATCHED THEN INSERT (
    date_key, full_date, day_name, is_weekend,
    total_observations, avg_delay_mins, pct_on_time,
    rolling_7d_avg_delay, rolling_7d_pct_on_time
) VALUES (
    source.date_key, source.full_date, source.day_name, source.is_weekend,
    source.total_observations, source.avg_delay_mins, source.pct_on_time,
    NULL, NULL
);
GO

PRINT 'Gold layer populated.';
GO
