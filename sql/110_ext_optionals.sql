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
