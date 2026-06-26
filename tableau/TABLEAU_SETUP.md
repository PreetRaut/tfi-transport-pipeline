# Tableau Public Setup Guide
# TFI Ireland — Real-Time Transport Analytics

## What you need
- Tableau Desktop Public Edition (free) — download at public.tableau.com/en/software/public
- Your Azure SQL Database running with gold views populated
- A Tableau Public account (free) to publish your workbook

---

## Part 1 — Connect Tableau to Azure SQL

1. Open **Tableau Desktop Public Edition**
2. Left panel → **Connect** → **Microsoft SQL Server**
3. Fill in:
   - Server: `sql-tfi-transport.database.windows.net`
   - Database: `tfi-transport-db`
   - Authentication: Use specific username and password
   - Username: `sqladmin`
   - Password: your password
4. Click **Sign In**

### Add your data sources (one per view)

In the Data Source tab, drag each view from the left panel:

| Tableau Data Source Name | Azure SQL View |
|--------------------------|----------------|
| Route Performance        | `gold.vw_route_performance` |
| Delay Heatmap            | `gold.vw_delay_heatmap` |
| Stop Map                 | `gold.vw_stop_map` |
| Operator Comparison      | `gold.vw_operator_comparison` |
| Network KPI              | `gold.vw_network_kpi` |
| Delay Trend              | `gold.vw_delay_trend` |

> **Tip**: Use **Extract** (not Live) for Tableau Public — Live connection
> is a Tableau Desktop paid feature. Extract saves a snapshot of the data
> into the workbook file (.twbx). Refresh the extract whenever you re-run
> the pipeline.

---

## Part 2 — Calculated Fields

In Tableau, right-click any dimension/measure → **Create Calculated Field**.
Paste each formula below.

### On Route Performance data source

**On-Time Colour** (for conditional bar colour)
```
IF [Pct On Time] >= 90 THEN "#2ECC71"
ELSEIF [Pct On Time] >= 75 THEN "#F39C12"
ELSEIF [Pct On Time] >= 60 THEN "#E67E22"
ELSE "#E74C3C"
END
```

**Performance Tier**
```
IF [Pct On Time] >= 90 THEN "Excellent"
ELSEIF [Pct On Time] >= 75 THEN "Good"
ELSEIF [Pct On Time] >= 60 THEN "Fair"
ELSE "Poor"
END
```

**Delay in Minutes (formatted)**
```
STR(ROUND([Avg Arrival Delay Mins], 1)) + " min"
```

### On Delay Heatmap data source

**Severity Index** (for colour on heatmap)
```
100 - IFNULL([Pct On Time], 100)
```

**Hour Label**
```
IF LEN(STR([Hour Of Day])) = 1
THEN "0" + STR([Hour Of Day]) + ":00"
ELSE STR([Hour Of Day]) + ":00"
END
```

### On Stop Map data source

**Delay Category**
```
IF [Pct On Time] >= 90 THEN "On-Time"
ELSEIF [Pct On Time] >= 75 THEN "Minor Delays"
ELSEIF [Pct On Time] >= 60 THEN "Moderate Delays"
ELSE "Severe Delays"
END
```

### On Operator Comparison data source

**Reliability Change Arrow**
```
IF [Reliability Delta] > 0 THEN "↑ Improving"
ELSEIF [Reliability Delta] < 0 THEN "↓ Worsening"
ELSE "→ Stable"
END
```

---

## Part 3 — Build the 5 Dashboard Sheets

### Sheet 1 — Network KPI Bar (Overview)

**Chart type**: Horizontal bar  
**Data source**: Route Performance  
**Steps**:
1. Drag `Route Short Name` → Rows
2. Drag `Pct On Time` → Columns
3. Drag `On-Time Colour` calculated field → Colour mark card
4. Sort descending by `Pct On Time`
5. Add reference line: Analytics pane → Reference Line → Value: 90 (the on-time target)
6. Title: **Route On-Time Performance (%)**

---

### Sheet 2 — Delay Heatmap (Hour × Day of Week)

**Chart type**: Text/Highlight table  
**Data source**: Delay Heatmap  
**Steps**:
1. Drag `Day Name` → Rows
2. Drag `Hour Label` → Columns
3. Drag `Avg Delay Mins` → Colour mark card
4. Drag `Avg Delay Mins` → Text mark card (shows value in cell)
5. Colour palette: **Temperature** diverging (white → red)
6. Sort Rows: Mon, Tue, Wed, Thu, Fri, Sat, Sun
7. Sort Columns: ascending by Hour
8. Title: **Avg Delay by Hour & Day of Week (mins)**

---

### Sheet 3 — Stop Delay Map

**Chart type**: Map  
**Data source**: Stop Map  
**Steps**:
1. Double-click `Stop Lat` — Tableau auto-generates a map
2. Drag `Stop Lon` to the Columns shelf (Tableau links the pair)
3. Drag `Avg Arrival Delay Mins` → Size mark card
4. Drag `Delay Category` → Colour mark card
5. Set colour: Green=On-Time, Yellow=Minor, Orange=Moderate, Red=Severe
6. Drag `Stop Name` → Tooltip
7. Drag `Worst Route` → Tooltip
8. Map style: **Light** (Map menu → Map Layers → Style)
9. Title: **Stop-Level Delay Hotspots**

---

### Sheet 4 — Operator Reliability Scorecard

**Chart type**: Packed bubbles or Side-by-side bars  
**Data source**: Operator Comparison  
**Steps**:
1. Drag `Agency Name` → Rows
2. Drag `Reliability Score` → Columns
3. Drag `Reliability Band` → Colour
4. Drag `Week Label` → Pages card (creates animated weekly playback)
5. Add `Pct On Time` as a dual axis (Columns → right-click → Dual Axis)
6. Title: **Operator Reliability Score by Week**

---

### Sheet 5 — 30-Day Delay Trend

**Chart type**: Line chart with reference band  
**Data source**: Delay Trend  
**Steps**:
1. Drag `Full Date` → Columns (set to continuous Date)
2. Drag `Pct On Time` → Rows (primary axis)
3. Drag `Rolling 7d Avg Delay` → Rows (dual axis, secondary)
4. Make primary axis a bar, secondary a line
5. Colour: bars = blue (pct on time), line = orange (rolling avg)
6. Analytics pane → Add Reference Line → Value: 90 (target line)
7. Title: **Network On-Time % — 30-Day Trend**

---

## Part 4 — Assemble the Dashboard

1. **New Dashboard** → size: **Automatic** (fits any screen)
2. Layout suggestion (drag sheets from left panel):

```
┌─────────────────────────────────────────────┐
│  [KPI Cards: 4 text boxes with big numbers]  │
│  On-Time%  |  Avg Delay  |  Routes  |  Vehs  │
├──────────────────────┬──────────────────────┤
│  Sheet 1             │  Sheet 5             │
│  Route Bar Chart     │  30-Day Trend Line   │
├──────────────────────┴──────────────────────┤
│  Sheet 2 — Delay Heatmap (full width)        │
├──────────────────────┬──────────────────────┤
│  Sheet 3 — Stop Map  │  Sheet 4 — Operators │
└──────────────────────┴──────────────────────┘
```

3. Add **Filters** (Dashboard menu → Actions → Filter):
   - Click any bar in Sheet 1 → filters Sheet 3 (stop map) and Sheet 5 (trend)
   - Click any cell in Sheet 2 → highlights Sheet 1

4. Add **text boxes** for the 4 KPI cards — manually type in the values or
   use a summary sheet feeding into a Crosstab.

---

## Part 5 — Publish to Tableau Public

1. **File → Save to Tableau Public As…**
2. Sign in with your Tableau Public account
3. Name it: `TFI Ireland Transport Analytics`
4. After publishing → copy the public URL
5. Add to your CV and LinkedIn as: **[View Dashboard →](your-url)**

> **Important**: Tableau Public workbooks are visible to everyone.
> Do NOT embed your Azure SQL password in a Live connection —
> always use Extract mode (password is not stored in the extract).

---

## Part 6 — Screenshot Checklist for GitHub

After publishing, take screenshots of each dashboard page and save:

```
tableau/screenshots/
  01_network_overview.png
  02_route_scorecard.png
  03_delay_heatmap.png
  04_stop_map.png
  05_operator_comparison.png
  06_trend_line.png
```

Add them to the README with:
```markdown
![Delay Heatmap](tableau/screenshots/03_delay_heatmap.png)
```

This makes your GitHub repo visually impressive for recruiters who never
click into code files.

---

## Tableau Public Tips for Interviews

- **Tableau Public URL on your CV** is stronger than a screenshot —
  interviewers can interact with it live
- Be ready to explain: "I used an Extract rather than a Live connection
  because Tableau Public doesn't support Live connections to Azure SQL —
  in a production environment I'd use Tableau Server or Tableau Cloud"
- The heatmap (Sheet 2) is the most visually distinctive — lead with it
- The stop map demonstrates geospatial thinking — mention lat/lon came
  from the raw GTFS stops.txt feed you parsed
