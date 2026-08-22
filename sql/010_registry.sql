-- cel4postgres -- the four registries.
--
-- An extension is rows in these tables plus PL/pgSQL functions; it is
-- never a patch to the core. The standard library itself registers
-- through them (seeded by 030_parse.sql and 060_stdlib.sql) -- if the
-- core could reach anything the registry cannot describe, the
-- registry would stop being the extension mechanism.

BEGIN;

-- Custom and well-known types: name resolution, construction,
-- equality and conversion hooks. Every row visible in an env also
-- implies an identifier of type type(T) under the type's name.
CREATE TABLE IF NOT EXISTS cel.type (
  name       text PRIMARY KEY,
  kind       jsonb NOT NULL,
  construct  regprocedure,
  equal      regprocedure,
  convert    regprocedure,
  doc        text
);

-- Overloads: the unit of dispatch. cel.check binds ids from here;
-- cel.eval dispatches on the bound id and never on a function name.
-- ordinal preserves cel-go's declaration order, because overload
-- resolution and multi-match widening are order-sensitive.
CREATE TABLE IF NOT EXISTS cel.overload (
  id          text PRIMARY KEY,
  function    text NOT NULL,
  member      boolean NOT NULL,
  arg_types   jsonb NOT NULL,
  result_type jsonb NOT NULL,
  impl        regprocedure,
  non_strict  boolean NOT NULL DEFAULT false,
  ordinal     int NOT NULL,
  doc         text
);

CREATE INDEX IF NOT EXISTS overload_function
  ON cel.overload (function, ordinal);

-- Parse-time macros. arity -1 is variadic. The expander signature is
--   expander(target jsonb, args jsonb, next_id bigint)
--     RETURNS (expr jsonb, next_id bigint, err text)
-- returning NULL expr with NULL err to decline the expansion.
CREATE TABLE IF NOT EXISTS cel.macro (
  name     text NOT NULL,
  arity    int NOT NULL,
  member   boolean NOT NULL,
  expander regprocedure NOT NULL,
  PRIMARY KEY (name, arity, member)
);

-- Named environments: a bundle of visible overloads, macros and
-- types, plus parse-level feature flags (optional_syntax, ...).
-- kind='env' composes environments; the API's env argument is
-- additionally a comma-separated union of names.
CREATE TABLE IF NOT EXISTS cel.env (
  name  text PRIMARY KEY,
  flags jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS cel.env_item (
  env  text NOT NULL REFERENCES cel.env (name),
  kind text NOT NULL CHECK (kind IN ('overload', 'macro', 'type', 'env')),
  ref  text NOT NULL,
  PRIMARY KEY (env, kind, ref)
);

-- Resolves an env argument ('standard', 'standard,strings', nested
-- includes) to the flat set of env names, cycle-safe. An unknown name
-- raises: a misconfigured environment is a caller bug, not a CEL
-- error value.
CREATE OR REPLACE FUNCTION cel._env_names(env text)
RETURNS text[]
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  pending text[];
  seen    text[] := '{}';
  current text;
  extra   text[];
BEGIN
  SELECT array_agg(btrim(n)) INTO pending
  FROM unnest(string_to_array(env, ',')) AS n
  WHERE btrim(n) <> '';

  IF pending IS NULL THEN
    RAISE 'empty env argument';
  END IF;

  WHILE cardinality(pending) > 0 LOOP
    current := pending[1];
    pending := pending[2:];
    CONTINUE WHEN current = ANY (seen);

    IF NOT EXISTS (SELECT FROM cel.env WHERE name = current) THEN
      RAISE 'unknown env %', quote_literal(current);
    END IF;
    seen := seen || current;

    SELECT array_agg(ref) INTO extra
    FROM cel.env_item
    WHERE env_item.env = current AND kind = 'env';
    IF extra IS NOT NULL THEN
      pending := pending || extra;
    END IF;
  END LOOP;

  RETURN seen;
END;
$$;

-- Merged parse-level flags of an env union. Later names win on
-- conflicting keys; flags are booleans in practice, set once by the
-- env that owns the feature, so conflicts do not arise today.
CREATE OR REPLACE FUNCTION cel._env_flags(env text)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  FROM (
    SELECT key, value,
           row_number() OVER (PARTITION BY key ORDER BY ord DESC) AS rn
    FROM unnest(cel._env_names(env)) WITH ORDINALITY AS e(name, ord)
    JOIN cel.env ON cel.env.name = e.name,
    LATERAL jsonb_each(cel.env.flags)
  ) flags
  WHERE rn = 1;
$$;

-- The macros visible to an env union, as one jsonb object the parser
-- looks up per call site without further table reads:
--   {"<name>/<arity>/<member>": "<callable name>", ...}
-- with arity -1 entries under their own key for the variadic probe.
CREATE OR REPLACE FUNCTION cel._env_macros(env text)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(
    jsonb_object_agg(
      format('%s/%s/%s', m.name, m.arity, m.member::int),
      split_part(m.expander::text, '(', 1)
    ),
    '{}'::jsonb
  )
  FROM cel.macro m
  WHERE EXISTS (
    SELECT FROM cel.env_item i
    WHERE i.env = ANY (cel._env_names(env))
      AND i.kind = 'macro'
      AND i.ref = format('%s/%s/%s', m.name, m.arity, m.member::int)
  );
$$;

-- The spec-conformant default environment. Its items are seeded by
-- the scripts that create the functions they reference. The
-- identifier-escape syntax (`a-b`) is part of standard parsing
-- (cel-go enables it corpus-wide); optional syntax is not.
INSERT INTO cel.env (name, flags)
VALUES ('standard', '{"ident_escape": true}')
ON CONFLICT (name) DO NOTHING;

-- Extension environments. The rows exist from day one so an env
-- union like 'standard,strings' resolves before the extension's own
-- install script has seeded any items into them; the scripts under
-- sql/ext/ fill them in later phases. optionals owns the
-- optional-syntax parse flag.
INSERT INTO cel.env (name, flags) VALUES
  ('strings', '{}'),
  ('math', '{}'),
  ('lists', '{}'),
  ('encoders', '{}'),
  ('bindings', '{}'),
  ('two_var_comprehensions', '{}'),
  ('optionals', '{"optional_syntax": true}'),
  ('network', '{}')
ON CONFLICT (name) DO NOTHING;

COMMIT;
