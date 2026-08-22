-- cel4postgres -- standard library, part 1.
--
-- Logic, arithmetic, relations, size, membership, indexing. Every
-- implementation has the uniform registry signature
-- impl(args jsonb[]) -> jsonb over already-evaluated tagged values,
-- and registers through cel.overload rows exactly as an extension
-- would -- no privileged path (CLAUDE.md, the four registries).
--
-- Semantics are cel-go v0.32.0's, encoded from measured runs and the
-- pinned source (workspace measurements.md): checked int64/uint64
-- arithmetic with overflow sentinels, IEEE-754 double arithmetic
-- with the three non-finite sentinels, Go-style truncated division
-- and remainder.

BEGIN;

-- Integer (int64) checked arithmetic. Postgres numeric is exact, so
-- overflow is a range check, not a wraparound.

CREATE OR REPLACE FUNCTION cel._chk_int(n numeric, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN n < -9223372036854775808::numeric
      OR n > 9223372036854775807::numeric
    THEN cel._err('integer overflow', id)
    ELSE cel._int_val(n)
  END;
$$;

CREATE OR REPLACE FUNCTION cel._chk_uint(n numeric, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN n < 0 OR n > 18446744073709551615::numeric
    THEN cel._err('unsigned integer overflow', id)
    ELSE jsonb_build_object('@t', 'uint', 'v', to_jsonb(n))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_add_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(
    (args[1] ->> 'v')::numeric + (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_subtract_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(
    (args[1] ->> 'v')::numeric - (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_multiply_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(
    (args[1] ->> 'v')::numeric * (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_divide_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('division by zero')
    ELSE cel._chk_int(trunc(
      (args[1] ->> 'v')::numeric / (args[2] ->> 'v')::numeric, 0))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_modulo_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  -- Go's % truncates toward zero (remainder keeps the dividend's
  -- sign), which is exactly Postgres numeric mod. MinInt64 % -1 is
  -- an overflow sentinel in cel-go, not 0.
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('modulus by zero')
    WHEN (args[1] ->> 'v')::numeric = -9223372036854775808::numeric
     AND (args[2] ->> 'v')::numeric = -1
      THEN cel._err('integer overflow')
    ELSE cel._int_val(mod(
      (args[1] ->> 'v')::numeric, (args[2] ->> 'v')::numeric))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_negate_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(-(args[1] ->> 'v')::numeric);
$$;

-- Unsigned (uint64) checked arithmetic.

CREATE OR REPLACE FUNCTION cel._f_add_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint(
    (args[1] ->> 'v')::numeric + (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_subtract_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint(
    (args[1] ->> 'v')::numeric - (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_multiply_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint(
    (args[1] ->> 'v')::numeric * (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_divide_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('division by zero')
    ELSE cel._chk_uint(trunc(
      (args[1] ->> 'v')::numeric / (args[2] ->> 'v')::numeric, 0))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_modulo_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('modulus by zero')
    ELSE cel._chk_uint(mod(
      (args[1] ->> 'v')::numeric, (args[2] ->> 'v')::numeric))
  END;
$$;

-- Double (IEEE-754 binary64) arithmetic. Hardware float8 ops are
-- correctly rounded, but Postgres raises on overflow/underflow where
-- IEEE wants ±Infinity/±0, so finite operands go through an exact
-- numeric computation (+ - *) or numeric pre-checks (/) with the
-- true rounding boundaries: 2^1024 - 2^970 for overflow (at or
-- beyond rounds to Infinity, ties-to-even) and 2^-1075 for
-- underflow. Non-finite operands use float8 directly -- IEEE special
-- values never raise.
--
-- Note: float8 -> numeric goes through the shortest decimal text,
-- not the exact binary value; the discrepancy (< 1 ulp of the 17th
-- digit) only matters within one part in 1e16 of the exact overflow
-- boundary, unreachable in practice.

CREATE OR REPLACE FUNCTION cel._dbl_of_numeric(n numeric)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  boundary numeric := 18014398509481983::numeric * (2::numeric ^ 970);
BEGIN
  IF abs(n) >= boundary THEN
    RETURN jsonb_build_object('@t', 'double', 'v',
      CASE WHEN n < 0 THEN '-Infinity' ELSE 'Infinity' END);
  END IF;
  IF n <> 0 AND abs(n) <= 2.4703282292062327e-324::numeric THEN
    RETURN cel._dbl_val((CASE WHEN n < 0 THEN '-0' ELSE '0' END)::float8);
  END IF;
  RETURN cel._dbl_val(n::float8);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_dbl_bin(op text, a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  fa float8 := cel._dbl(a);
  fb float8 := cel._dbl(b);
  na numeric;
  nb numeric;
  boundary numeric := 18014398509481983::numeric * (2::numeric ^ 970);
  neg boolean;
BEGIN
  IF fa = 'Infinity'::float8 OR fa = '-Infinity'::float8
     OR fa = 'NaN'::float8
     OR fb = 'Infinity'::float8 OR fb = '-Infinity'::float8
     OR fb = 'NaN'::float8
  THEN
    -- IEEE special values never raise in float8 arithmetic; the one
    -- case Postgres would reject is division by a zero divisor.
    IF op = '/' AND fb = 0 THEN
      IF fa = 'NaN'::float8 THEN
        RETURN jsonb_build_object('@t', 'double', 'v', 'NaN');
      END IF;
      neg := (fa < 0) <> (fb::text LIKE '-%');
      RETURN jsonb_build_object('@t', 'double', 'v',
        CASE WHEN neg THEN '-Infinity' ELSE 'Infinity' END);
    END IF;
    RETURN cel._dbl_val(CASE op
      WHEN '+' THEN fa + fb
      WHEN '-' THEN fa - fb
      WHEN '*' THEN fa * fb
      ELSE fa / fb
    END);
  END IF;

  IF op = '/' THEN
    IF fb = 0 THEN
      IF fa = 0 THEN
        RETURN jsonb_build_object('@t', 'double', 'v', 'NaN');
      END IF;
      -- Sign of the zero matters: 1.0 / -0.0 is -Infinity.
      neg := (fa < 0) <> (fb::text LIKE '-%');
      RETURN jsonb_build_object('@t', 'double', 'v',
        CASE WHEN neg THEN '-Infinity' ELSE 'Infinity' END);
    END IF;
    na := fa::numeric;
    nb := fb::numeric;
    IF abs(na) >= boundary * abs(nb) THEN
      RETURN jsonb_build_object('@t', 'double', 'v',
        CASE WHEN (fa < 0) <> (fb < 0)
             THEN '-Infinity' ELSE 'Infinity' END);
    END IF;
    IF fa <> 0
       AND abs(na) <= 2.4703282292062327e-324::numeric * abs(nb) THEN
      RETURN cel._dbl_val(
        (CASE WHEN (fa < 0) <> (fb < 0) THEN '-0' ELSE '0' END)::float8);
    END IF;
    RETURN cel._dbl_val(fa / fb);
  END IF;

  na := fa::numeric;
  nb := fb::numeric;
  RETURN cel._dbl_of_numeric(CASE op
    WHEN '+' THEN na + nb
    WHEN '-' THEN na - nb
    ELSE na * nb
  END);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_add_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('+', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_subtract_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('-', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_multiply_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('*', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_divide_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('/', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_negate_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val(-cel._dbl(args[1]));
$$;

-- Concatenation forms of _+_.

CREATE OR REPLACE FUNCTION cel._f_add_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    (args[1] ->> 'v') || (args[2] ->> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_add_bytes(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'bytes', 'v',
    replace(encode(
      decode(args[1] ->> 'v', 'base64')
      || decode(args[2] ->> 'v', 'base64'), 'base64'), E'\n', ''));
$$;

CREATE OR REPLACE FUNCTION cel._f_add_list(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'list', 'v',
    (args[1] -> 'v') || (args[2] -> 'v'));
$$;

-- Logic.

CREATE OR REPLACE FUNCTION cel._f_logical_not(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(NOT (args[1] ->> 'v')::boolean);
$$;

-- Relations: four shared impls over cel._compare, which already
-- implements the numeric cross-type matrix and NaN unorderability.

CREATE OR REPLACE FUNCTION cel._f_lt(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int < 0);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_le(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int <= 0);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_gt(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int > 0);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_ge(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int >= 0);
END;
$$;

-- Size.

CREATE OR REPLACE FUNCTION cel._f_size_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(length(args[1] ->> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_size_bytes(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(octet_length(decode(args[1] ->> 'v', 'base64')));
$$;

CREATE OR REPLACE FUNCTION cel._f_size_list(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(jsonb_array_length(args[1] -> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_size_map(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(jsonb_array_length(args[1] -> 'v'));
$$;

-- Membership.

CREATE OR REPLACE FUNCTION cel._f_in_list(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  e jsonb;
BEGIN
  FOR e IN SELECT x FROM jsonb_array_elements(args[2] -> 'v') x LOOP
    IF cel._equal(args[1], e) THEN
      RETURN cel._bool_val(true);
    END IF;
  END LOOP;
  RETURN cel._bool_val(false);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_in_map(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(cel._map_find(args[2], args[1]) IS NOT NULL);
$$;

-- Indexing. List indices accept int plus losslessly-coercible
-- double/uint (cel-go list index semantics, workspace doc 06).

CREATE OR REPLACE FUNCTION cel._f_index_list(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  kind text := args[2] ->> '@t';
  n    numeric;
  size int := jsonb_array_length(args[1] -> 'v');
BEGIN
  IF kind = 'double' THEN
    n := cel._dbl(args[2])::numeric;
    IF n <> trunc(n) THEN
      RETURN cel._err(format(
        'invalid_argument: unsupported index value %s', n::text));
    END IF;
  ELSIF kind IN ('int', 'uint') THEN
    n := (args[2] ->> 'v')::numeric;
  ELSE
    RETURN cel._err('no such overload');
  END IF;

  IF n < 0 OR n >= size THEN
    RETURN cel._err(format(
      'index ''%s'' out of range in list size ''%s''', n::text, size));
  END IF;
  RETURN args[1] -> 'v' -> n::int;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_index_map(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := cel._map_find(args[1], args[2]);
BEGIN
  IF v IS NULL THEN
    RETURN cel._err(format('no such key: %s',
      coalesce(args[2] ->> 'v', 'null')));
  END IF;
  RETURN v;
END;
$$;

-- type() and dyn().

CREATE OR REPLACE FUNCTION cel._f_type(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'type', 'v', CASE args[1] ->> '@t'
    WHEN 'null' THEN 'null_type'
    WHEN 'timestamp' THEN 'google.protobuf.Timestamp'
    WHEN 'duration' THEN 'google.protobuf.Duration'
    WHEN 'opaque' THEN args[1] ->> 'type'
    ELSE args[1] ->> '@t'
  END);
$$;

CREATE OR REPLACE FUNCTION cel._f_to_dyn(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

COMMIT;

BEGIN;

-- Overload rows. Ids are cel-go's exactly (common/overloads); the
-- checker binds them and conformance's type_deduction output depends
-- on them. The absorbed ids carry NULL impls -- the evaluator core
-- recognizes them by id after finding them through this same table.

WITH t AS (
  SELECT
    '{"kind":"bool"}'::jsonb   AS bool,
    '{"kind":"int"}'::jsonb    AS int,
    '{"kind":"uint"}'::jsonb   AS uint,
    '{"kind":"double"}'::jsonb AS dbl,
    '{"kind":"string"}'::jsonb AS str,
    '{"kind":"bytes"}'::jsonb  AS byt,
    '{"kind":"dyn"}'::jsonb    AS dyn,
    '{"kind":"param","name":"A"}'::jsonb AS pa,
    '{"kind":"param","name":"B"}'::jsonb AS pb,
    '{"kind":"list","params":[{"kind":"param","name":"A"}]}'::jsonb AS lista,
    '{"kind":"map","params":[{"kind":"param","name":"A"},{"kind":"param","name":"B"}]}'::jsonb AS mapab,
    '{"kind":"type","params":[{"kind":"param","name":"A"}]}'::jsonb AS typea
)
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT * FROM (
  SELECT 'logical_and', '_&&_', false,
    jsonb_build_array(t.bool, t.bool), t.bool,
    NULL::regprocedure, 10 FROM t
  UNION ALL SELECT 'logical_or', '_||_', false,
    jsonb_build_array(t.bool, t.bool), t.bool, NULL, 10 FROM t
  UNION ALL SELECT 'logical_not', '!_', false,
    jsonb_build_array(t.bool), t.bool,
    'cel._f_logical_not(jsonb[])'::regprocedure, 10 FROM t
  UNION ALL SELECT 'conditional', '_?_:_', false,
    jsonb_build_array(t.bool, t.pa, t.pa), t.pa, NULL, 10 FROM t
  UNION ALL SELECT 'not_strictly_false', '@not_strictly_false', false,
    jsonb_build_array(t.bool), t.bool, NULL, 10 FROM t
  UNION ALL SELECT 'equals', '_==_', false,
    jsonb_build_array(t.pa, t.pa), t.bool, NULL, 10 FROM t
  UNION ALL SELECT 'not_equals', '_!=_', false,
    jsonb_build_array(t.pa, t.pa), t.bool, NULL, 10 FROM t

  UNION ALL SELECT 'add_int64', '_+_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_add_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'add_uint64', '_+_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_add_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'add_double', '_+_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_add_double(jsonb[])', 30 FROM t
  UNION ALL SELECT 'add_string', '_+_', false,
    jsonb_build_array(t.str, t.str), t.str,
    'cel._f_add_string(jsonb[])', 40 FROM t
  UNION ALL SELECT 'add_bytes', '_+_', false,
    jsonb_build_array(t.byt, t.byt), t.byt,
    'cel._f_add_bytes(jsonb[])', 50 FROM t
  UNION ALL SELECT 'add_list', '_+_', false,
    jsonb_build_array(t.lista, t.lista), t.lista,
    'cel._f_add_list(jsonb[])', 60 FROM t

  UNION ALL SELECT 'subtract_int64', '_-_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_subtract_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'subtract_uint64', '_-_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_subtract_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'subtract_double', '_-_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_subtract_double(jsonb[])', 30 FROM t

  UNION ALL SELECT 'multiply_int64', '_*_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_multiply_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'multiply_uint64', '_*_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_multiply_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'multiply_double', '_*_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_multiply_double(jsonb[])', 30 FROM t

  UNION ALL SELECT 'divide_int64', '_/_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_divide_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'divide_uint64', '_/_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_divide_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'divide_double', '_/_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_divide_double(jsonb[])', 30 FROM t

  UNION ALL SELECT 'modulo_int64', '_%_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_modulo_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'modulo_uint64', '_%_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_modulo_uint64(jsonb[])', 20 FROM t

  UNION ALL SELECT 'negate_int64', '-_', false,
    jsonb_build_array(t.int), t.int,
    'cel._f_negate_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'negate_double', '-_', false,
    jsonb_build_array(t.dbl), t.dbl,
    'cel._f_negate_double(jsonb[])', 20 FROM t

  UNION ALL SELECT 'size_string', 'size', false,
    jsonb_build_array(t.str), t.int,
    'cel._f_size_string(jsonb[])', 10 FROM t
  UNION ALL SELECT 'size_bytes', 'size', false,
    jsonb_build_array(t.byt), t.int,
    'cel._f_size_bytes(jsonb[])', 20 FROM t
  UNION ALL SELECT 'size_list', 'size', false,
    jsonb_build_array(t.lista), t.int,
    'cel._f_size_list(jsonb[])', 30 FROM t
  UNION ALL SELECT 'size_map', 'size', false,
    jsonb_build_array(t.mapab), t.int,
    'cel._f_size_map(jsonb[])', 40 FROM t
  UNION ALL SELECT 'string_size', 'size', true,
    jsonb_build_array(t.str), t.int,
    'cel._f_size_string(jsonb[])', 10 FROM t
  UNION ALL SELECT 'bytes_size', 'size', true,
    jsonb_build_array(t.byt), t.int,
    'cel._f_size_bytes(jsonb[])', 20 FROM t
  UNION ALL SELECT 'list_size', 'size', true,
    jsonb_build_array(t.lista), t.int,
    'cel._f_size_list(jsonb[])', 30 FROM t
  UNION ALL SELECT 'map_size', 'size', true,
    jsonb_build_array(t.mapab), t.int,
    'cel._f_size_map(jsonb[])', 40 FROM t

  UNION ALL SELECT 'in_list', '@in', false,
    jsonb_build_array(t.pa, t.lista), t.bool,
    'cel._f_in_list(jsonb[])', 10 FROM t
  UNION ALL SELECT 'in_map', '@in', false,
    jsonb_build_array(t.pa, t.mapab), t.bool,
    'cel._f_in_map(jsonb[])', 20 FROM t

  -- Index rows carry NULL impls: indexing is core attribute
  -- machinery (runtime numeric coercion), found through this table
  -- by id like the other absorbed operations.
  UNION ALL SELECT 'index_list', '_[_]', false,
    jsonb_build_array(t.lista, t.int), t.pa, NULL, 10 FROM t
  UNION ALL SELECT 'index_map', '_[_]', false,
    jsonb_build_array(t.mapab, t.pa), t.pb, NULL, 20 FROM t

  UNION ALL SELECT 'type', 'type', false,
    jsonb_build_array(t.pa), t.typea,
    'cel._f_type(jsonb[])', 10 FROM t
  UNION ALL SELECT 'to_dyn', 'dyn', false,
    jsonb_build_array(t.pa), t.dyn,
    'cel._f_to_dyn(jsonb[])', 10 FROM t
) rows(id, fn, member, arg_types, result_type, impl, ordinal)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- Relation overloads: 4 operators x 12 type pairs sharing four
-- comparator impls (timestamp/duration pairs arrive with 070).
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT
  op.prefix || CASE WHEN pair.suffix = '' THEN pair.t1
                    ELSE pair.suffix END,
  op.fn, false,
  jsonb_build_array(
    jsonb_build_object('kind', pair.t1),
    jsonb_build_object('kind', pair.t2)),
  '{"kind":"bool"}'::jsonb,
  op.impl::regprocedure,
  pair.ord
FROM (VALUES
  ('less_', '_<_', 'cel._f_lt(jsonb[])'),
  ('less_equals_', '_<=_', 'cel._f_le(jsonb[])'),
  ('greater_', '_>_', 'cel._f_gt(jsonb[])'),
  ('greater_equals_', '_>=_', 'cel._f_ge(jsonb[])')
) op(prefix, fn, impl)
CROSS JOIN (VALUES
  ('bool',          'bool',   'bool',   10),
  ('int64',         'int',    'int',    20),
  ('int64_double',  'int',    'double', 30),
  ('int64_uint64',  'int',    'uint',   40),
  ('uint64',        'uint',   'uint',   50),
  ('uint64_double', 'uint',   'double', 60),
  ('uint64_int64',  'uint',   'int',    70),
  ('double',        'double', 'double', 80),
  ('double_int64',  'double', 'int',    90),
  ('double_uint64', 'double', 'uint',   100),
  ('string',        'string', 'string', 110),
  ('bytes',         'bytes',  'bytes',  120)
) pair(suffix, t1, t2, ord)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  arg_types = excluded.arg_types,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- Standard type identifiers: every visible cel.type row implies an
-- ident of type type(T) under the type's name.
INSERT INTO cel.type (name, kind) VALUES
  ('bool',      '{"kind":"bool"}'),
  ('int',       '{"kind":"int"}'),
  ('uint',      '{"kind":"uint"}'),
  ('double',    '{"kind":"double"}'),
  ('string',    '{"kind":"string"}'),
  ('bytes',     '{"kind":"bytes"}'),
  ('list',      '{"kind":"list","params":[{"kind":"dyn"}]}'),
  ('map',       '{"kind":"map","params":[{"kind":"dyn"},{"kind":"dyn"}]}'),
  ('null_type', '{"kind":"null"}'),
  ('type',      '{"kind":"type"}')
ON CONFLICT (name) DO NOTHING;

-- Everything above is visible in the standard env.
INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'overload', id FROM cel.overload
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'type', name FROM cel.type
ON CONFLICT DO NOTHING;

COMMIT;
