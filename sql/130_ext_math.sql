-- The math extension (cel-go ext/math.go at the pinned v0.32.0,
-- latest library version): the math.greatest / math.least macros over
-- math.@max / math.@min, ceil/floor/round/trunc, isInf/isNaN/
-- isFinite, abs/sign/sqrt, and the 64-bit bit operations. Registered
-- under the 'math' env.
--
-- Bit operations run in numeric two's-complement arithmetic (div /
-- mod by exact powers of two) because Postgres bigint shifts take
-- the count mod 64, and uint64 values do not fit bigint.

BEGIN;

CREATE OR REPLACE FUNCTION cel._math_ident(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

-- minPair/maxPair (math.go:684): compare, propagate NaN's
-- unorderable error.
CREATE OR REPLACE FUNCTION cel._math_pair(a jsonb, b jsonb, mx boolean)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c    jsonb := cel._compare(a, b);
  take int := CASE WHEN mx THEN -1 ELSE 1 END;
BEGIN
  IF cel._is_error(c) THEN
    RETURN c;
  END IF;
  IF (c ->> 'v')::int = take THEN
    RETURN b;
  END IF;
  RETURN a;
END;
$$;

CREATE OR REPLACE FUNCTION cel._math_minmax(args jsonb[], mx boolean)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  acc jsonb;
  i   int;
BEGIN
  IF cardinality(args) = 2 THEN
    RETURN cel._math_pair(args[1], args[2], mx);
  END IF;
  -- Single list argument.
  IF jsonb_array_length(args[1] -> 'v') = 0 THEN
    RETURN cel._err(format('math.@%s(list) argument must not be '
      || 'empty', CASE WHEN mx THEN 'max' ELSE 'min' END));
  END IF;
  acc := args[1] -> 'v' -> 0;
  FOR i IN 1 .. jsonb_array_length(args[1] -> 'v') - 1 LOOP
    acc := cel._math_pair(acc, args[1] -> 'v' -> i, mx);
    IF cel._is_error(acc) THEN
      RETURN acc;
    END IF;
  END LOOP;
  IF acc ->> '@t' NOT IN ('int', 'uint', 'double', 'unknown') THEN
    RETURN cel._err(format('no such overload: math.@%s',
      CASE WHEN mx THEN 'max' ELSE 'min' END));
  END IF;
  RETURN acc;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_min(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._math_minmax(args, false) $$;

CREATE OR REPLACE FUNCTION cel._f_math_max(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._math_minmax(args, true) $$;

CREATE OR REPLACE FUNCTION cel._f_math_ceil(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val(ceil((args[1] ->> 'v')::float8));
$$;

CREATE OR REPLACE FUNCTION cel._f_math_floor(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val(floor((args[1] ->> 'v')::float8));
$$;

-- math.Round: half away from zero; NaN and infinities pass through.
CREATE OR REPLACE FUNCTION cel._f_math_round(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f float8 := (args[1] ->> 'v')::float8;
BEGIN
  IF args[1] ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
    RETURN args[1];
  END IF;
  RETURN cel._dbl_val(CASE WHEN f < 0 THEN -floor(-f + 0.5)
                           ELSE floor(f + 0.5) END);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_trunc(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN args[1] ->> 'v' IN ('NaN', 'Infinity', '-Infinity')
      THEN args[1]
    ELSE cel._dbl_val(trunc((args[1] ->> 'v')::float8::numeric)
                        ::float8)
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_isinf(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    args[1] ->> 'v' IN ('Infinity', '-Infinity'));
$$;

CREATE OR REPLACE FUNCTION cel._f_math_isnan(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(args[1] ->> 'v' = 'NaN');
$$;

CREATE OR REPLACE FUNCTION cel._f_math_isfinite(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    args[1] ->> 'v' NOT IN ('NaN', 'Infinity', '-Infinity'));
$$;

CREATE OR REPLACE FUNCTION cel._f_math_abs(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := args[1] ->> '@t';
BEGIN
  CASE k
    WHEN 'double' THEN
      IF args[1] ->> 'v' = 'NaN' THEN
        RETURN args[1];
      END IF;
      RETURN cel._dbl_val(abs((args[1] ->> 'v')::float8));
    WHEN 'int' THEN
      IF (args[1] ->> 'v')::numeric = -9223372036854775808 THEN
        RETURN cel._err('integer overflow');
      END IF;
      RETURN cel._int_val(abs((args[1] ->> 'v')::numeric));
    ELSE
      RETURN args[1];  -- uint
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_sign(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := args[1] ->> '@t';
  n numeric;
BEGIN
  IF k = 'double' THEN
    IF args[1] ->> 'v' = 'NaN' THEN
      RETURN args[1];
    END IF;
    RETURN cel._dbl_val(sign((args[1] ->> 'v')::float8)::float8);
  END IF;
  n := (args[1] ->> 'v')::numeric;
  IF k = 'uint' THEN
    RETURN jsonb_build_object('@t', 'uint', 'v',
      CASE WHEN n = 0 THEN 0 ELSE 1 END);
  END IF;
  RETURN cel._int_val(sign(n));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_sqrt(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f float8;
BEGIN
  IF args[1] ->> '@t' = 'double'
     AND args[1] ->> 'v' IN ('NaN', '-Infinity') THEN
    RETURN cel._dbl_val('NaN'::float8);
  END IF;
  IF args[1] ->> 'v' = 'Infinity' THEN
    RETURN args[1];
  END IF;
  f := (args[1] ->> 'v')::float8;
  IF f < 0 THEN
    RETURN cel._dbl_val('NaN'::float8);
  END IF;
  RETURN cel._dbl_val(sqrt(f));
END;
$$;

-- Two's-complement helpers over numeric: to64/from64 map an
-- int64-or-uint64 payload onto [0, 2^64) and back.
CREATE OR REPLACE FUNCTION cel._bits_of(v jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN (v ->> 'v')::numeric < 0
    THEN (v ->> 'v')::numeric + 18446744073709551616::numeric
    ELSE (v ->> 'v')::numeric END;
$$;

CREATE OR REPLACE FUNCTION cel._bits_val(u numeric, uns boolean)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN uns
    THEN jsonb_build_object('@t', 'uint', 'v', to_jsonb(u))
    ELSE cel._int_val(CASE
      WHEN u >= 9223372036854775808::numeric
        THEN u - 18446744073709551616::numeric
      ELSE u END)
  END;
$$;

-- Bitwise and/or/xor run on bigint after an offset-preserving remap
-- (two's complement is offset-invariant under these operators).
CREATE OR REPLACE FUNCTION cel._f_math_bitop(args jsonb[], op text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  uns boolean := args[1] ->> '@t' = 'uint';
  a bigint := cel._bits_val(cel._bits_of(args[1]), false) ->> 'v';
  b bigint := cel._bits_val(cel._bits_of(args[2]), false) ->> 'v';
  r bigint;
BEGIN
  r := CASE op
    WHEN 'and' THEN a & b
    WHEN 'or'  THEN a | b
    ELSE a # b
  END;
  RETURN cel._bits_val(
    cel._bits_of(cel._int_val(r::numeric)), uns);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_bitand(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._f_math_bitop(args, 'and') $$;
CREATE OR REPLACE FUNCTION cel._f_math_bitor(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._f_math_bitop(args, 'or') $$;
CREATE OR REPLACE FUNCTION cel._f_math_bitxor(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._f_math_bitop(args, 'xor') $$;

CREATE OR REPLACE FUNCTION cel._f_math_bitnot(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN args[1] ->> '@t' = 'uint'
    THEN jsonb_build_object('@t', 'uint', 'v', to_jsonb(
      18446744073709551615::numeric - (args[1] ->> 'v')::numeric))
    ELSE cel._int_val(-(args[1] ->> 'v')::numeric - 1)
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_shl(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  uns boolean := args[1] ->> '@t' = 'uint';
  bs  numeric := (args[2] ->> 'v')::numeric;
  u   numeric;
BEGIN
  IF bs < 0 THEN
    RETURN cel._err(format(
      'math.bitShiftLeft() negative offset: %s', bs));
  END IF;
  IF bs >= 64 THEN
    RETURN cel._bits_val(0, uns);
  END IF;
  -- numeric ^ returns a scaled result even for integer powers;
  -- trunc() restores the integer.
  u := trunc(mod(
    cel._bits_of(args[1]) * (2::numeric ^ bs::int),
    18446744073709551616::numeric));
  RETURN cel._bits_val(u, uns);
END;
$$;

-- Right shift is logical for both int and uint (math.go
-- bitShiftRightIntInt reinterprets through uint64).
CREATE OR REPLACE FUNCTION cel._f_math_shr(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  uns boolean := args[1] ->> '@t' = 'uint';
  bs  numeric := (args[2] ->> 'v')::numeric;
BEGIN
  IF bs < 0 THEN
    RETURN cel._err(format(
      'math.bitShiftRight() negative offset: %s', bs));
  END IF;
  IF bs >= 64 THEN
    RETURN cel._bits_val(0, uns);
  END IF;
  RETURN cel._bits_val(
    div(cel._bits_of(args[1]), 2::numeric ^ bs::int), uns);
END;
$$;

-- The greatest/least macros (math.go:617): receiver macros on the
-- 'math' namespace, variadic; literal arguments must be numeric.

CREATE OR REPLACE FUNCTION cel._mx_math_arg_ok(arg jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE arg ->> 'k'
    WHEN 'lit' THEN
      (arg -> 'v' ->> '@t') IN ('int', 'uint', 'double')
    WHEN 'list' THEN false
    WHEN 'map' THEN false
    WHEN 'struct' THEN false
    ELSE true
  END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_math_minmax(
  fn text, disp text, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n  int := jsonb_array_length(args);
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  ok boolean;
  i  int;
  lst jsonb;
BEGIN
  next_id_out := next_id;
  -- Decline unless the receiver is the math namespace.
  IF target ->> 'k' <> 'ident'
     OR ltrim(target ->> 'name', '.') <> 'math' THEN
    RETURN;
  END IF;
  IF n = 0 THEN
    err := format('%s() requires at least one argument', disp);
    RETURN;
  END IF;
  IF n = 1 THEN
    ok := CASE args -> 0 ->> 'k'
      WHEN 'list' THEN
        jsonb_array_length(args -> 0 -> 'elems') > 0 AND NOT EXISTS (
          SELECT FROM jsonb_array_elements(args -> 0 -> 'elems') e
          WHERE NOT cel._mx_math_arg_ok(e))
      ELSE cel._mx_math_arg_ok(args -> 0)
    END;
    IF NOT ok THEN
      err := format('%s() invalid single argument value', disp);
      RETURN;
    END IF;
    next_id_out := next_id + 1;
    expr := jsonb_build_object('id', next_id_out, 'k', 'call',
      'fn', fn, 'args', args, 's', cs, 'e', ce);
    RETURN;
  END IF;
  FOR i IN 0 .. n - 1 LOOP
    IF NOT cel._mx_math_arg_ok(args -> i) THEN
      err := format('%s() simple literal arguments must be numeric',
        disp);
      RETURN;
    END IF;
  END LOOP;
  IF n = 2 THEN
    next_id_out := next_id + 1;
    expr := jsonb_build_object('id', next_id_out, 'k', 'call',
      'fn', fn, 'args', args, 's', cs, 'e', ce);
    RETURN;
  END IF;
  next_id_out := next_id + 1;
  lst := jsonb_build_object('id', next_id_out, 'k', 'list',
    'elems', args, 's', cs, 'e', ce);
  next_id_out := next_id_out + 1;
  expr := jsonb_build_object('id', next_id_out, 'k', 'call',
    'fn', fn, 'args', jsonb_build_array(lst), 's', cs, 'e', ce);
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_math_least(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_math_minmax(
    'math.@min', 'math.least', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx_math_greatest(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_math_minmax(
    'math.@max', 'math.greatest', target, args, next_id);
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('least', -1, true,
   'cel._mx_math_least(jsonb,jsonb,bigint)'),
  ('greatest', -1, true,
   'cel._mx_math_greatest(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT ('math_@' || mm || suffix), 'math.@' || mm, false,
       arg_types, result_type,
       CASE WHEN mm = 'min' THEN 'cel._f_math_min(jsonb[])'
            ELSE 'cel._f_math_max(jsonb[])' END::regprocedure,
       ordinal
FROM (VALUES
  ('_double', '[{"kind":"double"}]'::jsonb, '{"kind":"double"}'::jsonb, 10),
  ('_int', '[{"kind":"int"}]'::jsonb, '{"kind":"int"}'::jsonb, 20),
  ('_uint', '[{"kind":"uint"}]'::jsonb, '{"kind":"uint"}'::jsonb, 30),
  ('_double_double',
   '[{"kind":"double"},{"kind":"double"}]'::jsonb,
   '{"kind":"double"}'::jsonb, 40),
  ('_int_int', '[{"kind":"int"},{"kind":"int"}]'::jsonb,
   '{"kind":"int"}'::jsonb, 50),
  ('_uint_uint', '[{"kind":"uint"},{"kind":"uint"}]'::jsonb,
   '{"kind":"uint"}'::jsonb, 60),
  ('_int_uint', '[{"kind":"int"},{"kind":"uint"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 70),
  ('_int_double', '[{"kind":"int"},{"kind":"double"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 80),
  ('_double_int', '[{"kind":"double"},{"kind":"int"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 90),
  ('_double_uint', '[{"kind":"double"},{"kind":"uint"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 100),
  ('_uint_int', '[{"kind":"uint"},{"kind":"int"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 110),
  ('_uint_double', '[{"kind":"uint"},{"kind":"double"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 120),
  ('_list_double',
   '[{"kind":"list","params":[{"kind":"double"}]}]'::jsonb,
   '{"kind":"double"}'::jsonb, 130),
  ('_list_int',
   '[{"kind":"list","params":[{"kind":"int"}]}]'::jsonb,
   '{"kind":"int"}'::jsonb, 140),
  ('_list_uint',
   '[{"kind":"list","params":[{"kind":"uint"}]}]'::jsonb,
   '{"kind":"uint"}'::jsonb, 150)
) v(suffix, arg_types, result_type, ordinal)
CROSS JOIN (VALUES ('min'), ('max')) m(mm)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- Single-argument @min/@max of a scalar are identity.
UPDATE cel.overload
SET impl = 'cel._math_ident(jsonb[])'
WHERE id IN ('math_@min_double', 'math_@min_int', 'math_@min_uint',
             'math_@max_double', 'math_@max_int', 'math_@max_uint');

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('math_ceil_double', 'math.ceil', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_ceil(jsonb[])', 10),
  ('math_floor_double', 'math.floor', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_floor(jsonb[])', 10),
  ('math_round_double', 'math.round', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_round(jsonb[])', 10),
  ('math_trunc_double', 'math.trunc', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_trunc(jsonb[])', 10),
  ('math_isInf_double', 'math.isInf', false,
   '[{"kind": "double"}]', '{"kind": "bool"}',
   'cel._f_math_isinf(jsonb[])', 10),
  ('math_isNaN_double', 'math.isNaN', false,
   '[{"kind": "double"}]', '{"kind": "bool"}',
   'cel._f_math_isnan(jsonb[])', 10),
  ('math_isFinite_double', 'math.isFinite', false,
   '[{"kind": "double"}]', '{"kind": "bool"}',
   'cel._f_math_isfinite(jsonb[])', 10),
  ('math_abs_double', 'math.abs', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_abs(jsonb[])', 10),
  ('math_abs_int', 'math.abs', false,
   '[{"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_abs(jsonb[])', 20),
  ('math_abs_uint', 'math.abs', false,
   '[{"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_abs(jsonb[])', 30),
  ('math_sign_double', 'math.sign', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_sign(jsonb[])', 10),
  ('math_sign_int', 'math.sign', false,
   '[{"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_sign(jsonb[])', 20),
  ('math_sign_uint', 'math.sign', false,
   '[{"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_sign(jsonb[])', 30),
  ('math_sqrt_double', 'math.sqrt', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_sqrt(jsonb[])', 10),
  ('math_sqrt_int', 'math.sqrt', false,
   '[{"kind": "int"}]', '{"kind": "double"}',
   'cel._f_math_sqrt(jsonb[])', 20),
  ('math_sqrt_uint', 'math.sqrt', false,
   '[{"kind": "uint"}]', '{"kind": "double"}',
   'cel._f_math_sqrt(jsonb[])', 30),
  ('math_bitAnd_int_int', 'math.bitAnd', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitand(jsonb[])', 10),
  ('math_bitAnd_uint_uint', 'math.bitAnd', false,
   '[{"kind": "uint"}, {"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitand(jsonb[])', 20),
  ('math_bitOr_int_int', 'math.bitOr', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitor(jsonb[])', 10),
  ('math_bitOr_uint_uint', 'math.bitOr', false,
   '[{"kind": "uint"}, {"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitor(jsonb[])', 20),
  ('math_bitXor_int_int', 'math.bitXor', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitxor(jsonb[])', 10),
  ('math_bitXor_uint_uint', 'math.bitXor', false,
   '[{"kind": "uint"}, {"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitxor(jsonb[])', 20),
  ('math_bitNot_int_int', 'math.bitNot', false,
   '[{"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitnot(jsonb[])', 10),
  ('math_bitNot_uint_uint', 'math.bitNot', false,
   '[{"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitnot(jsonb[])', 20),
  ('math_bitShiftLeft_int_int', 'math.bitShiftLeft', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_shl(jsonb[])', 10),
  ('math_bitShiftLeft_uint_int', 'math.bitShiftLeft', false,
   '[{"kind": "uint"}, {"kind": "int"}]', '{"kind": "uint"}',
   'cel._f_math_shl(jsonb[])', 20),
  ('math_bitShiftRight_int_int', 'math.bitShiftRight', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_shr(jsonb[])', 10),
  ('math_bitShiftRight_uint_int', 'math.bitShiftRight', false,
   '[{"kind": "uint"}, {"kind": "int"}]', '{"kind": "uint"}',
   'cel._f_math_shr(jsonb[])', 20)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'math', 'overload', id FROM cel.overload
WHERE function LIKE 'math.%'
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('math', 'macro', 'least/-1/1'),
  ('math', 'macro', 'greatest/-1/1')
ON CONFLICT DO NOTHING;

COMMIT;
