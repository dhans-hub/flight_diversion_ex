Flight Diversion DC Airport Analysis

![CI](https://github.com/dhans-hub/flight_diversion_ex/actions/workflows/ci.yml/badge.svg)

This project was built entirely using an open source data stack of QGIS, PostGIS, and Python. The geodata such as airports, runways, and boundaries are also public and open source. When executed, the project mimics how an FAA safety team locates alternative airports in the Washington D.C area if an emergency occurs along the flight route. The tool tracks and calculates the top three airports to land at so long as the criteria for the distance and runway length parameters is met.



<!-- Add a screenshot of your QGIS map at docs/images/diversion_map.png, then uncomment:
![Diversion map](docs/images/diversion_map.png)
-->

## SHOWCASES

- **Spatial SQL:** `geography` casts for true distances, `ST_DWithin`, `ST_Distance`, `ST_Azimuth`,
  `ST_LineInterpolatePoint`, `ST_Segmentize`, `LATERAL` joins, and a set-returning SQL function.
- **Schema design:** constraints, an enum type, a generated column, GiST indexes (including an
  expression index on `geom::geography`).
- **Adapter views:** `src_airport` and `src_runway` isolate the analysis from the source tables, so
  real FAA data can be swapped in by editing two views.
- **Automation:** a PyQGIS script that loads, styles and groups the layers, adds range rings and
  rank labels, builds a print layout, and animates the aircraft with live re-ranking.
- **Testing:** CI builds the database in a PostGIS container and runs SQL assertions on every push.

## Quick start

### Option A: Docker

```bash
docker compose up -d          # creates faa_db and runs sql/01_*.sql then sql/02_*.sql
docker compose exec db psql -U postgres -d faa_db \
  -f /docker-entrypoint-initdb.d/tests/assertions.sql
```

### Option B: existing PostgreSQL with PostGIS

```bash
psql -v ON_ERROR_STOP=1 -d faa_db -f sql/01_dc_region_aviation_postgis.sql
psql -v ON_ERROR_STOP=1 -d faa_db -f sql/02_diversion_analysis.sql
psql -v ON_ERROR_STOP=1 -d faa_db -f sql/tests/assertions.sql
```

### QGIS

1. Open QGIS 3.x, then Plugins > Python Console > Show Editor.
2. Open `python/qgis_interview_map_upgrades.py`, edit the `CONFIG` block (host, database, user), and run it.
3. In the console, run `start_flight()` to animate the aircraft; the top three diversion airports
   re-rank as it moves. `stop_flight()` stops it.

Try it in SQL too:

```sql
SELECT rank, ident, longest_runway_ft, dist_nm, bearing_deg, eta_min FROM dcaviation.diversion_top3;
UPDATE dcaviation.sim_flight SET progress = 0.60;      -- move the aircraft
SELECT * FROM dcaviation.diversion_airports(7000, 150, 3);   -- stricter runway rule
```

## Repository layout

| Path | Purpose |
|---|---|
| `sql/01_dc_region_aviation_postgis.sql` | Schema, sample data, views and queries (airports, runways, airspace, flights) |
| `sql/02_diversion_analysis.sql` | Simulated flight, ranking function, range rings, diversion views |
| `sql/tests/assertions.sql` | SQL assertions used by CI |
| `python/qgis_interview_map_upgrades.py` | PyQGIS loader, styling, layout and animation |
| `.github/workflows/ci.yml` | Lint plus database build and tests |
| `docker-compose.yml` | Local PostGIS database |
| `DOCUMENTATION.md` | Design notes and details |

## Data and limitations

- Sample data (13 airports, 21 runways, circular airspace stand-ins) is approximate and illustrative.
  For real work, load the FAA NASR subscription (28-day cycle) and official airspace layers.
- The flight is simulated: position is a fraction of a route line, not live traffic.
- Ranking is by straight-line (geodesic) distance and runway length. It does not model weather, terrain,
  aircraft performance or airspace restrictions.

## License

MIT. See `LICENSE`.
