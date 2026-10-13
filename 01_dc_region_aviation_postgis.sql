-- =====================================================================
-- Washington, DC Region Aeronautical Database (PostgreSQL + PostGIS)
-- Major airports (DCA, IAD, BWI) + airports within 70 statute miles of DC,
-- DC-specific airspace (Class B/C/D, SFRA, FRZ, P-56), obstacles, flights.
--
-- ALL DATA IS ILLUSTRATIVE / APPROXIMATE. NOT FOR NAVIGATION OR FLIGHT
-- PLANNING. Replace with FAA NASR (28-day cycle), the Digital Obstacle
-- File, and official FAA airspace layers for real work.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
DROP SCHEMA IF EXISTS dcaviation CASCADE;   -- re-runnable: rebuilds the demo schema from scratch
CREATE SCHEMA dcaviation;
SET search_path = dcaviation, public;

-- ---------------------------------------------------------------------
-- 1. TYPES AND HELPERS
-- ---------------------------------------------------------------------
CREATE TYPE airspace_kind AS ENUM
  ('CLASS_B','CLASS_C','CLASS_D','SFRA','FRZ','PROHIBITED');

CREATE FUNCTION nm_to_m(nm double precision) RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$ SELECT nm * 1852.0 $$;

CREATE FUNCTION mi_to_m(mi double precision) RETURNS double precision   -- statute miles
LANGUAGE sql IMMUTABLE AS $$ SELECT mi * 1609.344 $$;

-- Circle of radius_nm around a point, built on the spheroid (geography)
CREATE FUNCTION circle_nm(center geometry, radius_nm double precision)
RETURNS geometry LANGUAGE sql IMMUTABLE
SET search_path = dcaviation, public      -- body calls nm_to_m(); resolve it regardless of caller
AS $$
    SELECT ST_Buffer(center::geography, nm_to_m(radius_nm), 16)::geometry
$$;

-- ---------------------------------------------------------------------
-- 2. SCHEMA
-- ---------------------------------------------------------------------

-- The "70 miles from DC" region is data, not a hard-coded constant
CREATE TABLE study_area (
    area_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text NOT NULL UNIQUE,
    center     geometry(Point, 4326) NOT NULL,
    radius_mi  numeric(6,1) NOT NULL CHECK (radius_mi > 0),
    boundary   geometry(Polygon, 4326) NOT NULL
);

CREATE TABLE airport (
    airport_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    faa_id        text NOT NULL UNIQUE,
    icao_id       text UNIQUE CHECK (icao_id ~ '^[A-Z0-9]{4}$'),
    name          text NOT NULL,
    state         char(2) NOT NULL CHECK (state IN ('DC','MD','VA','WV','PA','DE')),
    role          text NOT NULL
                  CHECK (role IN ('COMMERCIAL','MILITARY','RELIEVER','GENERAL_AVIATION')),
    elevation_ft  integer NOT NULL,
    towered       boolean NOT NULL DEFAULT false,
    arp           geometry(Point, 4326) NOT NULL    -- airport reference point
);

CREATE TABLE runway (
    runway_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    airport_id  integer NOT NULL REFERENCES airport ON DELETE CASCADE,
    designator  text NOT NULL,                      -- e.g. 01/19
    length_ft   integer NOT NULL CHECK (length_ft > 0),
    width_ft    integer NOT NULL CHECK (width_ft > 0),
    surface     text NOT NULL CHECK (surface IN ('ASPH','CONC','TURF','GRVL','WATER')),
    geom        geometry(LineString, 4326) NOT NULL, -- centerline
    UNIQUE (airport_id, designator)
);

CREATE TABLE navaid (
    navaid_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ident        text NOT NULL,
    navaid_type  text NOT NULL CHECK (navaid_type IN ('VOR','VORTAC','NDB','DME','TACAN')),
    freq_mhz     numeric(6,2),
    geom         geometry(Point, 4326) NOT NULL,
    UNIQUE (ident, navaid_type)
);

-- 2D polygon + vertical limits in ft MSL.
-- (Real FAA airspace data is MultiPolygon; widen the column type if you load it.)
CREATE TABLE airspace (
    airspace_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text NOT NULL,
    kind            airspace_kind NOT NULL,
    floor_ft_msl    integer NOT NULL CHECK (floor_ft_msl >= 0),
    ceiling_ft_msl  integer NOT NULL,
    boundary        geometry(Polygon, 4326) NOT NULL,
    CHECK (ceiling_ft_msl > floor_ft_msl),
    CHECK (ST_IsValid(boundary))
);

CREATE TABLE obstacle (
    obstacle_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    oas_number      text NOT NULL UNIQUE,
    description     text,
    obstacle_type   text NOT NULL CHECK (obstacle_type IN ('TOWER','CRANE','BUILDING','STACK','POLE')),
    agl_ft          integer NOT NULL CHECK (agl_ft > 0),
    ground_elev_ft  integer NOT NULL,
    amsl_ft         integer GENERATED ALWAYS AS (ground_elev_ft + agl_ft) STORED,
    lighted         boolean NOT NULL DEFAULT false,
    geom            geometry(Point, 4326) NOT NULL
);

CREATE TABLE flight (
    flight_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    callsign        text NOT NULL,
    aircraft_type   text NOT NULL,
    flight_rules    text NOT NULL CHECK (flight_rules IN ('IFR','VFR')),
    atc_clearance   boolean NOT NULL DEFAULT false,
    squawk          text NOT NULL CHECK (squawk ~ '^[0-7]{4}$'),   -- 1200 = generic VFR
    dep_airport_id  integer NOT NULL REFERENCES airport,
    arr_airport_id  integer NOT NULL REFERENCES airport,
    planned_route   geometry(LineString, 4326) NOT NULL
);

CREATE TABLE track_point (
    point_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    flight_id       bigint NOT NULL REFERENCES flight ON DELETE CASCADE,
    observed_at     timestamptz NOT NULL,
    altitude_ft     integer NOT NULL,
    groundspeed_kt  integer,
    geom            geometry(Point, 4326) NOT NULL
);

-- ---------------------------------------------------------------------
-- 3. INDEXES
-- ---------------------------------------------------------------------
CREATE INDEX airport_arp_gix      ON airport USING gist (arp);
CREATE INDEX airport_arp_geog_gix ON airport USING gist ((arp::geography));  -- metre/mile queries
CREATE INDEX runway_geom_gix      ON runway USING gist (geom);
CREATE INDEX runway_geog_gix      ON runway USING gist ((geom::geography));
CREATE INDEX navaid_geom_gix      ON navaid USING gist (geom);
CREATE INDEX airspace_bound_gix   ON airspace USING gist (boundary);
CREATE INDEX airspace_kind_ix     ON airspace (kind);
CREATE INDEX obstacle_geom_gix    ON obstacle USING gist (geom);
CREATE INDEX obstacle_geog_gix    ON obstacle USING gist ((geom::geography));
CREATE INDEX flight_route_gix     ON flight USING gist (planned_route);
CREATE INDEX track_geom_gix       ON track_point USING gist (geom);
CREATE INDEX track_flight_time_ix ON track_point (flight_id, observed_at);
CREATE INDEX airport_role_ix      ON airport (role);

-- ---------------------------------------------------------------------
-- 4. SAMPLE DATA
-- ---------------------------------------------------------------------

-- 4a. The region: 70 statute miles around the US Capitol
INSERT INTO study_area (name, center, radius_mi, boundary)
SELECT 'DC 70-mile region', c, 70, ST_Buffer(c::geography, mi_to_m(70), 32)::geometry
FROM (SELECT ST_SetSRID(ST_MakePoint(-77.0091, 38.8899), 4326) AS c) s;

-- 4b. Airports (RIC is deliberately outside the region as a control case;
--     HGR sits near the edge)
INSERT INTO airport (faa_id, icao_id, name, state, role, elevation_ft, towered, arp)
SELECT faa, icao, nm, st, role, elev, twr, ST_SetSRID(ST_MakePoint(lon, lat), 4326)
FROM (VALUES
 ('DCA','KDCA','Ronald Reagan Washington National','VA','COMMERCIAL',      15,true, -77.0377,38.8521),
 ('IAD','KIAD','Washington Dulles International',   'VA','COMMERCIAL',     313,true, -77.4558,38.9445),
 ('BWI','KBWI','Baltimore/Washington International','MD','COMMERCIAL',     146,true, -76.6683,39.1754),
 ('ADW','KADW','Joint Base Andrews',                'MD','MILITARY',       280,true, -76.8672,38.8108),
 ('HEF','KHEF','Manassas Regional',                 'VA','RELIEVER',       192,true, -77.5154,38.7214),
 ('JYO','KJYO','Leesburg Executive',                'VA','RELIEVER',       389,true, -77.5575,39.0781),
 ('FDK','KFDK','Frederick Municipal',               'MD','GENERAL_AVIATION',303,true, -77.3743,39.4176),
 ('CGS','KCGS','College Park',                      'MD','GENERAL_AVIATION', 48,false,-76.9223,38.9806),
 ('MTN','KMTN','Martin State',                      'MD','RELIEVER',        21,true, -76.4138,39.3257),
 ('ANP','KANP','Lee Airport (Annapolis)',           'MD','GENERAL_AVIATION', 34,false,-76.5684,38.9429),
 ('EZF','KEZF','Shannon Airport',                   'VA','GENERAL_AVIATION', 86,false,-77.4496,38.2701),
 ('HGR','KHGR','Hagerstown Regional',               'MD','GENERAL_AVIATION',703,true, -77.7295,39.7079),
 ('RIC','KRIC','Richmond International',            'VA','COMMERCIAL',     167,true, -77.3197,37.5052)
) AS v(faa, icao, nm, st, role, elev, twr, lon, lat);

-- 4c. Runways. Real centerline endpoints come from NASR; here each centerline is
--     GENERATED from the airport reference point, magnetic heading, length and a
--     lateral offset (so parallel runways don't overlap). True heading is
--     approximated as magnetic - 10 deg (DC magnetic variation is ~10 deg W).
WITH rwy(faa_id, designator, mag_hdg, len_ft, wid_ft, offset_ft) AS (VALUES
 ('DCA','01/19',  10, 7169,150,     0), ('DCA','15/33', 150, 5204,150,     0), ('DCA','04/22', 40, 4911,150,0),
 ('IAD','01L/19R',10,11500,150, -3500), ('IAD','01C/19C',10,11500,150,    0),
 ('IAD','01R/19L',10,11500,150,  3500), ('IAD','12/30', 120,10501,150,    0),
 ('BWI','10/28', 100,10502,200,     0), ('BWI','15R/33L',150,9501,150, 1000),
 ('BWI','15L/33R',150, 5000,150, -1000),
 ('ADW','01L/19R',10, 9755,200, -1500), ('ADW','01R/19L',10, 9300,200, 1500),
 ('HEF','16L/34R',160,5700,100,     0), ('JYO','17/35', 170, 5500,100,    0),
 ('FDK','05/23',  50, 5219,100,     0), ('CGS','15/33', 150, 2607, 60,    0),
 ('MTN','15/33', 150, 6997,150,     0), ('ANP','12/30', 120, 2500, 50,    0),
 ('EZF','06/24',  60, 4200, 75,     0), ('HGR','02/20',  20, 7000,150,    0),
 ('RIC','16/34', 160, 9003,150,     0)
),
placed AS (
  SELECT a.airport_id, r.designator, r.len_ft, r.wid_ft,
         (r.mag_hdg - 10)::float AS az,
         ST_Project(a.arp::geography, abs(r.offset_ft) * 0.3048,
                    radians(r.mag_hdg - 10 + CASE WHEN r.offset_ft >= 0 THEN 90 ELSE -90 END)) AS ctr
  FROM rwy r JOIN airport a ON a.faa_id = r.faa_id
)
INSERT INTO runway (airport_id, designator, length_ft, width_ft, surface, geom)
SELECT airport_id, designator, len_ft, wid_ft, 'ASPH',
       ST_MakeLine(ST_Project(ctr, len_ft * 0.3048 / 2, radians(az + 180))::geometry,
                   ST_Project(ctr, len_ft * 0.3048 / 2, radians(az))::geometry)
FROM placed;

-- 4d. Navaids (illustrative placement)
INSERT INTO navaid (ident, navaid_type, freq_mhz, geom) VALUES
('DCA','VOR',   111.00, ST_SetSRID(ST_MakePoint(-77.0390, 38.8590),4326)),
('BAL','VORTAC',115.10, ST_SetSRID(ST_MakePoint(-76.6600, 39.1650),4326)),
('CSN','VORTAC',116.50, ST_SetSRID(ST_MakePoint(-77.8590, 38.7260),4326));

-- 4e. Airspace. Circles stand in for the real irregular FAA polygons.
INSERT INTO airspace (name, kind, floor_ft_msl, ceiling_ft_msl, boundary)
SELECT v.name, v.kind::airspace_kind, v.floor_ft, v.ceil_ft, circle_nm(a.arp, v.r_nm)
FROM (VALUES
 ('WASHINGTON CLASS B (DCA surface area)','CLASS_B',    0,10000,'DCA', 8.0),
 ('WASHINGTON CLASS B (IAD surface area)','CLASS_B',    0,10000,'IAD', 8.0),
 ('WASHINGTON CLASS B (outer shelf)',     'CLASS_B', 3000,10000,'DCA',20.0),
 ('BWI CLASS C (inner)',                  'CLASS_C',    0, 4000,'BWI', 5.0),
 ('BWI CLASS C (outer shelf)',            'CLASS_C', 1200, 4000,'BWI',10.0),
 ('MANASSAS CLASS D',                     'CLASS_D',    0, 2500,'HEF', 4.0),
 ('FREDERICK CLASS D',                    'CLASS_D',    0, 2500,'FDK', 4.0),
 ('MARTIN STATE CLASS D',                 'CLASS_D',    0, 2500,'MTN', 4.0),
 ('DC FLIGHT RESTRICTED ZONE (FRZ)',      'FRZ',        0,17999,'DCA',15.0),
 ('DC SPECIAL FLIGHT RULES AREA (SFRA)',  'SFRA',       0,17999,'DCA',30.0)
) AS v(name, kind, floor_ft, ceil_ft, faa, r_nm)
JOIN airport a ON a.faa_id = v.faa;

-- Prohibited areas around the White House / Naval Observatory (simplified circles)
INSERT INTO airspace (name, kind, floor_ft_msl, ceiling_ft_msl, boundary) VALUES
('P-56A (National Mall / White House)', 'PROHIBITED', 0, 17999,
   circle_nm(ST_SetSRID(ST_MakePoint(-77.0365, 38.8977),4326), 1.5)),
('P-56B (Naval Observatory)',           'PROHIBITED', 0, 17999,
   circle_nm(ST_SetSRID(ST_MakePoint(-77.0668, 38.9211),4326), 1.0));

-- 4f. Obstacles (OAS numbers are made up)
INSERT INTO obstacle (oas_number, description, obstacle_type, agl_ft, ground_elev_ft, lighted, geom) VALUES
('11-000001','Washington Monument','TOWER',   555, 40, true, ST_SetSRID(ST_MakePoint(-77.0353,38.8895),4326)),
('11-000002','Rosslyn high-rise',  'BUILDING',400, 60, true, ST_SetSRID(ST_MakePoint(-77.0720,38.8960),4326)),
('24-000003','Crane near BWI',     'CRANE',   250,150, true, ST_SetSRID(ST_MakePoint(-76.6700,39.1900),4326));

-- 4g. Flights
--   N123AB: VFR, no clearance, squawk 1200, Manassas -> College Park (cuts through DC airspace)
--   UAL10 : IFR, cleared, IAD -> BWI
--   N456CD: VFR, discrete code, Frederick -> Annapolis (compliant)
INSERT INTO flight (callsign, aircraft_type, flight_rules, atc_clearance, squawk,
                    dep_airport_id, arr_airport_id, planned_route)
SELECT v.callsign, v.type, v.rules, v.cleared, v.squawk, d.airport_id, a.airport_id,
       ST_MakeLine(d.arp, a.arp)
FROM (VALUES
 ('N123AB','C172','VFR',false,'1200','HEF','CGS'),
 ('UAL10', 'B738','IFR',true, '4521','IAD','BWI'),
 ('N456CD','PA28','VFR',false,'4321','FDK','ANP')
) AS v(callsign, type, rules, cleared, squawk, dep, arr)
JOIN airport d ON d.faa_id = v.dep
JOIN airport a ON a.faa_id = v.arr;

-- Synthetic radar tracks interpolated along each route (30 s apart)
INSERT INTO track_point (flight_id, observed_at, altitude_ft, groundspeed_kt, geom)
SELECT f.flight_id,
       timestamptz '2026-09-01 15:00+00' + make_interval(secs => 30 * i),
       CASE f.callsign WHEN 'UAL10' THEN 1500 + 200 * i ELSE 2500 END,
       CASE f.callsign WHEN 'UAL10' THEN 250 ELSE 110 END,
       ST_LineInterpolatePoint(f.planned_route, i / 40.0)
FROM flight f, generate_series(0, 40) AS i;

-- ---------------------------------------------------------------------
-- 5. VIEWS AND QUERIES
-- ---------------------------------------------------------------------

-- 5a. Airports inside the 70-mile region, with distance from the center
CREATE VIEW dc_region_airports AS
SELECT a.*,
       round((ST_Distance(a.arp::geography, s.center::geography) / 1609.344)::numeric, 1)
           AS miles_from_dc
FROM airport a
JOIN study_area s ON s.name = 'DC 70-mile region'
WHERE ST_DWithin(a.arp::geography, s.center::geography, mi_to_m(s.radius_mi));

SELECT faa_id, name, role, miles_from_dc FROM dc_region_airports ORDER BY miles_from_dc;

-- Control check: airports that are NOT in the region (expect RIC)
SELECT faa_id, name FROM airport
WHERE airport_id NOT IN (SELECT airport_id FROM dc_region_airports);

-- 5b. The major (commercial) airports in the region: runway summary
SELECT a.faa_id, a.name, count(*) AS runways,
       max(r.length_ft) AS longest_ft, sum(r.length_ft) AS total_runway_ft
FROM dc_region_airports a
JOIN runway r USING (airport_id)
WHERE a.role = 'COMMERCIAL'
GROUP BY a.airport_id, a.faa_id, a.name
ORDER BY longest_ft DESC;

-- 5c. Distances between the three major airports (statute miles)
SELECT a.faa_id AS from_apt, b.faa_id AS to_apt,
       round((ST_Distance(a.arp::geography, b.arp::geography) / 1609.344)::numeric, 1) AS miles
FROM airport a JOIN airport b ON a.faa_id < b.faa_id
WHERE a.faa_id IN ('DCA','IAD','BWI') AND b.faa_id IN ('DCA','IAD','BWI')
ORDER BY miles;

-- 5d. Nearest commercial airports to Union Station (KNN via GiST)
SELECT faa_id, name,
       round((ST_Distance(arp::geography,
              ST_SetSRID(ST_MakePoint(-77.0066, 38.8973),4326)::geography) / 1609.344)::numeric, 1) AS miles
FROM airport
WHERE role = 'COMMERCIAL'
ORDER BY arp <-> ST_SetSRID(ST_MakePoint(-77.0066, 38.8973),4326)
LIMIT 3;

-- 5e. Which special airspace contains each airport in the region?
SELECT a.faa_id,
       coalesce(string_agg(s.kind::text, ', ' ORDER BY s.kind), '-') AS inside
FROM dc_region_airports a
LEFT JOIN airspace s
  ON ST_Covers(s.boundary, a.arp) AND s.kind IN ('SFRA','FRZ','PROHIBITED')
GROUP BY a.airport_id, a.faa_id
ORDER BY a.faa_id;

-- 5f. What airspace applies over the National Mall at 1,500 ft?
SELECT name, kind, floor_ft_msl, ceiling_ft_msl
FROM airspace
WHERE ST_Covers(boundary, ST_SetSRID(ST_MakePoint(-77.0353, 38.8895),4326))
  AND 1500 BETWEEN floor_ft_msl AND ceiling_ft_msl
ORDER BY kind;

-- 5g. Obstacles >= 200 ft AGL within 3 NM of a commercial-airport runway.
-- NOTE: a flat buffer is only a proxy; real analysis uses 14 CFR Part 77 surfaces.
SELECT a.faa_id, r.designator, o.description, o.agl_ft, o.amsl_ft,
       round((ST_Distance(o.geom::geography, r.geom::geography) / 1852)::numeric, 2) AS dist_nm
FROM runway r
JOIN airport a USING (airport_id)
JOIN obstacle o ON ST_DWithin(o.geom::geography, r.geom::geography, nm_to_m(3))
WHERE a.role = 'COMMERCIAL' AND o.agl_ft >= 200
ORDER BY dist_nm;

-- 5h. Rebuild the flown path as a line
CREATE VIEW flight_actual_path AS
SELECT flight_id, ST_MakeLine(geom ORDER BY observed_at) AS path,
       min(observed_at) AS started_at, max(observed_at) AS ended_at
FROM track_point GROUP BY flight_id;

-- 5i. Airspace alerts (simplified DC rules, for illustration)
CREATE VIEW airspace_alerts AS
WITH hits AS (
  SELECT f.callsign, a.name AS airspace, t.observed_at,
         CASE
           WHEN a.kind = 'PROHIBITED'                          THEN 'Inside prohibited area'
           WHEN a.kind = 'FRZ'     AND NOT f.atc_clearance     THEN 'In FRZ without clearance'
           WHEN a.kind = 'SFRA'    AND f.squawk = '1200'       THEN 'In SFRA on VFR code 1200'
           WHEN a.kind = 'CLASS_B' AND NOT f.atc_clearance     THEN 'In Class B without clearance'
         END AS issue
  FROM track_point t
  JOIN flight f USING (flight_id)
  JOIN airspace a
    ON ST_Covers(a.boundary, t.geom)
   AND t.altitude_ft BETWEEN a.floor_ft_msl AND a.ceiling_ft_msl
)
SELECT callsign, airspace, issue,
       min(observed_at) AS first_seen, max(observed_at) AS last_seen, count(*) AS reports
FROM hits
WHERE issue IS NOT NULL
GROUP BY callsign, airspace, issue
ORDER BY callsign, first_seen;

SELECT * FROM airspace_alerts;   -- expect only N123AB

-- ---------------------------------------------------------------------
-- 6. LOADING REAL DATA (examples, run from a shell)
-- ---------------------------------------------------------------------
-- ogr2ogr -f PostgreSQL PG:"dbname=faa" Class_Airspace.shp \
--         -nln dcaviation.stg_airspace -t_srs EPSG:4326 -nlt PROMOTE_TO_MULTI
-- Then INSERT ... SELECT from the staging table, mapping class/floor/ceiling fields.

-- ---------------------------------------------------------------------
-- 7. PERFORMANCE CHECK
-- ---------------------------------------------------------------------
-- EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM dc_region_airports;
-- Expect "Index Scan using airport_arp_geog_gix". Run ANALYZE after bulk loads.

-- ---------------------------------------------------------------------
-- 8. MAP MESSAGE (shows as a hover tooltip on the map)
-- ---------------------------------------------------------------------
CREATE TABLE map_message (
    message_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       text NOT NULL,
    message     text NOT NULL,
    geom        geometry(Point, 4326) NOT NULL
);
CREATE INDEX map_message_gix ON map_message USING gist (geom);

-- Placed at the FAA Headquarters (approximate coordinates)
INSERT INTO map_message (title, message, geom) VALUES
('FAA Headquarters (approx.)', 'Hi Cobec! I''m Dana and ready to work',
 ST_SetSRID(ST_MakePoint(-77.0232, 38.887), 4326));

-- GeoJSON for web maps; the 'message' property is what the hover tooltip displays
SELECT jsonb_build_object(
    'type', 'FeatureCollection',
    'features', jsonb_agg(jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(geom)::jsonb,
        'properties', jsonb_build_object('title', title, 'message', message)))
) AS geojson
FROM map_message;

-- QGIS: Layer Properties > Display > HTML Map Tip: <b>[% title %]</b><br>[% message %]
-- then View > Show Map Tips, and hover over the point.
