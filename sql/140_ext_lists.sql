-- The lists extension (cel-go ext/lists.go at the pinned v0.32.0):
-- slice, flatten, sort, sortBy (macro over @sortByAssociatedKeys),
-- lists.range, reverse, distinct. Registered under the 'lists' env.

BEGIN;

CREATE OR REPLACE FUNCTION cel._list_val(elems jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'list', 'v', elems);
$$;

CREATE OR REPLACE FUNCTION cel._f_list_slice(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l jsonb := args[1] -> 'v';
  a numeric := (args[2] ->> 'v')::numeric;
  b numeric := (args[3] ->> 'v')::numeric;
  n int := jsonb_array_length(l);
  o jsonb := '[]'::jsonb;
  i int;
BEGIN
  IF a < 0 OR b < 0 THEN
    RETURN cel._err(format('cannot slice(%s, %s), negative indexes '
      || 'not supported', a, b));
  END IF;
  IF a > b THEN
    RETURN cel._err(format('cannot slice(%s, %s), start index must '
      || 'be less than or equal to end index', a, b));
  END IF;
  IF n < b THEN
    RETURN cel._err(format('cannot slice(%s, %s), list is length %s',
      a, b, n));
  END IF;
  FOR i IN a::int .. b::int - 1 LOOP
    o := o || jsonb_build_array(l -> i);
  END LOOP;
  RETURN cel._list_val(o);
END;
$$;

CREATE OR REPLACE FUNCTION cel._list_flatten(l jsonb, depth numeric)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  o jsonb := '[]'::jsonb;
  e jsonb;
  i int;
BEGIN
  FOR i IN 0 .. jsonb_array_length(l) - 1 LOOP
    e := l -> i;
    IF e ->> '@t' = 'list' AND depth > 0 THEN
      o := o || cel._list_flatten(e -> 'v', depth - 1);
    ELSE
      o := o || jsonb_build_array(e);
    END IF;
  END LOOP;
  RETURN o;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_list_flatten(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  depth numeric := CASE WHEN cardinality(args) > 1
                        THEN (args[2] ->> 'v')::numeric ELSE 1 END;
BEGIN
  IF depth < 0 THEN
    RETURN cel._err('level must be non-negative');
  END IF;
  RETURN cel._list_val(cel._list_flatten(args[1] -> 'v', depth));
END;
$$;

-- sort()/sortBy() core: reorder list by the sort order of keys,
-- which must share one comparable runtime type (lists.go:539).
CREATE OR REPLACE FUNCTION cel._f_list_sort_by_keys(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l    jsonb := args[1] -> 'v';
  ks   jsonb := args[2] -> 'v';
  n    int := jsonb_array_length(l);
  kt   text;
  o    jsonb := '[]'::jsonb;
  idx  int[];
  i    int;
  j    int;
  tmp  int;
  c    jsonb;
BEGIN
  IF n <> jsonb_array_length(ks) THEN
    RETURN cel._err(format('@sortByAssociatedKeys() expected a list '
      || 'of the same size as the associated keys list, but got %s '
      || 'and %s elements respectively',
      n, jsonb_array_length(ks)));
  END IF;
  IF n = 0 THEN
    RETURN args[1];
  END IF;
  kt := ks -> 0 ->> '@t';
  IF kt NOT IN ('int', 'uint', 'double', 'bool', 'duration',
                'timestamp', 'string', 'bytes') THEN
    RETURN cel._err('list elements must be comparable');
  END IF;
  idx := '{}';
  FOR i IN 0 .. n - 1 LOOP
    IF (ks -> i ->> '@t') <> kt THEN
      RETURN cel._err('list elements must have the same type');
    END IF;
    idx := idx || i;
  END LOOP;
  -- Insertion sort on indices: stable, and adequate for
  -- conformance-sized lists.
  FOR i IN 2 .. n LOOP
    j := i;
    WHILE j > 1 LOOP
      c := cel._compare(ks -> idx[j], ks -> idx[j - 1]);
      IF cel._is_error(c) THEN
        RETURN c;
      END IF;
      EXIT WHEN (c ->> 'v')::int <> -1;
      tmp := idx[j];
      idx[j] := idx[j - 1];
      idx[j - 1] := tmp;
      j := j - 1;
    END LOOP;
  END LOOP;
  FOR i IN 1 .. n LOOP
    o := o || jsonb_build_array(l -> idx[i]);
  END LOOP;
  RETURN cel._list_val(o);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_list_sort(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_list_sort_by_keys(ARRAY[args[1], args[1]]);
$$;

CREATE OR REPLACE FUNCTION cel._f_lists_range(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n numeric := (args[1] ->> 'v')::numeric;
BEGIN
  IF n < 0 THEN
    RETURN cel._err(format(
      'lists.range: size must be non-negative, got %s', n));
  END IF;
  -- cel-go's conformance default limit.
  IF n > 1000000 THEN
    RETURN cel._err(format(
      'lists.range: size %s exceeds maximum allowed (1000000)', n));
  END IF;
  RETURN cel._list_val(coalesce((
    SELECT jsonb_agg(cel._int_val(i))
    FROM generate_series(0, n::int - 1) i), '[]'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_list_reverse(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._list_val(coalesce((
    SELECT jsonb_agg(e ORDER BY o DESC)
    FROM jsonb_array_elements(args[1] -> 'v')
      WITH ORDINALITY q(e, o)), '[]'::jsonb));
$$;

CREATE OR REPLACE FUNCTION cel._f_list_distinct(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l jsonb := args[1] -> 'v';
  o jsonb := '[]'::jsonb;
  i int;
  j int;
  seen boolean;
BEGIN
  FOR i IN 0 .. jsonb_array_length(l) - 1 LOOP
    seen := false;
    FOR j IN 0 .. jsonb_array_length(o) - 1 LOOP
      IF cel._equal(l -> i, o -> j) THEN
        seen := true;
        EXIT;
      END IF;
    END LOOP;
    IF NOT seen THEN
      o := o || jsonb_build_array(l -> i);
    END IF;
  END LOOP;
  RETURN cel._list_val(o);
END;
$$;

-- sortBy(e, keyExpr) expands to a bind-style comprehension
-- (lists.go:594): fold the target into @__sortBy_input__, then call
-- @sortByAssociatedKeys with the mapped keys.
CREATE OR REPLACE FUNCTION cel._mx_sort_by(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  id bigint := next_id;
  vref jsonb;
  mapc record;
  callx jsonb;
  init jsonb;
  cond jsonb;
  itv record;
BEGIN
  IF target ->> 'k' NOT IN
     ('list', 'select', 'ident', 'comp', 'call') THEN
    err := 'sortBy can only be applied to a list, identifier, '
        || 'comprehension, call or select expression';
    RETURN;
  END IF;
  SELECT * INTO itv FROM cel._mx_itervar(args -> 0);
  IF itv.err IS NOT NULL THEN
    err := itv.err;
    RETURN;
  END IF;
  id := id + 1;
  vref := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@__sortBy_input__', 's', cs, 'e', ce);
  SELECT * INTO mapc FROM cel._mx_fold(
    'map', vref, args -> 0 ->> 'name', NULL, args -> 1, id);
  IF mapc.err IS NOT NULL THEN
    err := mapc.err;
    RETURN;
  END IF;
  id := mapc.next_id_out + 1;
  vref := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@__sortBy_input__', 's', cs, 'e', ce);
  id := id + 1;
  callx := jsonb_build_object('id', id, 'k', 'call',
    'fn', '@sortByAssociatedKeys', 'target', vref,
    'args', jsonb_build_array(mapc.expr), 's', cs, 'e', ce);
  id := id + 1;
  init := jsonb_build_object('id', id, 'k', 'list',
    'elems', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  vref := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@__sortBy_input__', 's', cs, 'e', ce);
  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', init, 'iter', '#unused', 'iter2', '',
    'accu', '@__sortBy_input__',
    'init', target, 'cond', cond, 'step', vref, 'result', callx,
    's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('sortBy', 2, true, 'cel._mx_sort_by(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('list_slice', 'slice', true,
   '[{"kind": "list", "params": [{"kind": "param", "name": "T"}]},
     {"kind": "int"}, {"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_slice(jsonb[])', 10),
  ('list_flatten', 'flatten', true,
   '[{"kind": "list", "params": [{"kind": "list",
      "params": [{"kind": "param", "name": "T"}]}]}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_flatten(jsonb[])', 10),
  ('list_flatten_int', 'flatten', true,
   '[{"kind": "list", "params": [{"kind": "dyn"}]},
     {"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "dyn"}]}',
   'cel._f_list_flatten(jsonb[])', 20),
  ('lists_range', 'lists.range', false,
   '[{"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "int"}]}',
   'cel._f_lists_range(jsonb[])', 10),
  ('list_reverse', 'reverse', true,
   '[{"kind": "list", "params": [{"kind": "param", "name": "T"}]}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_reverse(jsonb[])', 20),
  ('list_distinct', 'distinct', true,
   '[{"kind": "list", "params": [{"kind": "param", "name": "T"}]}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_distinct(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- sort() and @sortByAssociatedKeys(): one row per comparable element
-- type, sharing an impl (lists.go templatedOverloads).
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT 'list_' || tn || '_sort', 'sort', true,
       jsonb_build_array(jsonb_build_object(
         'kind', 'list', 'params', jsonb_build_array(t))),
       jsonb_build_object(
         'kind', 'list', 'params', jsonb_build_array(t)),
       'cel._f_list_sort(jsonb[])', ord
FROM (VALUES
  ('int', '{"kind":"int"}'::jsonb, 10),
  ('uint', '{"kind":"uint"}'::jsonb, 20),
  ('double', '{"kind":"double"}'::jsonb, 30),
  ('bool', '{"kind":"bool"}'::jsonb, 40),
  ('google.protobuf.Duration', '{"kind":"duration"}'::jsonb, 50),
  ('google.protobuf.Timestamp', '{"kind":"timestamp"}'::jsonb, 60),
  ('string', '{"kind":"string"}'::jsonb, 70),
  ('bytes', '{"kind":"bytes"}'::jsonb, 80)
) v(tn, t, ord)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT 'list_' || tn || '_sortByAssociatedKeys',
       '@sortByAssociatedKeys', true,
       jsonb_build_array(
         '{"kind":"list","params":[{"kind":"param","name":"T"}]}'
           ::jsonb,
         jsonb_build_object(
           'kind', 'list', 'params', jsonb_build_array(t))),
       '{"kind":"list","params":[{"kind":"param","name":"T"}]}'
         ::jsonb,
       'cel._f_list_sort_by_keys(jsonb[])', ord
FROM (VALUES
  ('int', '{"kind":"int"}'::jsonb, 10),
  ('uint', '{"kind":"uint"}'::jsonb, 20),
  ('double', '{"kind":"double"}'::jsonb, 30),
  ('bool', '{"kind":"bool"}'::jsonb, 40),
  ('google.protobuf.Duration', '{"kind":"duration"}'::jsonb, 50),
  ('google.protobuf.Timestamp', '{"kind":"timestamp"}'::jsonb, 60),
  ('string', '{"kind":"string"}'::jsonb, 70),
  ('bytes', '{"kind":"bytes"}'::jsonb, 80)
) v(tn, t, ord)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'lists', 'overload', id FROM cel.overload
WHERE id IN ('list_slice', 'list_flatten', 'list_flatten_int',
             'lists_range', 'list_reverse', 'list_distinct')
   OR id LIKE 'list\_%\_sort'
   OR id LIKE 'list\_%\_sortByAssociatedKeys'
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('lists', 'macro', 'sortBy/2/1')
ON CONFLICT DO NOTHING;

COMMIT;
