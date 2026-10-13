-- =====================================================================
-- Diversion-airport analysis for the interview map (PostgreSQL + PostGIS)
-- Run AFTER 01_dc_region_aviation_postgis.sql (uses schema dcaviation).
--
-- Adds:
--   * adapter views, so you can point everything at your OWN airport tables
--   * sim_flight: a simulated flight whose position is driven by "progress"
--   * aircraft_position (with heading), range_rings (25/50/100 NM)
--   * diversion_airports(): ranked by distance, with a minimum runway length
--   * diversion_top3, diversion_top3_rings, diversion_legs (map-ready views)
--   * a geodesic 150 NM buffer and a Web Mercator buffer sanity check
--
-- Validated in CI against a PostGIS container (see sql/tests/assertions.sql).
-- Illustrative data. Not for navigation or flight planning.
-- =====================================================================
SET search_path = dcaviation, public;

-- ---------------------------------------------------------------------
-- 0. ADAPTER VIEWS: repoint these two at your real FAA tables
-- ---------------------------------------------------------------------
-- Defaults use the sample tables from the first script. To use your own data,
-- change only the FROM clauses and column names, e.g.
--   CREATE OR REPLACE VIEW src_airport AS
--   SELECT gid AS airport_id, ident, name, elev AS elevation_ft, false AS towered, geom
--   FROM public.your_airports;
-- and give your table a geography index for fast radius filters:
--   CREATE INDEX ON public.your_airports USING gist ((geom::geography));
CREATE OR REPLACE VIEW src_airport AS
SELECT airport_id, faa_id AS ident, name, elevation_ft, towered, arp AS geom
FROM airport;

CREATE OR REPLACE VIEW src_runway AS
SELECT airport_id, designator, length_ft
FROM runway;

-- ---------------------------------------------------------------------
-- 1. 150 NM REGIONAL BUFFER, built on the spheroid (true distance)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW regional_buffer_150nm AS
SELECT 1 AS id,
       '150 NM buffer (geodesic)'::text AS name,
       150 AS radius_nm,
       ST_Buffer(center::geography, nm_to_m(150), 64)::geometry(Polygon, 4326) AS geom
FROM study_area
WHERE name = 'DC 70-mile region';

-- Sanity check: why not buffer in Web Mercator (EPSG:3857)?
-- Its units are stretched by 1/cos(latitude), so a "150 NM" buffer drawn there is
-- only about 117 NM on the ground at this latitude (ground area ratio about 0.61).
WITH c AS (
    SELECT center FROM study_area WHERE name = 'DC 70-mile region'
), r AS (
    SELECT ST_Area(ST_Transform(ST_Buffer(ST_Transform(center, 3857), 150 * 1852.0), 4326)::geography)
           / ST_Area(ST_Buffer(center::geography, 150 * 1852.0)) AS ratio
    FROM c
)
SELECT round(ratio::numeric, 3)                     AS ground_area_ratio,
       round((150 * sqrt(ratio))::numeric, 1)       AS effective_ground_radius_nm
FROM r;

-- ---------------------------------------------------------------------
-- 2. SIMULATED FLIGHT (one active flight; move it by changing "progress")
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sim_flight (
    callsign        text PRIMARY KEY,
    groundspeed_kt  integer NOT NULL CHECK (groundspeed_kt > 0),
    progress        numeric(5,4) NOT NULL DEFAULT 0.45 CHECK (progress BETWEEN 0 AND 1),
    route           geometry(LineString, 4326) NOT NULL
);

-- Default route: great-circle-style line from the New York area to Atlanta.
-- Replace "route" with your own geometry if you like.
INSERT INTO sim_flight (callsign, groundspeed_kt, progress, route)
VALUES ('SIM100', 450, 0.45,
        ST_Segmentize(
            ST_MakeLine(ST_SetSRID(ST_MakePoint(-73.78, 40.64), 4326),
                        ST_SetSRID(ST_MakePoint(-84.43, 33.64), 4326))::geography,
            20000)::geometry)
ON CONFLICT (callsign) DO NOTHING;

CREATE INDEX IF NOT EXISTS sim_flight_route_gix ON sim_flight USING gist (route);

-- Current position and true heading (heading from ST_Azimuth on the spheroid)
CREATE OR REPLACE VIEW aircraft_position AS
SELECT callsign,
       groundspeed_kt,
       progress,
       ST_LineInterpolatePoint(route, progress::float8)::geometry(Point, 4326) AS geom,
       round(degrees(ST_Azimuth(
           ST_LineInterpolatePoint(route, GREATEST(progress::float8 - 0.002, 0))::geography,
           ST_LineInterpolatePoint(route, LEAST(progress::float8 + 0.002, 1))::geography
       ))::numeric, 1) AS heading_deg
FROM sim_flight;

-- ---------------------------------------------------------------------
-- 3. RANGE RINGS around the aircraft (25 / 50 / 100 NM)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW range_rings AS
SELECT r.nm AS ring_nm,
       ST_Boundary(ST_Buffer(a.geom::geography, nm_to_m(r.nm), 64)::geometry)::geometry(LineString, 4326) AS geom
FROM aircraft_position a
CROSS JOIN (VALUES (25), (50), (100)) AS r(nm);

-- ---------------------------------------------------------------------
-- 4. DIVERSION AIRPORT RANKING
--    Candidate = airport within p_max_nm of the aircraft with a runway of at
--    least p_min_runway_ft. Ranked by true (geodesic) distance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION diversion_airports(
    p_min_runway_ft integer          DEFAULT 5000,
    p_max_nm        double precision DEFAULT 150,
    p_n             integer          DEFAULT 3)
RETURNS TABLE (rank integer, ident text, name text, elevation_ft integer, towered boolean,
               longest_runway_ft integer, dist_nm numeric, bearing_deg numeric,
               eta_min numeric, geom geometry)
LANGUAGE sql STABLE
SET search_path = dcaviation, public   -- required: QGIS/other sessions do not have this schema on their search_path
AS $$
    SELECT (row_number() OVER (ORDER BY d.dist_m))::integer,
           d.ident, d.name, d.elevation_ft, d.towered, d.longest,
           round((d.dist_m / 1852.0)::numeric, 1),
           round(degrees(ST_Azimuth(ac.geom::geography, d.geom::geography))::numeric, 0),
           round((d.dist_m / 1852.0 / ac.groundspeed_kt * 60)::numeric, 0),
           d.geom
    FROM aircraft_position ac
    CROSS JOIN LATERAL (
        SELECT a.ident, a.name, a.elevation_ft, a.towered, a.geom,
               max(r.length_ft)::integer AS longest,
               ST_Distance(a.geom::geography, ac.geom::geography) AS dist_m
        FROM src_airport a
        JOIN src_runway r USING (airport_id)
        WHERE ST_DWithin(a.geom::geography, ac.geom::geography, nm_to_m(p_max_nm))
        GROUP BY a.airport_id, a.ident, a.name, a.elevation_ft, a.towered, a.geom
        HAVING max(r.length_ft) >= p_min_runway_ft
    ) d
    ORDER BY d.dist_m
    LIMIT p_n
$$;

-- Map-ready views (edit the numbers here to change the rule)
CREATE OR REPLACE VIEW diversion_top3 AS
SELECT rank, ident, name, elevation_ft, towered, longest_runway_ft,
       dist_nm, bearing_deg, eta_min,
       geom::geometry(Point, 4326) AS geom
FROM diversion_airports(5000, 150, 3);

-- Light 20 NM rings around each diversion airport
CREATE OR REPLACE VIEW diversion_top3_rings AS
SELECT rank, ident,
       ST_Buffer(geom::geography, nm_to_m(20), 48)::geometry(Polygon, 4326) AS geom
FROM diversion_top3;

-- Great-circle legs from the aircraft to each diversion airport
CREATE OR REPLACE VIEW diversion_legs AS
SELECT d.rank, d.ident, d.dist_nm, d.eta_min,
       ST_Segmentize(ST_MakeLine(a.geom, d.geom)::geography, 10000)::geometry(LineString, 4326) AS geom
FROM diversion_top3 d
CROSS JOIN aircraft_position a;

-- ---------------------------------------------------------------------
-- 5. TRY IT
-- ---------------------------------------------------------------------
SELECT * FROM aircraft_position;
SELECT rank, ident, longest_runway_ft, dist_nm, bearing_deg, eta_min FROM diversion_top3;

-- Move the aircraft and re-rank (QGIS layers update on refresh):
-- UPDATE sim_flight SET progress = 0.60;
-- SELECT rank, ident, dist_nm, eta_min FROM diversion_top3;

-- Require a longer runway (e.g. a heavy jet):
-- SELECT * FROM diversion_airports(7000, 150, 3);
-- With the sample data you will see DC-area airports. Once src_airport points at
-- your full airport table, the top 3 will be the airports nearest the route
-- (for example Charlottesville).
