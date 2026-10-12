# Real-Time Flight Path & Dynamic Diversion Airport Analysis

An interactive aviation mapping stack built for PostgreSQL + PostGIS and QGIS 3.x. This technical assignment analyzes live flight progress along a great-circle route and dynamically ranks the top three nearest diversion airports based on customizable physical constraints.

## Architectural Design

* Geodetic Precision: Employs spatial indexing and distance metrics built on the WGS 84 ellipsoid (ST_DWithin, ST_Distance, ST_Azimuth) to calculate true headings, nautical distances, and ETA without coordinate scale distortion.
* Decoupled Adapter Views: Employs abstract baseline adapters (src_airport, src_runway) allowing the entire analysis script to be remapped to different regional datasets without breaking downstream logic.

## Repository Layout

* .github/workflows/ci.yml - Automated pipeline testing environment
* sql/spatial_routing_analysis.sql - Optimized PostGIS routing functions & analytic views
* python/qgis_interview_map_upgrades.py - Automation script for QGIS environment setup
* DOCUMENTATION.md - Project documentation and run guides

## Installation & Setup

### 1. Database Configuration
Ensure you have a PostgreSQL instance running with the postgis extension enabled.
```bash
psql -h localhost -U postgres -d faa_db -f sql/spatial_routing_analysis.sql
```

### 2. QGIS Environment Automation
1. Launch QGIS 3.x and open your targeted working project profile.
2. Open the file python/qgis_interview_map_upgrades.py.
3. Open the Python Console (Plugins > Python Console > Show Editor).
4. Run the script, then type start_flight() into the console to watch the aircraft move and the top 3 diversion airports calculate in real-time.
