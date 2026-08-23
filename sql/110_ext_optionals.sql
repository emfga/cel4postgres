-- The optionals extension, part one: the optional_type opaque type
-- and the optional.of / optional.ofNonZeroValue / optional.none /
-- value / hasValue functions (cel-go cel/library.go optionals, pinned
-- v0.32.0). The optional-syntax sugar (x.?f, [?x], {?k: v}), or /
-- orValue, and the optMap/optFlatMap macros arrive with the Phase 6
-- extension work; type_deduction's optional sections need only the
-- declaration surface here.
--
-- An optional value is the opaque
--   {"@t": "opaque", "type": "optional_type", "v":
--     {"p": <present?>, "v": <value when present>}}
-- (day-one invariant 3: extension types are registry rows over the
-- opaque kind, never new core kinds).

BEGIN;

CREATE OR REPLACE FUNCTION cel._opt_of(v jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'optional_type',
    'v', jsonb_build_object('p', true, 'v', v));
$$;

CREATE OR REPLACE FUNCTION cel._opt_none()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'optional_type',
    'v', jsonb_build_object('p', false));
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_of(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._opt_of(args[1]);
$$;

-- ofNonZeroValue: none when the argument is its type's zero value
-- (cel-go types/optional.go / library.go).
CREATE OR REPLACE FUNCTION cel._f_opt_of_nonzero(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := args[1];
  zero boolean;
BEGIN
  zero := CASE v ->> '@t'
    WHEN 'int'    THEN (v ->> 'v')::numeric = 0
    WHEN 'uint'   THEN (v ->> 'v')::numeric = 0
    WHEN 'double' THEN (v ->> 'v') = '0'
                    OR (v ->> 'v')::float8 = 0
    WHEN 'bool'   THEN NOT (v ->> 'v')::boolean
    WHEN 'string' THEN v ->> 'v' = ''
    WHEN 'bytes'  THEN v ->> 'v' = ''
    WHEN 'list'   THEN jsonb_array_length(v -> 'v') = 0
    WHEN 'map'    THEN jsonb_array_length(v -> 'v') = 0
    WHEN 'null'   THEN true
    ELSE false
  END;
  RETURN CASE WHEN zero THEN cel._opt_none()
              ELSE cel._opt_of(v) END;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_none(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._opt_none();
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_value(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[1] -> 'v' ->> 'p')::boolean THEN args[1] -> 'v' -> 'v'
    ELSE cel._err('optional.none() dereference')
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_has_value(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val((args[1] -> 'v' ->> 'p')::boolean);
$$;

INSERT INTO cel.type (name, kind) VALUES
  ('optional_type',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}')
ON CONFLICT (name) DO UPDATE SET kind = excluded.kind;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('optional_of', 'optional.of', false,
   '[{"kind": "param", "name": "V"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_of(jsonb[])', 10),
  ('optional_ofNonZeroValue', 'optional.ofNonZeroValue', false,
   '[{"kind": "param", "name": "V"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_of_nonzero(jsonb[])', 10),
  ('optional_none', 'optional.none', false,
   '[]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_none(jsonb[])', 10),
  ('optional_value', 'value', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]}]',
   '{"kind": "param", "name": "V"}',
   'cel._f_opt_value(jsonb[])', 10),
  ('optional_hasValue', 'hasValue', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]}]',
   '{"kind": "bool"}',
   'cel._f_opt_has_value(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('optionals', 'type', 'optional_type'),
  ('optionals', 'overload', 'optional_of'),
  ('optionals', 'overload', 'optional_ofNonZeroValue'),
  ('optionals', 'overload', 'optional_none'),
  ('optionals', 'overload', 'optional_value'),
  ('optionals', 'overload', 'optional_hasValue')
ON CONFLICT DO NOTHING;

COMMIT;

BEGIN;

-- Part two: the optional-syntax operators, or/orValue, and the
-- optMap/optFlatMap macros (cel/library.go optionals block,
-- cel/library.go:430-560 at the pinned v0.32.0).

-- select_optional_field (_?._): field presence lifted into an
-- optional; distributes over an optional operand.
CREATE OR REPLACE FUNCTION cel._f_opt_select(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := args[1];
  r jsonb;
BEGIN
  IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type' THEN
    IF NOT (v -> 'v' ->> 'p')::boolean THEN
      RETURN v;
    END IF;
    RETURN cel._f_opt_select(ARRAY[v -> 'v' -> 'v', args[2]]);
  END IF;
  IF v ->> '@t' = 'map' THEN
    r := cel._map_find(v, args[2]);
    IF r IS NULL THEN
      RETURN cel._opt_none();
    END IF;
    RETURN cel._opt_of(r);
  END IF;
  RETURN cel._err(format(
    'does not support field selection: %s', v ->> '@t'));
END;
$$;

-- _[?_]: index presence lifted into an optional; distributes over
-- an optional operand.
CREATE OR REPLACE FUNCTION cel._f_opt_index(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := args[1];
  k jsonb := args[2];
  r jsonb;
  n numeric;
BEGIN
  IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type' THEN
    IF NOT (v -> 'v' ->> 'p')::boolean THEN
      RETURN v;
    END IF;
    RETURN cel._f_opt_index(ARRAY[v -> 'v' -> 'v', k]);
  END IF;
  IF v ->> '@t' = 'list' THEN
    IF k ->> '@t' NOT IN ('int', 'uint', 'double') THEN
      RETURN cel._err(format('no such overload: %s[?%s]',
        v ->> '@t', k ->> '@t'));
    END IF;
    n := (k ->> 'v')::numeric;
    IF n <> trunc(n) OR n < 0
       OR n >= jsonb_array_length(v -> 'v') THEN
      RETURN cel._opt_none();
    END IF;
    RETURN cel._opt_of(v -> 'v' -> n::int);
  END IF;
  IF v ->> '@t' = 'map' THEN
    r := cel._map_find(v, k);
    IF r IS NULL THEN
      RETURN cel._opt_none();
    END IF;
    RETURN cel._opt_of(r);
  END IF;
  RETURN cel._err(format('no such overload: %s[?_]', v ->> '@t'));
END;
$$;

-- Plain _[_] with an optional operand: none stays none, a present
-- container indexes strictly and re-wraps.
CREATE OR REPLACE FUNCTION cel._f_opt_index_strict(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  -- Qualification of an optional is always if-present in cel-go's
  -- attribute machinery: a missing key or index yields none, not an
  -- error (measured: optionals/optional_chaining_5..11).
  RETURN cel._f_opt_index(args);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_or(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN (args[1] -> 'v' ->> 'p')::boolean
              THEN args[1] ELSE args[2] END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_or_value(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN (args[1] -> 'v' ->> 'p')::boolean
              THEN args[1] -> 'v' -> 'v' ELSE args[2] END;
$$;

-- optMap / optFlatMap (cel/library.go optMap/optFlatMap): expand to
--   target.hasValue()
--     ? <of?>(bind(v, target.value(), expr))
--     : optional.none()
-- with the target itself bound to @target first when it is not a
-- simple identifier.
CREATE OR REPLACE FUNCTION cel._mx_opt_map(
  flat boolean, target jsonb, args jsonb, next_id bigint,
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
  nm text;
  tgt jsonb;
  hasv jsonb;
  valv jsonb;
  innerc jsonb;
  cond jsonb;
  step jsonb;
  nonec jsonb;
  branch jsonb;
BEGIN
  IF args -> 0 ->> 'k' <> 'ident' THEN
    err := format('opt%s() variable name must be a simple '
      || 'identifier', CASE WHEN flat THEN 'FlatMap' ELSE 'Map' END);
    RETURN;
  END IF;
  nm := args -> 0 ->> 'name';

  IF target ->> 'k' = 'ident' THEN
    tgt := target;
  ELSE
    id := id + 1;
    tgt := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@target', 's', cs, 'e', ce);
  END IF;

  id := id + 1;
  hasv := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'hasValue', 'target', tgt, 'args', '[]'::jsonb,
    's', cs, 'e', ce);
  id := id + 1;
  valv := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'value', 'target', tgt, 'args', '[]'::jsonb,
    's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'ident',
    'name', nm, 's', cs, 'e', ce);
  id := id + 1;
  innerc := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', jsonb_build_object('id', id, 'k', 'list',
      'elems', '[]'::jsonb, 's', cs, 'e', ce),
    'iter', '#unused', 'iter2', '', 'accu', nm,
    'init', valv, 'cond', cond, 'step', step,
    'result', args -> 1, 's', cs, 'e', ce);
  IF NOT flat THEN
    id := id + 1;
    innerc := jsonb_build_object('id', id, 'k', 'call',
      'fn', 'optional.of', 'args', jsonb_build_array(innerc),
      's', cs, 'e', ce);
  END IF;
  id := id + 1;
  nonec := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'optional.none', 'args', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  branch := jsonb_build_object('id', id, 'k', 'call',
    'fn', '_?_:_',
    'args', jsonb_build_array(hasv, innerc, nonec),
    's', cs, 'e', ce);

  IF target ->> 'k' = 'ident' THEN
    expr := branch;
    next_id_out := id;
    RETURN;
  END IF;

  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@target', 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', jsonb_build_object('id', id, 'k', 'list',
      'elems', '[]'::jsonb, 's', cs, 'e', ce),
    'iter', '#unused', 'iter2', '', 'accu', '@target',
    'init', target, 'cond', cond, 'step', step,
    'result', branch, 's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_opt_map_2(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_opt_map(false, target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx_opt_flat_map(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_opt_map(true, target, args, next_id);
$$;

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('optMap', 2, true, 'cel._mx_opt_map_2(jsonb,jsonb,bigint)'),
  ('optFlatMap', 2, true,
   'cel._mx_opt_flat_map(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('optional_or_optional', 'or', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]},
     {"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_or(jsonb[])', 10),
  ('optional_orValue_value', 'orValue', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]},
     {"kind": "param", "name": "V"}]',
   '{"kind": "param", "name": "V"}',
   'cel._f_opt_or_value(jsonb[])', 10),
  ('select_optional_field', '_?._', false,
   '[{"kind": "dyn"}, {"kind": "string"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_select(jsonb[])', 10),
  ('list_optindex_optional_int', '_[?_]', false,
   '[{"kind": "list", "params": [{"kind": "param", "name": "V"}]},
     {"kind": "int"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 10),
  ('optional_list_optindex_optional_int', '_[?_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "list", "params": [{"kind": "param",
        "name": "V"}]}]},
     {"kind": "int"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 20),
  ('map_optindex_optional_value', '_[?_]', false,
   '[{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]},
     {"kind": "param", "name": "K"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 30),
  ('optional_map_optindex_optional_value', '_[?_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "map", "params": [{"kind": "param", "name": "K"},
        {"kind": "param", "name": "V"}]}]},
     {"kind": "param", "name": "K"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 40),
  ('optional_list_index_int', '_[_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "list", "params": [{"kind": "param",
        "name": "V"}]}]},
     {"kind": "int"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index_strict(jsonb[])', 30),
  ('optional_map_index_value', '_[_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "map", "params": [{"kind": "param", "name": "K"},
        {"kind": "param", "name": "V"}]}]},
     {"kind": "param", "name": "K"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index_strict(jsonb[])', 40)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('optionals', 'overload', 'optional_or_optional'),
  ('optionals', 'overload', 'optional_orValue_value'),
  ('optionals', 'overload', 'select_optional_field'),
  ('optionals', 'overload', 'list_optindex_optional_int'),
  ('optionals', 'overload', 'optional_list_optindex_optional_int'),
  ('optionals', 'overload', 'map_optindex_optional_value'),
  ('optionals', 'overload', 'optional_map_optindex_optional_value'),
  ('optionals', 'overload', 'optional_list_index_int'),
  ('optionals', 'overload', 'optional_map_index_value'),
  ('optionals', 'macro', 'optMap/2/1'),
  ('optionals', 'macro', 'optFlatMap/2/1')
ON CONFLICT DO NOTHING;

COMMIT;
