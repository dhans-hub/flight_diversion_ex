-- SQL assertions: any failure raises an exception and fails the CI job.
-- Run after 01_ and 02_:  psql -v ON_ERROR_STOP=1 -f sql/tests/assertions.sql
\set ON_ERROR_STOP on
SET search_path = dcaviation, public;

-- ---- Data and region ------------------------------------------------------
DO $$
DECLARE n integer; s text;
BEGIN
    SELECT count(*) INTO n FROM airport;
    IF n <> 13 THEN RAISE EXCEPTION 'expected 13 airports, found %', n; END IF;

    SELECT count(*) INTO n FROM runway;
    IF n <> 21 THEN RAISE EXCEPTION 'expected 21 runways, found %', n; END IF;

    SELECT count(*) INTO n FROM airspace;
    IF n <> 12 THEN RAISE EXCEPTION 'expected 12 airspace rows, found %', n; END IF;

    -- 70-mile region: 12 of 13 airports; Richmond out, Hagerstown (edge case) in
    SELECT count(*) INTO n FROM dc_region_airports;
    IF n <> 12 THEN RAISE EXCEPTION 'expected 12 airports in region, found %', n; END IF;
    IF EXISTS (SELECT 1 FROM dc_region_airports WHERE faa_id = 'RIC') THEN
        RAISE EXCEPTION 'RIC should be outside the 70-mile region';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM dc_region_airports WHERE faa_id = 'HGR') THEN
        RAISE EXCEPTION 'HGR should be inside the 70-mile region';
    END IF;

    -- generated runway centerlines match the declared lengths within 1%
    SELECT count(*) INTO n FROM runway
    WHERE abs(ST_Length(geom::geography) / 0.3048 - length_ft) / length_ft > 0.01;
    IF n <> 0 THEN RAISE EXCEPTION '% runways differ from declared length by more than 1%%', n; END IF;

    -- airspace alerts: only the uncleared VFR flight, and it clips P-56B
    SELECT string_agg(DISTINCT callsign, ',') INTO s FROM airspace_alerts;
    IF s IS DISTINCT FROM 'N123AB' THEN RAISE EXCEPTION 'expected alerts only for N123AB, got %', s; END IF;
    IF NOT EXISTS (SELECT 1 FROM airspace_alerts WHERE callsign = 'N123AB' AND airspace LIKE 'P-56B%') THEN
        RAISE EXCEPTION 'N123AB should trigger a P-56B alert';
    END IF;
END $$;

-- ---- Geodesic buffer vs Web Mercator ---------------------------------------
DO $$
DECLARE ratio numeric;
BEGIN
    SELECT ST_Area(ST_Transform(ST_Buffer(ST_Transform(center, 3857), 150 * 1852.0), 4326)::geography)
           / ST_Area(ST_Buffer(center::geography, 150 * 1852.0))
    INTO ratio FROM study_area WHERE name = 'DC 70-mile region';
    IF ratio NOT BETWEEN 0.55 AND 0.67 THEN
        RAISE EXCEPTION 'unexpected Web Mercator ground-area ratio: %', ratio;
    END IF;
END $$;

-- ---- Diversion ranking -----------------------------------------------------
DO $$
DECLARE n integer; bad integer; heading numeric; before_ident text; after_ident text;
BEGIN
    SELECT count(*) INTO n FROM diversion_top3;
    IF n <> 3 THEN RAISE EXCEPTION 'diversion_top3 should return 3 rows, got %', n; END IF;

    -- distances ascend with rank and every airport meets the runway minimum
    SELECT count(*) INTO bad FROM (
        SELECT dist_nm, longest_runway_ft,
               lag(dist_nm) OVER (ORDER BY rank) AS prev_dist
        FROM diversion_top3) t
    WHERE longest_runway_ft < 5000 OR (prev_dist IS NOT NULL AND dist_nm < prev_dist);
    IF bad > 0 THEN RAISE EXCEPTION 'diversion_top3 ordering or runway filter is wrong'; END IF;

    -- a stricter runway rule is honoured
    SELECT count(*) INTO bad FROM diversion_airports(7000, 150, 3) WHERE longest_runway_ft < 7000;
    IF bad > 0 THEN RAISE EXCEPTION 'min runway parameter is not applied'; END IF;

    -- heading is south-west for the New York -> Atlanta route
    SELECT heading_deg INTO heading FROM aircraft_position;
    IF heading NOT BETWEEN 200 AND 250 THEN RAISE EXCEPTION 'unexpected heading: %', heading; END IF;

    -- moving the aircraft changes the ranking (restored afterwards)
    SELECT ident INTO before_ident FROM diversion_top3 WHERE rank = 1;
    UPDATE sim_flight SET progress = 0.75;
    SELECT ident INTO after_ident FROM diversion_top3 WHERE rank = 1;
    UPDATE sim_flight SET progress = 0.45;
    IF before_ident IS NOT DISTINCT FROM after_ident THEN
        RAISE EXCEPTION 'top diversion airport did not change when the aircraft moved';
    END IF;
END $$;

SELECT 'ALL SQL ASSERTIONS PASSED' AS result;
