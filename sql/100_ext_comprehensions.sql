-- The two-variable comprehensions extension (cel-go
-- ext.TwoVarComprehensions, ext/comprehensions.go at the pinned
-- v0.32.0): all/exists/existsOne/exists_one, transformList,
-- transformMap and transformMapEntry over (index, value) or
-- (key, value) pairs, plus the cel.@mapInsert helper the map
-- transforms expand to. Registered under the
-- 'two_var_comprehensions' env; nothing ships in 'standard'.
--
-- Extension scripts live at the top of sql/ with a 1xx prefix
-- because initdb runs only the directory's top level; a
-- subdirectory would silently not install.

BEGIN;

-- Extracts and validates the two iteration variables
-- (ext/comprehensions.go extractIterVars).
CREATE OR REPLACE FUNCTION cel._mx2_vars(
  a0 jsonb, a1 jsonb, OUT v1 text, OUT v2 text, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM cel._mx_itervar(a0);
  IF r.err IS NOT NULL THEN
    err := r.err;
    RETURN;
  END IF;
  v1 := r.name;
  SELECT * INTO r FROM cel._mx_itervar(a1);
  IF r.err IS NOT NULL THEN
    err := r.err;
    RETURN;
  END IF;
  v2 := r.name;
  IF v1 = v2 THEN
    err := format('duplicate variable name: %s', v1);
  END IF;
END;
$$;

-- The quantifiers and transformList share their fold wiring with
-- the one-variable macros; only the second iteration variable is
-- new.
CREATE OR REPLACE FUNCTION cel._mx2_quant(
  kind text, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx2_vars(args -> 0, args -> 1);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold(kind, target, v.v1, args -> 2, NULL, next_id);
  IF f.err IS NOT NULL THEN
    err := f.err;
    RETURN;
  END IF;
  expr := jsonb_set(f.expr, '{iter2}', to_jsonb(v.v2));
  next_id_out := f.next_id_out;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx2_all(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx2_quant('all', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_exists(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx2_quant('exists', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_exists_one(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx2_quant('exists_one', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_transform_list(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx2_vars(args -> 0, args -> 1);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  IF jsonb_array_length(args) = 4 THEN
    SELECT * INTO f FROM cel._mx_fold(
      'map_filter', target, v.v1, args -> 2, args -> 3, next_id);
  ELSE
    SELECT * INTO f FROM cel._mx_fold(
      'map', target, v.v1, NULL, args -> 2, next_id);
  END IF;
  IF f.err IS NOT NULL THEN
    err := f.err;
    RETURN;
  END IF;
  expr := jsonb_set(f.expr, '{iter2}', to_jsonb(v.v2));
  next_id_out := f.next_id_out;
END;
$$;

-- transformMap / transformMapEntry: fold into a map through
-- cel.@mapInsert (ext/comprehensions.go:333-397). entry_mode picks
-- the two-argument @mapInsert(accu, transform) form.
CREATE OR REPLACE FUNCTION cel._mx2_transform_map(
  entry_mode boolean, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  id bigint := next_id;
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  filter jsonb;
  transform jsonb;
  init jsonb;
  cond jsonb;
  step jsonb;
  accu jsonb;
  result jsonb;
  cargs jsonb;
BEGIN
  SELECT * INTO v FROM cel._mx2_vars(args -> 0, args -> 1);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  IF jsonb_array_length(args) = 4 THEN
    filter := args -> 2;
    transform := args -> 3;
  ELSE
    transform := args -> 2;
  END IF;

  id := id + 1;
  init := jsonb_build_object('id', id, 'k', 'map',
    'entries', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', true),
    's', cs, 'e', ce);
  id := id + 1;
  accu := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@result', 's', cs, 'e', ce);
  IF entry_mode THEN
    cargs := jsonb_build_array(accu, transform);
  ELSE
    id := id + 1;
    cargs := jsonb_build_array(accu,
      jsonb_build_object('id', id, 'k', 'ident', 'name', v.v1,
        's', cs, 'e', ce),
      transform);
  END IF;
  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'cel.@mapInsert', 'args', cargs, 's', cs, 'e', ce);
  IF filter IS NOT NULL THEN
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_?_:_', 'args', jsonb_build_array(filter, step, accu),
      's', cs, 'e', ce);
  END IF;
  id := id + 1;
  result := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@result', 's', cs, 'e', ce);

  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', target, 'iter', v.v1, 'iter2', v.v2,
    'accu', '@result',
    'init', init, 'cond', cond, 'step', step, 'result', result,
    's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx2_transform_map_3(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT *
  FROM cel._mx2_transform_map(false, target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_transform_map_entry(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT *
  FROM cel._mx2_transform_map(true, target, args, next_id);
$$;

-- cel.@mapInsert impls: inserting an existing key is an error
-- (cel-go types.InsertMapKeyValue).

CREATE OR REPLACE FUNCTION cel._f_map_insert_kv(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF cel._map_find(args[1], args[2]) IS NOT NULL THEN
    RETURN cel._err(format('insert failed: key %s already exists',
      args[2] ->> 'v'));
  END IF;
  RETURN jsonb_set(args[1], '{v}',
    (args[1] -> 'v') || jsonb_build_array(
      jsonb_build_object('k', args[2], 'v', args[3])));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_map_insert_map(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  acc jsonb := args[1];
  i   int;
BEGIN
  FOR i IN 0 .. jsonb_array_length(args[2] -> 'v') - 1 LOOP
    acc := cel._f_map_insert_kv(ARRAY[
      acc,
      args[2] -> 'v' -> i -> 'k',
      args[2] -> 'v' -> i -> 'v']);
    IF cel._is_error(acc) THEN
      RETURN acc;
    END IF;
  END LOOP;
  RETURN acc;
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('all',               3, true,
   'cel._mx2_all(jsonb,jsonb,bigint)'),
  ('exists',            3, true,
   'cel._mx2_exists(jsonb,jsonb,bigint)'),
  ('existsOne',         3, true,
   'cel._mx2_exists_one(jsonb,jsonb,bigint)'),
  ('exists_one',        3, true,
   'cel._mx2_exists_one(jsonb,jsonb,bigint)'),
  ('transformList',     3, true,
   'cel._mx2_transform_list(jsonb,jsonb,bigint)'),
  ('transformList',     4, true,
   'cel._mx2_transform_list(jsonb,jsonb,bigint)'),
  ('transformMap',      3, true,
   'cel._mx2_transform_map_3(jsonb,jsonb,bigint)'),
  ('transformMap',      4, true,
   'cel._mx2_transform_map_3(jsonb,jsonb,bigint)'),
  ('transformMapEntry', 3, true,
   'cel._mx2_transform_map_entry(jsonb,jsonb,bigint)'),
  ('transformMapEntry', 4, true,
   'cel._mx2_transform_map_entry(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('@mapInsert_map_key_value', 'cel.@mapInsert', false,
   '[{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]},
     {"kind": "param", "name": "K"},
     {"kind": "param", "name": "V"}]',
   '{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]}',
   'cel._f_map_insert_kv(jsonb[])', 10),
  ('@mapInsert_map_map', 'cel.@mapInsert', false,
   '[{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]},
     {"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]}]',
   '{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]}',
   'cel._f_map_insert_map(jsonb[])', 20)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'two_var_comprehensions', 'macro',
  format('%s/%s/%s', name, arity, member::int)
FROM cel.macro
WHERE arity IN (3, 4) AND member
  AND name IN ('all', 'exists', 'existsOne', 'exists_one',
               'transformList', 'transformMap', 'transformMapEntry')
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('two_var_comprehensions', 'overload', '@mapInsert_map_key_value'),
  ('two_var_comprehensions', 'overload', '@mapInsert_map_map')
ON CONFLICT DO NOTHING;

COMMIT;
