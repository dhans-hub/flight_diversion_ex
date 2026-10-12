# Real-Time Flight Path & Dynamic Diversion Airport Analysis

An interactive aviation mapping stack built for **PostgreSQL + PostGIS** and **QGIS 3.x**. This technical assignment analyzes live flight progress along a great-circle route and dynamically ranks the top three nearest diversion airports based on customizable physical constraints, such as minimum runway lengths and geodetic bounding criteria.

##  Architectural Design & Features

*   **Geodetic Precision:** Employs spatial indexing and distance metrics built on the WGS 84 ellipsoid (`ST_DWithin`, `ST_Distance`, `ST_Azimuth`) to calculate true headings, nautical distances, and Estimated Time of Arrival (ETA) without coordinate scale distortion.
*   **Decoupled Adapter Views:** Employs abstract baseline adapters (`src_airport`, `src_runway`) allowing the entire analysis script to be remapped to different regional datasets (e.g., live FAA/NIMA vector sets) without breaking down stream logic.
*   **Automated Workspace Provisioning:** The PyQGIS script dynamically builds layered group trees, optimizes rendering thresholds to filter canvas clutter, links contextual meteorological feeds (NEXRAD), and instantiates a standard standalone Print Layout.

---

##  Repository Layout

```text
├── .github/
│   └── workflows/
│       └── ci.yml               # Automated pipeline testing environment
├── sql/
│   ├── dc_region_aviation_postgis.sql  # Database schema definition and seed data
│   └── diversion_analysis.sql          # Optimized PostGIS routing functions & analytic views
├── python/
│   └── qgis_interview_map_upgrades.py  # Automation script for QGIS environment setup
└── README.md                           # Operational documentation and run guides
```

---

## 🛠️ Installation & Setup

### 1. Database Configuration (PostgreSQL/PostGIS)
Ensure you have a PostgreSQL instance running with the `postgis` extension enabled.

1. Execute your structural schema setup:
   ```bash
   psql -h localhost -U postgres -d faa_db -f sql/dc_region_aviation_postgis.sql
   ```
2. Execute the optimized analytic functions and spatial tracking views:
   ```bash
   psql -h localhost -U postgres -d faa_db -f sql/diversion_analysis.sql
   ```

### 2. QGIS Environment Automation
1. Launch **QGIS 3.x** and open your targeted working project profile.
2. Open the file `python/qgis_interview_map_upgrades.py`.
3. Locate the `=== CONFIG ===` block near the top of the file and adjust your database connection string properties (`HOST`, `PORT`, `DBNAME`, `USER`, `PASSWORD`, or `AUTHCFG`) as needed.
4. Navigate to the top application menu bar and choose: **Plugins > Python Console**.
5. Within the console workspace panel, click **Show Editor**, open the modified script, and click **Run Script** (the green play arrow).

---

## ✈️ Running the Live Flight Simulation

Once the PyQGIS deployment script finishes provisioning your layers and workspace canvas, the active flight simulation engine can be manipulated natively from the QGIS Python Console.

### Start the Simulation
Initiate real-time position updates and dynamic re-ranking calculations by calling:
```python
start_flight(start=0.30, step=0.01, interval_ms=800)
```
*   `start`: Floating-point value representing the initial percentage position along the flight path vector (`0.0` to `1.0`).
*   `step`: The progression increment rate updated at each step calculation.
*   `interval_ms`: The physical evaluation timer loop delay expressed in milliseconds.

### Stop the Simulation
To halt the spatial computation thread loop at any time, execute:
```python
stop_flight()
```

---

##  Validation & Technical Verification

To test that your environment is rendering calculations identically inside the data store, you can sample the relational tracking outputs manually within a PostgreSQL terminal window:

```sql
-- Track real-time telemetry coordinates and computed spheroid headings
SELECT * FROM dcaviation.aircraft_position;

-- Extract instantaneous metrics for the top 3 nearest compliant diversion layers
SELECT rank, ident, longest_runway_ft, dist_nm, bearing_deg, eta_min 
FROM dcaviation.diversion_top3;
```

---
