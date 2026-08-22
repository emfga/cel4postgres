-- cel4postgres -- value helpers.
--
-- Run after 000_install.sql. Everything here is a pure function over
-- tagged jsonb values or their scalar payloads; nothing reads a table.

BEGIN;

-- Renders a finite double the way CEL's string(double) must: cel-go
-- delegates to Go's %g (common/types/double.go:141, pinned v0.32.0).
-- Postgres's own float8 output is close but measurably different in
-- two ways (both found by the fuzz test in conformance/format_test.go,
-- which holds this function to Go %g on every CI run):
--
--   1. Notation threshold. Go's shortest %g switches to scientific
--      notation when the decimal exponent is < -4 or >= 6 (strconv
--      ftoa.go: "use precision 6 for this decision"); Postgres stays
--      plain up to e+14.
--
--   2. Halfway digits. Both emit shortest-round-trip digits, but when
--      a shorter form lands exactly halfway between two doubles and
--      ties-to-even resolves back to the value, Go accepts it and
--      Postgres's Ryu does not (e.g. 4.468743327960138e+16, which Go
--      prints with 16 digits and Postgres with 17). Hence the
--      shortening loop: drop a digit while the result still casts
--      back to the same double.
--
-- Non-finite doubles never reach this function: the evaluator carries
-- them as the tagged strings "Infinity"/"-Infinity"/"NaN" and renders
-- their CEL text itself.
CREATE OR REPLACE FUNCTION cel._double_text(v float8)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE STRICT
SET search_path = cel, pg_temp
AS $$
DECLARE
  t         text := v::text;
  neg       text := '';
  mant      text;
  int_part  text;
  frac      text;
  digits    text;
  e         int;
  m         numeric;
  cand      text;
  cand_e    int;
  shortened text;
BEGIN
  IF t LIKE '-%' THEN
    neg := '-';
    t := substr(t, 2);
  END IF;

  -- Normalize to (digits, e): significant digits with no trailing
  -- zeros, and the decimal exponent of the leading digit.
  IF t LIKE '%e%' THEN
    mant := split_part(t, 'e', 1);
    e := split_part(t, 'e', 2)::int;
    digits := replace(mant, '.', '');
  ELSE
    int_part := split_part(t, '.', 1);
    frac := split_part(t, '.', 2);
    IF int_part = '0' THEN
      -- 0, or 0.00123-style: exponent from the leading zeros.
      digits := ltrim(frac, '0');
      IF digits = '' THEN
        RETURN neg || '0';
      END IF;
      e := -(length(frac) - length(digits)) - 1;
    ELSE
      digits := int_part || frac;
      e := length(int_part) - 1;
    END IF;
  END IF;
  digits := rtrim(digits, '0');
  IF digits = '' THEN
    digits := '0';
    e := 0;
  END IF;

  -- Shorten while a rounded-off form still round-trips (point 2).
  WHILE length(digits) > 1 LOOP
    m := round(digits::numeric / 10);
    cand := m::text;
    cand_e := e + length(cand) - (length(digits) - 1);
    cand := rtrim(cand, '0');
    IF cand = '' THEN
      cand := '0';
    END IF;
    -- A candidate rounded up past 1.7976931348623157e308 would make
    -- the round-trip cast raise instead of miss; it cannot be the
    -- shortest form of any finite double, so stop shortening there.
    IF cand_e > 308 OR (cand_e = 308
        AND rpad(cand, 17, '0') > '17976931348623157') THEN
      EXIT;
    END IF;
    shortened := substr(cand, 1, 1)
      || CASE WHEN length(cand) > 1
              THEN '.' || substr(cand, 2)
              ELSE '' END
      || 'e' || cand_e::text;
    EXIT WHEN (neg || shortened)::float8 IS DISTINCT FROM v;
    digits := cand;
    e := cand_e;
  END LOOP;

  -- Render per Go's %g rule (point 1).
  IF e < -4 OR e >= 6 THEN
    RETURN neg || substr(digits, 1, 1)
      || CASE WHEN length(digits) > 1
              THEN '.' || substr(digits, 2)
              ELSE '' END
      || CASE WHEN e < 0 THEN 'e-' ELSE 'e+' END
      -- At least two exponent digits, as Go prints (lpad would
      -- truncate three-digit exponents).
      || CASE WHEN abs(e) < 10 THEN '0' ELSE '' END
      || abs(e)::text;
  END IF;

  IF e >= 0 THEN
    int_part := rpad(substr(digits, 1, e + 1), e + 1, '0');
    frac := substr(digits, e + 2);
    RETURN neg || int_part
      || CASE WHEN frac <> '' THEN '.' || frac ELSE '' END;
  END IF;

  RETURN neg || '0.' || repeat('0', -e - 1) || digits;
END;
$$;

COMMIT;

BEGIN;

-- Tagged-value primitives. The kind tag carries type identity
-- (workspace doc 02); these helpers are the single place equality,
-- ordering and payload access are defined, so every impl and the
-- evaluator agree on them.

CREATE OR REPLACE FUNCTION cel._err(msg text, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'error',
    'v', jsonb_strip_nulls(jsonb_build_object('msg', msg, 'id', id)));
$$;

CREATE OR REPLACE FUNCTION cel._is_error(v jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT v ->> '@t' = 'error';
$$;

CREATE OR REPLACE FUNCTION cel._is_unknown(v jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT v ->> '@t' = 'unknown';
$$;

-- Unknown payloads are sorted, deduped expr-id arrays; merging is set
-- union.
CREATE OR REPLACE FUNCTION cel._unknown_merge(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'unknown', 'v',
    coalesce(jsonb_agg(id ORDER BY id), '[]'::jsonb))
  FROM (
    SELECT DISTINCT (e ->> 0)::bigint AS id
    FROM (
      SELECT jsonb_build_array(x) AS e
      FROM jsonb_array_elements(a -> 'v') x
      UNION ALL
      SELECT jsonb_build_array(x)
      FROM jsonb_array_elements(b -> 'v') x
    ) ids
  ) merged;
$$;

-- The float8 payload of a double value; the three non-finite
-- sentinels are strings in jsonb.
CREATE OR REPLACE FUNCTION cel._dbl(v jsonb)
RETURNS float8
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE v ->> 'v'
    WHEN 'Infinity'  THEN 'Infinity'::float8
    WHEN '-Infinity' THEN '-Infinity'::float8
    WHEN 'NaN'       THEN 'NaN'::float8
    ELSE (v ->> 'v')::float8
  END;
$$;

-- Wraps a float8 back into a tagged double, mapping non-finite
-- results to their sentinel strings (jsonb cannot hold them).
CREATE OR REPLACE FUNCTION cel._dbl_val(f float8)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN f = 'Infinity'::float8
      THEN jsonb_build_object('@t', 'double', 'v', 'Infinity')
    WHEN f = '-Infinity'::float8
      THEN jsonb_build_object('@t', 'double', 'v', '-Infinity')
    -- Postgres treats NaN as equal to NaN, so f <> f cannot detect
    -- it the IEEE way; the direct comparison works instead.
    WHEN f = 'NaN'::float8
      THEN jsonb_build_object('@t', 'double', 'v', 'NaN')
    ELSE jsonb_build_object('@t', 'double', 'v', to_jsonb(f))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._int_val(n numeric)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'int', 'v', to_jsonb(n));
$$;

CREATE OR REPLACE FUNCTION cel._bool_val(b boolean)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'bool', 'v', b);
$$;

-- Heterogeneous equality (cel-go v0.32.0 common/types, measured):
-- cross-kind == is false, never an error; int/uint compare exactly;
-- int-or-uint vs double bounds-checks then widens to double
-- (compare.go:23-66); NaN equals nothing; lists/maps size-first then
-- element-wise; timestamps by instant; null only equals null.
CREATE OR REPLACE FUNCTION cel._equal(a jsonb, b jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ka text := a ->> '@t';
  kb text := b ->> '@t';
  da float8;
  db float8;
  i  int;
  ea jsonb;
  found boolean;
  used  boolean[];
  j  int;
BEGIN
  -- Numeric cross-kind equality: NaN equals nothing; otherwise
  -- exactly the ordering comparison at zero, which carries the
  -- bounds-check-then-widen behaviour of compare.go (a bare widen
  -- would call 9223372036854775807 equal to 2^63 as a double).
  IF ka IN ('int', 'uint', 'double') AND kb IN ('int', 'uint', 'double')
  THEN
    IF (ka = 'double' AND a ->> 'v' = 'NaN')
       OR (kb = 'double' AND b ->> 'v' = 'NaN') THEN
      RETURN false;
    END IF;
    RETURN (cel._compare(a, b) ->> 'v')::int = 0;
  END IF;

  IF ka <> kb THEN
    RETURN false;
  END IF;

  CASE ka
    WHEN 'null' THEN
      RETURN true;
    WHEN 'bool', 'string', 'bytes', 'type' THEN
      RETURN a -> 'v' = b -> 'v';
    WHEN 'duration' THEN
      RETURN (a ->> 'v')::numeric = (b ->> 'v')::numeric;
    WHEN 'timestamp' THEN
      RETURN (a -> 'v' ->> 's')::numeric = (b -> 'v' ->> 's')::numeric
         AND (a -> 'v' ->> 'n')::numeric = (b -> 'v' ->> 'n')::numeric;
    WHEN 'list' THEN
      IF jsonb_array_length(a -> 'v') <> jsonb_array_length(b -> 'v')
      THEN
        RETURN false;
      END IF;
      FOR i IN 0 .. jsonb_array_length(a -> 'v') - 1 LOOP
        IF NOT cel._equal(a -> 'v' -> i, b -> 'v' -> i) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    WHEN 'map' THEN
      IF jsonb_array_length(a -> 'v') <> jsonb_array_length(b -> 'v')
      THEN
        RETURN false;
      END IF;
      used := array_fill(false, ARRAY[jsonb_array_length(b -> 'v')]);
      FOR i IN 0 .. jsonb_array_length(a -> 'v') - 1 LOOP
        ea := a -> 'v' -> i;
        found := false;
        FOR j IN 0 .. jsonb_array_length(b -> 'v') - 1 LOOP
          IF NOT used[j + 1]
             AND cel._equal(ea -> 'k', b -> 'v' -> j -> 'k')
             AND cel._equal(ea -> 'v', b -> 'v' -> j -> 'v') THEN
            used[j + 1] := true;
            found := true;
            EXIT;
          END IF;
        END LOOP;
        IF NOT found THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    ELSE
      -- Opaque and future kinds: structural payload identity unless
      -- a registered equality overrides it (extension phases).
      RETURN a - '@t' = b - '@t';
  END CASE;
END;
$$;

-- Three-way ordering for the relation operators. Returns a tagged
-- int (-1/0/1) or an error value: NaN is unorderable, and kinds
-- outside the numeric cross-compare matrix order only within their
-- own kind (cel-go compare.go, measured).
CREATE OR REPLACE FUNCTION cel._compare(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ka text := a ->> '@t';
  kb text := b ->> '@t';
  da float8;
  db float8;
  na numeric;
  nb numeric;
BEGIN
  IF ka IN ('int', 'uint', 'double') AND kb IN ('int', 'uint', 'double')
  THEN
    IF ka = 'double' OR kb = 'double' THEN
      da := CASE WHEN ka = 'double' THEN cel._dbl(a)
                 ELSE NULL END;
      db := CASE WHEN kb = 'double' THEN cel._dbl(b)
                 ELSE NULL END;
      -- Postgres NaN compares equal to NaN, so the check is direct.
      IF da = 'NaN'::float8 OR db = 'NaN'::float8 THEN
        RETURN cel._err('NaN values cannot be ordered');
      END IF;

      -- compareDoubleInt / compareDoubleUint: bounds first, then
      -- widen the integer side and compare as doubles.
      IF ka = 'double' AND kb IN ('int', 'uint') THEN
        nb := (b ->> 'v')::numeric;
        IF kb = 'int' AND da < -9223372036854775808::float8 THEN
          RETURN cel._int_val(-1);
        ELSIF kb = 'int' AND da > 9223372036854775807::float8 THEN
          RETURN cel._int_val(1);
        ELSIF kb = 'uint' AND da < 0 THEN
          RETURN cel._int_val(-1);
        ELSIF kb = 'uint' AND da > 18446744073709551615::float8 THEN
          RETURN cel._int_val(1);
        END IF;
        db := nb::float8;
      ELSIF kb = 'double' AND ka IN ('int', 'uint') THEN
        na := (a ->> 'v')::numeric;
        IF ka = 'int' AND db < -9223372036854775808::float8 THEN
          RETURN cel._int_val(1);
        ELSIF ka = 'int' AND db > 9223372036854775807::float8 THEN
          RETURN cel._int_val(-1);
        ELSIF ka = 'uint' AND db < 0 THEN
          RETURN cel._int_val(1);
        ELSIF ka = 'uint' AND db > 18446744073709551615::float8 THEN
          RETURN cel._int_val(-1);
        END IF;
        da := na::float8;
      END IF;

      RETURN cel._int_val(CASE
        WHEN da < db THEN -1 WHEN da > db THEN 1 ELSE 0 END);
    END IF;

    -- int/uint cross: exact integer comparison.
    na := (a ->> 'v')::numeric;
    nb := (b ->> 'v')::numeric;
    RETURN cel._int_val(CASE
      WHEN na < nb THEN -1 WHEN na > nb THEN 1 ELSE 0 END);
  END IF;

  IF ka <> kb THEN
    RETURN cel._err('no such overload');
  END IF;

  CASE ka
    WHEN 'bool' THEN
      RETURN cel._int_val(CASE
        WHEN a -> 'v' = b -> 'v' THEN 0
        WHEN (a ->> 'v')::boolean THEN 1 ELSE -1 END);
    WHEN 'string' THEN
      -- Byte-wise (C collation) order, not locale order.
      RETURN cel._int_val(CASE
        WHEN convert_to(a ->> 'v', 'UTF8')
             < convert_to(b ->> 'v', 'UTF8') THEN -1
        WHEN convert_to(a ->> 'v', 'UTF8')
             > convert_to(b ->> 'v', 'UTF8') THEN 1
        ELSE 0 END);
    WHEN 'bytes' THEN
      RETURN cel._int_val(CASE
        WHEN decode(a ->> 'v', 'base64') < decode(b ->> 'v', 'base64')
          THEN -1
        WHEN decode(a ->> 'v', 'base64') > decode(b ->> 'v', 'base64')
          THEN 1
        ELSE 0 END);
    WHEN 'duration' THEN
      na := (a ->> 'v')::numeric;
      nb := (b ->> 'v')::numeric;
      RETURN cel._int_val(CASE
        WHEN na < nb THEN -1 WHEN na > nb THEN 1 ELSE 0 END);
    WHEN 'timestamp' THEN
      na := (a -> 'v' ->> 's')::numeric * 1000000000
            + (a -> 'v' ->> 'n')::numeric;
      nb := (b -> 'v' ->> 's')::numeric * 1000000000
            + (b -> 'v' ->> 'n')::numeric;
      RETURN cel._int_val(CASE
        WHEN na < nb THEN -1 WHEN na > nb THEN 1 ELSE 0 END);
    ELSE
      RETURN cel._err('no such overload');
  END CASE;
END;
$$;

-- Map lookup by normalized key equality: exact kind first is not
-- needed separately -- cel._equal already implements the lossless
-- numeric coercions map.go's Find applies. Returns the entry's value
-- or NULL when absent.
CREATE OR REPLACE FUNCTION cel._map_find(m jsonb, key jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  entry jsonb;
BEGIN
  FOR entry IN SELECT e FROM jsonb_array_elements(m -> 'v') e LOOP
    IF cel._equal(entry -> 'k', key) THEN
      RETURN entry -> 'v';
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

COMMIT;
