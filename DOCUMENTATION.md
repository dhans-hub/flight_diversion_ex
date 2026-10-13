# Documentation

## Overview

Given a simulated aircraft position, the database returns the three closest airports that meet a
minimum runway length, with distance (NM), bearing, and ETA. QGIS layers read database views, so
moving the aircraft (updating one number) refreshes everything.

## Data model (schema `dcaviation`)

- `airport`, `runway`, `navaid`, `obstacle`: reference data with typed geometry columns (SRID 4326).
- `airspace`: a polygon plus vertical limits in feet MSL. `kind` is an enum
  (`CLASS_B`, `CLASS_C`, `CLASS_D`, `SFRA`, `FRZ`, `PROHIBITED`).
- `study_area`: the region center and radius, stored as data so the radius can change without code changes.
- `flight`, `track_point`: sample flights with synthetic position reports.
- `sim_flight`: the simulated flight used by the diversion analysis. `progress` (0 to 1) positions the aircraft.
- `map_message`: a point feature with a hover message, used to demonstrate map tips.

Integrity: `CHECK` constraints (ceiling above floor, valid polygons, squawk format), foreign keys, and a
generated column for obstacle AMSL height.

## Diversion analysis (`sql/02_diversion_analysis.sql`)

| Object | Role |
|---|---|
| `src_airport`, `src_runway` | Adapter views. Point them at real tables to reuse the analysis |
| `aircraft_position` | Point from `ST_LineInterpolatePoint`, heading from `ST_Azimuth` on the spheroid |
| `diversion_airports(min_runway_ft, max_nm, n)` | Candidates within `max_nm`, filtered by runway length, ranked by `ST_Distance` on geography |
| `diversion_top3` | Map-ready view of the top 3 |
| `diversion_top3_rings`, `diversion_legs` | 20 NM rings and great-circle legs to each airport |
| `range_rings` | 25/50/100 NM rings around the aircraft |
| `regional_buffer_150nm` | 150 NM buffer built on the spheroid |

## Design decisions and pitfalls

- **Geography for measurement, geometry for indexing.** Distances use `::geography` (metres on the ellipsoid).
  Casting bypasses a plain geometry index, so the schema adds GiST indexes on `(geom::geography)`.
- **Web Mercator buffers are wrong.** EPSG:3857 stretches distances by 1/cos(latitude). A "150 NM" buffer
  drawn in it covers only about 117 NM on the ground at Washington's latitude. The project builds buffers
  on the spheroid and offers an equidistant project CRS in QGIS. A check in the SQL shows the ratio.
- **`search_path` in SQL functions.** Unqualified names inside a SQL function body are resolved with the
  caller's `search_path`. Because QGIS connects with the default path, the functions set
  `SET search_path = dcaviation, public`. Without it, `diversion_top3` would fail from QGIS.
- **Runway geometry.** Real centerlines come from FAA NASR runway-end coordinates. The sample data generates
  each centerline from the reference point, heading, length and offset (true heading is magnetic minus about 10 degrees for DC).
- **Simplified airspace.** Circles stand in for irregular FAA polygons. Alert rules (prohibited area, FRZ,
  SFRA transponder code, Class B clearance) are simplified for illustration.

## Using real data

1. Load NASR airports and runways (and FAA airspace layers) into PostGIS.
2. Repoint `src_airport` and `src_runway` in `02_diversion_analysis.sql` to those tables.
3. Add `CREATE INDEX ... USING gist ((geom::geography))` on the airport table.
4. Replace the `route` in `sim_flight` with your own LineString.

## Testing and CI

`.github/workflows/ci.yml` starts a `postgis/postgis` container, lints the Python script with flake8
(syntax errors and undefined names fail the build), runs both SQL files with `ON_ERROR_STOP`, then
runs `sql/tests/assertions.sql`. The assertions check row counts, the 70-mile region, runway geometry,
alert behaviour, the buffer check, and the diversion ranking (ordering, runway filter, heading, and
that moving the aircraft changes the result).

## Troubleshooting

- **QGIS layer fails to load:** confirm both SQL files ran and the `CONFIG` block matches your database.
- **Map Tips don't show:** they only work for the active layer; select it and enable View > Show Map Tips.
- **Plane icon points the wrong way:** adjust `PLANE_ANGLE_OFFSET` in the script.
