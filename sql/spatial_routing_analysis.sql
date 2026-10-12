SET search_path = dcaviation, public;

CREATE OR REPLACE VIEW src_airport AS
SELECT airport_id, faa_id AS ident, name, elevation_ft, towered, arp AS geom
FROM airport;

CREATE OR REPLACE VIEW src_runway AS
SELECT airport_id, designator, length_ft
FROM runway;

CREATE OR REPLACE VIEW regional_buffer_150nm AS
SELECT 1 AS id,
       '150 NM buffer (geodesic)'::text AS name,
       150 AS radius_nm,
       ST_Buffer(center::geography, 150 * 1852.0, 64)::geometry(Polygon, 4326) AS geom
FROM study_area
WHERE name = 'DC 70-mile region';

CREATE TABLE IF NOT EXISTS sim_flight (
    callsign        text PRIMARY KEY,
    groundspeed_kt  integer NOT NULL CHECK (groundspeed_kt > 0),
    progress        numeric(5,4) NOT NULL DEFAULT 0.45 CHECK (progress BETWEEN 0 AND 1),
    route           geometry(LineString, 4326) NOT NULL
);

INSERT INTO sim_flight (callsign, groundspeed_kt, progress, route)
VALUES ('SIM100', 450, 0.45,
        ST_Segmentize(
            ST_MakeLine(ST_SetSRID(ST_MakePoint(-73.78, 40.64), 4326),
                        ST_SetSRID(ST_MakePoint(-84.43, 33.64), 4326))::geography,
            20000)::geometry)
ON CONFLICT (callsign) DO NOTHING;

CREATE INDEX IF NOT EXISTS sim_flight_route_gix ON sim_flight USING gist (route);

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

CREATE OR REPLACE VIEW range_rings AS
SELECT r.nm AS ring_nm,
       ST_Boundary(ST_Buffer(a.geom::geography, r.nm * 1852.0, 64)::geometry)::geometry(LineString, 4326) AS geom
FROM aircraft_position a
CROSS JOIN (VALUES (25), (50), (100)) AS r(nm);

CREATE OR REPLACE FUNCTION diversion_airports(
    p_min_runway_ft integer          DEFAULT 5000,
    p_max_nm        double precision DEFAULT 150,
    p_n             integer          DEFAULT 3)
RETURNS TABLE (rank integer, ident text, name text, elevation_ft integer, towered boolean,
               longest_runway_ft integer, dist_nm numeric, bearing_deg numeric,
               eta_min numeric, geom geometry)
LANGUAGE sql STABLE AS $$
    SELECT (row_number() OVER (ORDER BY d.dist_m))::integer,
           d.ident, d.name, d.elevation_ft, d.towered, d.longest,
           round((d.dist_m / 1852.0)::numeric, 1) AS dist_nm,
           round(degrees(ST_Azimuth(ac.geom::geography, d.geom::geography))::numeric, 0) AS bearing_deg,
           round((d.dist_m / 1852.0 / ac.groundspeed_kt * 60)::numeric, 0) AS eta_min,
           d.geom
    FROM aircraft_position ac
    CROSS JOIN LATERAL (
        SELECT a.ident, a.name, a.elevation_ft, a.towered, a.geom,
               max(r.length_ft)::integer AS longest,
               ST_Distance(a.geom::geography, ac.geom::geography) AS dist_m
        FROM src_airport a
        JOIN src_runway r USING (airport_id)
        WHERE ST_DWithin(a.geom::geography, ac.geom::geography, p_max_nm * 1852.0)
        GROUP BY a.airport_id, a.ident, a.name, a.elevation_ft, a.towered, a.geom
        HAVING max(r.length_ft) >= p_min_runway_ft
    ) d
    ORDER BY d.dist_m
    LIMIT p_n
$$;

CREATE OR REPLACE VIEW diversion_top3 AS
SELECT rank, ident, name, elevation_ft, towered, longest_runway_ft,
       dist_nm, bearing_deg, eta_min,
       geom::geometry(Point, 4326) AS geom
FROM diversion_airports(5000, 150, 3);

CREATE OR REPLACE VIEW diversion_top3_rings AS
SELECT rank, ident,
       ST_Buffer(geom::geography, 20 * 1852.0, 48)::geometry(Polygon, 4326) AS geom
FROM diversion_top3;

CREATE OR REPLACE VIEW diversion_legs AS
SELECT d.rank, d.ident, d.dist_nm, d.eta_min,
       ST_Segmentize(ST_MakeLine(a.geom, d.geom)::geography, 10000)::geometry(LineString, 4326) AS geom
FROM diversion_top3 d
CROSS JOIN aircraft_position a;
