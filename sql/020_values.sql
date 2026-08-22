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
