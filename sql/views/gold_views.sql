
CREATE OR ALTER VIEW gold.vw_route_performance AS
SELECT
    rdp.*,
    --  formatting
    performance_tier = CASE
        WHEN pct_on_time >= 90 THEN 'Excellent'
        WHEN pct_on_time >= 75 THEN 'Good'
        WHEN pct_on_time >= 60 THEN 'Fair'
        ELSE 'Poor'
    END,
    --  formatting
    tier_colour = CASE
        WHEN pct_on_time >= 90 THEN '#2ECC71'
        WHEN pct_on_time >= 75 THEN '#F39C12'
        WHEN pct_on_time >= 60 THEN '#E67E22'
        ELSE '#E74C3C'
    END,
    -- Rank 
    agency_rank = RANK() OVER (
        PARTITION BY agency_name, date_key
        ORDER BY pct_on_time DESC
    ),
    
    network_rank = RANK() OVER (
        PARTITION BY date_key
        ORDER BY pct_on_time DESC
    )
FROM gold.route_daily_performance rdp;
GO

-- ── 2. vw_delay_heatmap ──────────────────────────────────────────
-- Hour × Day matrix — feeds Tableau highlight table / heatmap
CREATE OR ALTER VIEW gold.vw_delay_heatmap AS
SELECT
    hnp.date_key,
    hnp.hour_of_day,
    hnp.time_period,
    hnp.day_name,
    hnp.is_weekend,
    hnp.scheduled_departures,
    hnp.delay_observations,
    hnp.avg_delay_mins,
    hnp.pct_on_time,
    hnp.active_vehicles,
    hnp.avg_speed_kmh,
    -- Severity index 0-100 for conditional colour
    severity_index = CAST(
        100 - COALESCE(hnp.pct_on_time, 100)
    AS DECIMAL(5,2)),
    -- Label for tooltip
    hour_label = RIGHT('0' + CAST(hnp.hour_of_day AS NVARCHAR), 2) + ':00'
FROM gold.hourly_network_pattern hnp;
GO

-- ── 3. vw_stop_map ───────────────────────────────────────────────
-- For Tableau map sheet — bubble map by delay severity
CREATE OR ALTER VIEW gold.vw_stop_map AS
SELECT
    sdh.stop_id,
    sdh.stop_name,
    sdh.stop_lat,
    sdh.stop_lon,
    sdh.county,
    sdh.is_city_centre,
    sdh.date_key,
    sdh.total_observations,
    sdh.avg_arrival_delay_mins,
    sdh.pct_on_time,
    sdh.worst_route,
    -- Bubble size (normalised 1-10 for map sizing)
    bubble_size = CAST(
        1 + (sdh.avg_arrival_delay_mins / NULLIF(
            MAX(sdh.avg_arrival_delay_mins) OVER (PARTITION BY sdh.date_key), 0
        )) * 9
    AS DECIMAL(4,1)),
    -- Delay severity label for tooltip
    delay_label = CASE
        WHEN sdh.pct_on_time >= 90 THEN 'On-Time'
        WHEN sdh.pct_on_time >= 75 THEN 'Minor delays'
        WHEN sdh.pct_on_time >= 60 THEN 'Moderate delays'
        ELSE 'Severe delays'
    END
FROM gold.stop_delay_hotspot sdh;
GO

-- ── 4. vw_operator_comparison ────────────────────────────────────
-- Operator scorecard with MoW (measure of work) trend
CREATE OR ALTER VIEW gold.vw_operator_comparison AS
SELECT
    ows.*,
    -- Reliability change vs prior week
    reliability_delta = reliability_score
        - LAG(reliability_score) OVER (
            PARTITION BY agency_name
            ORDER BY week_start_date
        ),
    -- Rank among operators this week
    weekly_rank = RANK() OVER (
        PARTITION BY week_start_date
        ORDER BY reliability_score DESC
    )
FROM gold.operator_weekly_scorecard ows;
GO

-- ── 5. vw_network_kpi ────────────────────────────────────────────
-- Single-row summary for Tableau KPI cards
CREATE OR ALTER VIEW gold.vw_network_kpi AS
SELECT
    MAX(date_key)                                                      AS latest_date_key,
    COUNT(DISTINCT route_id)                                           AS total_routes_monitored,
    SUM(total_delay_observations)                                      AS total_obs_today,
    AVG(pct_on_time)                                                   AS network_avg_on_time_pct,
    AVG(avg_arrival_delay_mins)                                        AS network_avg_delay_mins,
    MAX(max_delay_mins)                                                AS worst_delay_mins,
    -- Best and worst route today
    (SELECT TOP 1 route_short_name
     FROM gold.route_daily_performance
     WHERE date_key = MAX(rdp.date_key)
     ORDER BY pct_on_time DESC)                                        AS best_route,
    (SELECT TOP 1 route_short_name
     FROM gold.route_daily_performance
     WHERE date_key = MAX(rdp.date_key)
     ORDER BY pct_on_time ASC)                                         AS worst_route,
    CAST(GETDATE() AS NVARCHAR(30))                                    AS last_refreshed
FROM gold.route_daily_performance rdp
WHERE date_key = (SELECT MAX(date_key) FROM gold.route_daily_performance);
GO


CREATE OR ALTER VIEW gold.vw_delay_trend AS
SELECT
    dtd.*,
    -- MoM comparison label
    trend_label = CASE
        WHEN rolling_7d_avg_delay >
             LAG(rolling_7d_avg_delay) OVER (ORDER BY date_key)
        THEN '↑ Worsening'
        WHEN rolling_7d_avg_delay <
             LAG(rolling_7d_avg_delay) OVER (ORDER BY date_key)
        THEN '↓ Improving'
        ELSE '→ Stable'
    END
FROM gold.delay_trend_daily dtd;
GO

PRINT 'Gold views created.';
GO
