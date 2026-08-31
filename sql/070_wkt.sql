-- Well-known types: timestamps, durations, the wrapper types,
-- Struct/Value/ListValue, Any and NullValue. Everything registers
-- through the same four tables the standard library uses; nothing
-- here is a core patch.
--
-- Timestamp values are {"s": epoch seconds, "n": nanos 0..1e9-1,
-- "tz": fixed offset minutes}; durations are total nanoseconds.
-- Semantics are cel-go v0.32.0's (common/types/timestamp.go,
-- duration.go, overflow.go), confirmed by conformance runs.

BEGIN;

-- Range-checked constructors ------------------------------------------

-- Seconds range is year 0001..9999 (timestamp.go:54-56); outside it
-- construction and arithmetic yield 'timestamp overflow'
-- (overflow.go:239).
CREATE OR REPLACE FUNCTION cel._ts_val(
  s numeric, n numeric, tzm int, id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN s < -62135596800 OR s > 253402300799
      THEN cel._err('timestamp overflow', id)
    ELSE jsonb_build_object('@t', 'timestamp', 'v',
      jsonb_build_object('s', to_jsonb(s), 'n', to_jsonb(n),
        'tz', to_jsonb(tzm)))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._dur_val(ns numeric, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN ns < -9223372036854775808::numeric
      OR ns > 9223372036854775807::numeric
      THEN cel._err('integer overflow', id)
    ELSE jsonb_build_object('@t', 'duration', 'v', to_jsonb(ns))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._ts_ns(v jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT (v -> 'v' ->> 's')::numeric * 1000000000
       + (v -> 'v' ->> 'n')::numeric;
$$;

-- Builds a timestamp from total nanoseconds, flooring so nanos stay
-- in [0, 1e9). div() (truncating integer division) then a manual
-- floor correction: numeric '/' selects a result scale that can drop
-- fractional digits on 20-digit quotients, so it cannot be trusted
-- here.
CREATE OR REPLACE FUNCTION cel._ts_of_ns(
  total numeric, tzm int, id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s numeric := div(total, 1000000000);
  n numeric;
BEGIN
  n := total - s * 1000000000;
  IF n < 0 THEN
    s := s - 1;
    n := n + 1000000000;
  END IF;
  RETURN cel._ts_val(s, n, tzm, id);
END;
$$;

-- Conversions ----------------------------------------------------------

-- Strict RFC 3339 (timestamp.go isStrictRFC3339 + Go time.Parse):
-- fixed-width date-time, 'T'/'t' separator, optional fraction,
-- 'Z'/'z' or +-HH:MM offset. Go's parser rejects leap seconds and
-- impossible dates.
CREATE OR REPLACE FUNCTION cel._f_string_to_timestamp(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  str text := args[1] ->> 'v';
  m   text[];
  y int; mo int; dd int; hh int; mi int; ss int;
  n numeric := 0;
  tzm int := 0;
  days numeric;
BEGIN
  m := regexp_match(str,
    '^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})' ||
    '(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$');
  IF m IS NULL THEN
    RETURN cel._err(
      format('invalid RFC 3339 timestamp %s', quote_literal(str)));
  END IF;
  y := m[1]::int; mo := m[2]::int; dd := m[3]::int;
  hh := m[4]::int; mi := m[5]::int; ss := m[6]::int;
  IF y < 1 OR mo < 1 OR mo > 12 OR hh > 23 OR mi > 59 OR ss > 59
     OR dd < 1
     OR dd > extract(day FROM
          (make_date(y, mo, 1) + interval '1 month - 1 day'))
  THEN
    RETURN cel._err(
      format('invalid RFC 3339 timestamp %s', quote_literal(str)));
  END IF;
  IF m[7] IS NOT NULL THEN
    n := rpad(substr(substr(m[7], 2), 1, 9), 9, '0')::numeric;
  END IF;
  IF lower(m[8]) <> 'z' THEN
    hh := NULL;  -- reuse below is confusing; parse offset afresh
    tzm := substr(m[8], 2, 2)::int * 60 + substr(m[8], 5, 2)::int;
    IF left(m[8], 1) = '-' THEN
      tzm := -tzm;
    END IF;
    IF abs(tzm) > 23 * 60 + 59 THEN
      RETURN cel._err(
        format('invalid RFC 3339 timestamp %s', quote_literal(str)));
    END IF;
  END IF;
  days := (make_date(y, mo, dd) - date '1970-01-01')::numeric;
  RETURN cel._ts_val(
    days * 86400 + m[4]::int * 3600 + mi * 60 + ss - tzm * 60,
    n, tzm);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_int_to_timestamp(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_val((args[1] ->> 'v')::numeric, 0, 0);
$$;

CREATE OR REPLACE FUNCTION cel._f_timestamp_to_int(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val((args[1] -> 'v' ->> 's')::numeric);
$$;

-- RFC3339Nano in the value's own offset: fraction with trailing
-- zeros trimmed, 'Z' for a zero offset (timestamp.go:190).
CREATE OR REPLACE FUNCTION cel._f_timestamp_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   numeric := (args[1] -> 'v' ->> 's')::numeric;
  n   int := (args[1] -> 'v' ->> 'n')::numeric;
  tzm int := coalesce((args[1] -> 'v' ->> 'tz')::int, 0);
  wall numeric := s + tzm * 60;
  days int := floor(wall / 86400);
  rem  int;
  frac text := '';
  off  text;
BEGIN
  rem := wall - days::numeric * 86400;
  IF n > 0 THEN
    frac := '.' || rtrim(lpad(n::text, 9, '0'), '0');
  END IF;
  IF tzm = 0 THEN
    off := 'Z';
  ELSE
    off := CASE WHEN tzm < 0 THEN '-' ELSE '+' END
        || lpad((abs(tzm) / 60)::text, 2, '0') || ':'
        || lpad((abs(tzm) % 60)::text, 2, '0');
  END IF;
  RETURN jsonb_build_object('@t', 'string', 'v',
    to_char(date '1970-01-01' + days, 'YYYY-MM-DD') || 'T'
    || lpad((rem / 3600)::text, 2, '0') || ':'
    || lpad(((rem / 60) % 60)::text, 2, '0') || ':'
    || lpad((rem % 60)::text, 2, '0') || frac || off);
END;
$$;

-- Go time.ParseDuration: signed sequence of decimal numbers with
-- units ns/us/µs/μs/ms/s/m/h; bare "0" allowed.
CREATE OR REPLACE FUNCTION cel._f_string_to_duration(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  str   text := args[1] ->> 'v';
  s     text := str;
  neg   boolean := false;
  total numeric := 0;
  m     text[];
BEGIN
  IF s ~ '^[+-]' THEN
    neg := left(s, 1) = '-';
    s := substr(s, 2);
  END IF;
  IF s = '0' THEN
    RETURN cel._dur_val(0);
  END IF;
  IF s = '' THEN
    RETURN cel._err(
      format('invalid duration %s', quote_literal(str)));
  END IF;
  WHILE s <> '' LOOP
    m := regexp_match(s,
      '^(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|μs|ms|s|m|h)(.*)$');
    IF m IS NULL THEN
      RETURN cel._err(
        format('invalid duration %s', quote_literal(str)));
    END IF;
    total := total + trunc(m[1]::numeric * CASE m[2]
      WHEN 'ns' THEN 1
      WHEN 'ms' THEN 1000000
      WHEN 's'  THEN 1000000000
      WHEN 'm'  THEN 60000000000
      WHEN 'h'  THEN 3600000000000
      ELSE 1000  -- us / µs / μs
    END::numeric);
    s := m[3];
  END LOOP;
  RETURN cel._dur_val(CASE WHEN neg THEN -total ELSE total END);
END;
$$;

-- Renders scientific notation as plain decimal, for Go's
-- FormatFloat(f, 'f', -1, 64): same shortest digits as %g, fixed
-- rendering.
CREATE OR REPLACE FUNCTION cel._sci_to_plain(t text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  m      text[];
  digits text;
  p      int;
BEGIN
  m := regexp_match(t, '^(-?)(\d+)(?:\.(\d+))?e([+-]?\d+)$');
  IF m IS NULL THEN
    RETURN t;
  END IF;
  digits := m[2] || coalesce(m[3], '');
  p := length(m[2]) + m[4]::int;
  IF p <= 0 THEN
    RETURN m[1] || '0.' || repeat('0', -p) || digits;
  ELSIF p >= length(digits) THEN
    RETURN m[1] || digits || repeat('0', p - length(digits));
  END IF;
  RETURN m[1] || substr(digits, 1, p) || '.' || substr(digits, p + 1);
END;
$$;

-- duration.go:125: FormatFloat(d.Seconds(), 'f', -1, 64) + "s",
-- where Seconds() = float64(sec) + float64(nsec)/1e9.
CREATE OR REPLACE FUNCTION cel._f_duration_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ns  numeric := (args[1] ->> 'v')::numeric;
  sec float8;
BEGIN
  sec := trunc(ns / 1000000000)::float8
       + (ns - trunc(ns / 1000000000) * 1000000000)::float8 / 1e9;
  RETURN jsonb_build_object('@t', 'string', 'v',
    cel._sci_to_plain(cel._double_text(sec)) || 's');
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_duration_to_int(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val((args[1] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_identity(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

-- Arithmetic (overflow.go:236-260) ------------------------------------

CREATE OR REPLACE FUNCTION cel._f_add_ts_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_of_ns(
    cel._ts_ns(args[1]) + (args[2] ->> 'v')::numeric,
    coalesce((args[1] -> 'v' ->> 'tz')::int, 0), NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_add_dur_ts(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_of_ns(
    cel._ts_ns(args[2]) + (args[1] ->> 'v')::numeric,
    coalesce((args[2] -> 'v' ->> 'tz')::int, 0), NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_add_dur_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(
    (args[1] ->> 'v')::numeric + (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_sub_ts_ts(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(cel._ts_ns(args[1]) - cel._ts_ns(args[2]));
$$;

CREATE OR REPLACE FUNCTION cel._f_sub_ts_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_of_ns(
    cel._ts_ns(args[1]) - (args[2] ->> 'v')::numeric,
    coalesce((args[1] -> 'v' ->> 'tz')::int, 0), NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_sub_dur_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(
    (args[1] ->> 'v')::numeric - (args[2] ->> 'v')::numeric);
$$;

-- Getters --------------------------------------------------------------

-- Wall-clock timestamp for a value under an optional tz override
-- (timestamp.go timeZone): NULL -> the value's own fixed offset; a
-- string with ':' -> +-H:MM fixed offset; otherwise an IANA name
-- resolved by Postgres's tzdata.
CREATE OR REPLACE FUNCTION cel._ts_wall(
  v jsonb, tz text, OUT wall timestamp, OUT err jsonb
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s    numeric := (v -> 'v' ->> 's')::numeric;
  offm int;
  hr   int;
  mi   int;
BEGIN
  IF tz IS NULL THEN
    offm := coalesce((v -> 'v' ->> 'tz')::int, 0);
  ELSIF position(':' IN tz) = 0 THEN
    BEGIN
      wall := to_timestamp(s::float8) AT TIME ZONE tz;
      RETURN;
    EXCEPTION WHEN OTHERS THEN
      err := cel._err(format('unknown time zone %s',
        quote_literal(tz)));
      RETURN;
    END;
  ELSE
    BEGIN
      hr := split_part(tz, ':', 1)::int;
      mi := split_part(tz, ':', 2)::int;
    EXCEPTION WHEN OTHERS THEN
      err := cel._err(format('invalid timezone %s',
        quote_literal(tz)));
      RETURN;
    END;
    IF hr < -23 OR hr > 23 OR mi < 0 OR mi > 59 THEN
      err := cel._err(format(
        'timezone offset out of range: %s', tz));
      RETURN;
    END IF;
    offm := CASE WHEN left(tz, 1) = '-' THEN hr * 60 - mi
                 ELSE hr * 60 + mi END;
  END IF;
  wall := timestamp '1970-01-01'
        + make_interval(secs => (s + offm * 60)::float8);
END;
$$;

-- One impl per getter; a two-element args array carries the tz
-- override, so each impl serves both the 0- and 1-arg overloads.
CREATE OR REPLACE FUNCTION cel._ts_get(args jsonb[], part text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  w record;
BEGIN
  IF part = 'milliseconds' THEN
    RETURN cel._int_val(
      trunc((args[1] -> 'v' ->> 'n')::numeric / 1000000));
  END IF;
  SELECT * INTO w FROM cel._ts_wall(args[1],
    CASE WHEN cardinality(args) > 1 THEN args[2] ->> 'v' END);
  IF w.err IS NOT NULL THEN
    RETURN w.err;
  END IF;
  RETURN cel._int_val(CASE part
    WHEN 'year'         THEN extract(year FROM w.wall)
    WHEN 'month'        THEN extract(month FROM w.wall) - 1
    WHEN 'day_of_year'  THEN extract(doy FROM w.wall) - 1
    WHEN 'day_of_month' THEN extract(day FROM w.wall) - 1
    WHEN 'date'         THEN extract(day FROM w.wall)
    WHEN 'day_of_week'  THEN extract(dow FROM w.wall)
    WHEN 'hours'        THEN extract(hour FROM w.wall)
    WHEN 'minutes'      THEN extract(minute FROM w.wall)
    WHEN 'seconds'      THEN floor(extract(second FROM w.wall))
  END);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_ts_year(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'year') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_month(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'month') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_doy(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'day_of_year') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_dom0(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'day_of_month') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_dom1(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'date') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_dow(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'day_of_week') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_hours(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'hours') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_minutes(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'minutes') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_seconds(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'seconds') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_ms(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'milliseconds') $$;

-- Duration getters are truncated totals, except getMilliseconds,
-- which is the sub-second component: the corpus and cel-java agree
-- against cel-go v0.32.0 here.
CREATE OR REPLACE FUNCTION cel._f_dur_hours(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 3600000000000));
$$;
CREATE OR REPLACE FUNCTION cel._f_dur_minutes(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 60000000000));
$$;
CREATE OR REPLACE FUNCTION cel._f_dur_seconds(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 1000000000));
$$;
CREATE OR REPLACE FUNCTION cel._f_dur_ms(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 1000000) % 1000);
$$;

COMMIT;

BEGIN;

-- Construction impls ---------------------------------------------------
-- Each receives the evaluated fields as a jsonb object of tagged
-- values (050_eval.sql struct branch). Wrappers unwrap to their
-- primitive; an unset field takes the proto3 default.

CREATE OR REPLACE FUNCTION cel._wkt_bool(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "bool", "v": false}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_int(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value', '{"@t": "int", "v": 0}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_uint(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value', '{"@t": "uint", "v": 0}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_double(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "double", "v": 0}'::jsonb);
$$;

-- FloatValue narrows to float32 (dynamic/float/literal_not_double).
CREATE OR REPLACE FUNCTION cel._wkt_float(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN fields ? 'value'
    THEN cel._dbl_val(
      ((fields -> 'value' ->> 'v')::float8::float4)::float8)
    ELSE '{"@t": "double", "v": 0}'::jsonb
  END;
$$;

CREATE OR REPLACE FUNCTION cel._wkt_string(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "string", "v": ""}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_bytes(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "bytes", "v": ""}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_struct(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'fields',
    '{"@t": "map", "v": []}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_listvalue(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'values',
    '{"@t": "list", "v": []}'::jsonb);
$$;

-- google.protobuf.Value: whichever field is set decides the JSON
-- kind; unset means null.
CREATE OR REPLACE FUNCTION cel._wkt_value(fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF fields ? 'number_value' THEN
    RETURN jsonb_build_object('@t', 'double', 'v',
      fields -> 'number_value' -> 'v');
  ELSIF fields ? 'string_value' THEN
    RETURN fields -> 'string_value';
  ELSIF fields ? 'bool_value' THEN
    RETURN fields -> 'bool_value';
  ELSIF fields ? 'struct_value' THEN
    RETURN fields -> 'struct_value';
  ELSIF fields ? 'list_value' THEN
    RETURN fields -> 'list_value';
  END IF;
  RETURN '{"@t": "null", "v": null}'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION cel._wkt_timestamp(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_val(
    coalesce((fields -> 'seconds' ->> 'v')::numeric, 0),
    coalesce((fields -> 'nanos' ->> 'v')::numeric, 0), 0);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_duration(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(
    coalesce((fields -> 'seconds' ->> 'v')::numeric, 0) * 1000000000
    + coalesce((fields -> 'nanos' ->> 'v')::numeric, 0));
$$;

-- Any needs a descriptor pool to pack; its row exists so the name
-- resolves.
CREATE OR REPLACE FUNCTION cel._wkt_any(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._err(
    'cannot construct google.protobuf.Any without descriptors');
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.type (name, kind, construct) VALUES
  ('google.protobuf.Timestamp', '{"kind": "timestamp"}',
   'cel._wkt_timestamp(jsonb)'),
  ('google.protobuf.Duration', '{"kind": "duration"}',
   'cel._wkt_duration(jsonb)'),
  ('google.protobuf.BoolValue',
   '{"kind": "wrapper", "params": [{"kind": "bool"}]}',
   'cel._wkt_bool(jsonb)'),
  ('google.protobuf.Int32Value',
   '{"kind": "wrapper", "params": [{"kind": "int"}]}',
   'cel._wkt_int(jsonb)'),
  ('google.protobuf.Int64Value',
   '{"kind": "wrapper", "params": [{"kind": "int"}]}',
   'cel._wkt_int(jsonb)'),
  ('google.protobuf.UInt32Value',
   '{"kind": "wrapper", "params": [{"kind": "uint"}]}',
   'cel._wkt_uint(jsonb)'),
  ('google.protobuf.UInt64Value',
   '{"kind": "wrapper", "params": [{"kind": "uint"}]}',
   'cel._wkt_uint(jsonb)'),
  ('google.protobuf.FloatValue',
   '{"kind": "wrapper", "params": [{"kind": "double"}]}',
   'cel._wkt_float(jsonb)'),
  ('google.protobuf.DoubleValue',
   '{"kind": "wrapper", "params": [{"kind": "double"}]}',
   'cel._wkt_double(jsonb)'),
  ('google.protobuf.StringValue',
   '{"kind": "wrapper", "params": [{"kind": "string"}]}',
   'cel._wkt_string(jsonb)'),
  ('google.protobuf.BytesValue',
   '{"kind": "wrapper", "params": [{"kind": "bytes"}]}',
   'cel._wkt_bytes(jsonb)'),
  ('google.protobuf.Struct',
   '{"kind": "map", "params": [{"kind": "string"}, {"kind": "dyn"}]}',
   'cel._wkt_struct(jsonb)'),
  ('google.protobuf.Value', '{"kind": "dyn"}',
   'cel._wkt_value(jsonb)'),
  ('google.protobuf.ListValue',
   '{"kind": "list", "params": [{"kind": "dyn"}]}',
   'cel._wkt_listvalue(jsonb)'),
  ('google.protobuf.Any', '{"kind": "any"}', 'cel._wkt_any(jsonb)'),
  ('google.protobuf.NullValue',
   '{"kind": "int", "enum": {"NULL_VALUE": 0}}', NULL)
ON CONFLICT (name) DO UPDATE SET
  kind = excluded.kind,
  construct = excluded.construct;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  -- arithmetic (cel-go standard.go declaration order)
  ('add_duration_duration', '_+_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "duration"}', 'cel._f_add_dur_dur(jsonb[])', 70),
  ('add_duration_timestamp', '_+_', false,
   '[{"kind": "duration"}, {"kind": "timestamp"}]',
   '{"kind": "timestamp"}', 'cel._f_add_dur_ts(jsonb[])', 80),
  ('add_timestamp_duration', '_+_', false,
   '[{"kind": "timestamp"}, {"kind": "duration"}]',
   '{"kind": "timestamp"}', 'cel._f_add_ts_dur(jsonb[])', 90),
  ('subtract_duration_duration', '_-_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "duration"}', 'cel._f_sub_dur_dur(jsonb[])', 40),
  ('subtract_timestamp_duration', '_-_', false,
   '[{"kind": "timestamp"}, {"kind": "duration"}]',
   '{"kind": "timestamp"}', 'cel._f_sub_ts_dur(jsonb[])', 50),
  ('subtract_timestamp_timestamp', '_-_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "duration"}', 'cel._f_sub_ts_ts(jsonb[])', 60),
  -- relations
  ('less_timestamp', '_<_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_lt(jsonb[])', 130),
  ('less_duration', '_<_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_lt(jsonb[])', 140),
  ('less_equals_timestamp', '_<=_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_le(jsonb[])', 130),
  ('less_equals_duration', '_<=_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_le(jsonb[])', 140),
  ('greater_timestamp', '_>_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_gt(jsonb[])', 130),
  ('greater_duration', '_>_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_gt(jsonb[])', 140),
  ('greater_equals_timestamp', '_>=_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_ge(jsonb[])', 130),
  ('greater_equals_duration', '_>=_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_ge(jsonb[])', 140),
  -- conversions
  ('duration_to_int64', 'int', false,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_duration_to_int(jsonb[])', 50),
  ('timestamp_to_int64', 'int', false,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_timestamp_to_int(jsonb[])', 60),
  ('duration_to_string', 'string', false,
   '[{"kind": "duration"}]', '{"kind": "string"}',
   'cel._f_duration_to_string(jsonb[])', 70),
  ('timestamp_to_string', 'string', false,
   '[{"kind": "timestamp"}]', '{"kind": "string"}',
   'cel._f_timestamp_to_string(jsonb[])', 80),
  ('timestamp_to_timestamp', 'timestamp', false,
   '[{"kind": "timestamp"}]', '{"kind": "timestamp"}',
   'cel._f_identity(jsonb[])', 10),
  ('int64_to_timestamp', 'timestamp', false,
   '[{"kind": "int"}]', '{"kind": "timestamp"}',
   'cel._f_int_to_timestamp(jsonb[])', 20),
  ('string_to_timestamp', 'timestamp', false,
   '[{"kind": "string"}]', '{"kind": "timestamp"}',
   'cel._f_string_to_timestamp(jsonb[])', 30),
  ('duration_to_duration', 'duration', false,
   '[{"kind": "duration"}]', '{"kind": "duration"}',
   'cel._f_identity(jsonb[])', 10),
  ('string_to_duration', 'duration', false,
   '[{"kind": "string"}]', '{"kind": "duration"}',
   'cel._f_string_to_duration(jsonb[])', 20),
  -- timestamp getters
  ('timestamp_to_year', 'getFullYear', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_year(jsonb[])', 10),
  ('timestamp_to_year_with_tz', 'getFullYear', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_year(jsonb[])', 20),
  ('timestamp_to_month', 'getMonth', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_month(jsonb[])', 10),
  ('timestamp_to_month_with_tz', 'getMonth', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_month(jsonb[])', 20),
  ('timestamp_to_day_of_year', 'getDayOfYear', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_doy(jsonb[])', 10),
  ('timestamp_to_day_of_year_with_tz', 'getDayOfYear', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_doy(jsonb[])', 20),
  ('timestamp_to_day_of_month', 'getDayOfMonth', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_dom0(jsonb[])', 10),
  ('timestamp_to_day_of_month_with_tz', 'getDayOfMonth', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_dom0(jsonb[])', 20),
  ('timestamp_to_day_of_month_1_based', 'getDate', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_dom1(jsonb[])', 10),
  ('timestamp_to_day_of_month_1_based_with_tz', 'getDate', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_dom1(jsonb[])', 20),
  ('timestamp_to_day_of_week', 'getDayOfWeek', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_dow(jsonb[])', 10),
  ('timestamp_to_day_of_week_with_tz', 'getDayOfWeek', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_dow(jsonb[])', 20),
  ('timestamp_to_hours', 'getHours', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_hours(jsonb[])', 10),
  ('timestamp_to_hours_with_tz', 'getHours', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_hours(jsonb[])', 20),
  ('timestamp_to_minutes', 'getMinutes', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_minutes(jsonb[])', 10),
  ('timestamp_to_minutes_with_tz', 'getMinutes', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_minutes(jsonb[])', 20),
  ('timestamp_to_seconds', 'getSeconds', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_seconds(jsonb[])', 10),
  ('timestamp_to_seconds_tz', 'getSeconds', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_seconds(jsonb[])', 20),
  ('timestamp_to_milliseconds', 'getMilliseconds', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_ms(jsonb[])', 10),
  ('timestamp_to_milliseconds_with_tz', 'getMilliseconds', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_ms(jsonb[])', 20),
  -- duration getters
  ('duration_to_hours', 'getHours', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_hours(jsonb[])', 30),
  ('duration_to_minutes', 'getMinutes', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_minutes(jsonb[])', 30),
  ('duration_to_seconds', 'getSeconds', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_seconds(jsonb[])', 30),
  ('duration_to_milliseconds', 'getMilliseconds', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_ms(jsonb[])', 30)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'type', name FROM cel.type
WHERE name LIKE 'google.protobuf.%'
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'overload', id FROM cel.overload
ON CONFLICT DO NOTHING;

COMMIT;
