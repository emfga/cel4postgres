-- cel4postgres -- type checker.
--
-- Annotates a parse envelope with types and refs, rewriting idents,
-- qualified selects and struct type names to fully-qualified form and
-- binding overload ids into call nodes -- the ids cel.eval dispatches
-- on (day-one invariant 2). The algorithm is cel-go's
-- checker/checker.go and checker/types.go (pinned v0.32.0), ported
-- rule by rule: parameter unification with an occurs check,
-- most-general rebinding, dyn/any/error as wildcards, legacy
-- nullability, and declaration-ordered overload resolution with
-- result-type widening.
--
-- Types are the doc-03 json encoding; the substitution mapping is a
-- jsonb object keyed by the parameter type's canonical jsonb text.
-- Errors fail fast: conformance asserts on check-failure existence,
-- never on collecting several.

BEGIN;

-- Type formatting for error messages (checker/format.go, loosely).
CREATE OR REPLACE FUNCTION cel._t_fmt(t jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := t ->> 'kind';
BEGIN
  RETURN CASE k
    WHEN 'list' THEN
      format('list(%s)', cel._t_fmt(t -> 'params' -> 0))
    WHEN 'map' THEN
      format('map(%s, %s)', cel._t_fmt(t -> 'params' -> 0),
        cel._t_fmt(t -> 'params' -> 1))
    WHEN 'wrapper' THEN
      format('wrapper(%s)', cel._t_fmt(t -> 'params' -> 0))
    WHEN 'type' THEN
      CASE WHEN t ? 'params'
           THEN format('type(%s)', cel._t_fmt(t -> 'params' -> 0))
           ELSE 'type' END
    WHEN 'param' THEN t ->> 'name'
    WHEN 'opaque' THEN
      CASE WHEN jsonb_array_length(coalesce(t -> 'params', '[]')) > 0
        THEN format('%s(%s)', t ->> 'name', (
          SELECT string_agg(cel._t_fmt(p), ', ')
          FROM jsonb_array_elements(t -> 'params') p))
        ELSE t ->> 'name' END
    WHEN 'struct' THEN t ->> 'name'
    WHEN 'error' THEN '!error!'
    WHEN 'null' THEN 'null'
    WHEN 'timestamp' THEN 'google.protobuf.Timestamp'
    WHEN 'duration' THEN 'google.protobuf.Duration'
    ELSE k
  END;
END;
$$;

CREATE OR REPLACE FUNCTION cel._t_is_dyn(t jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT t ->> 'kind' IN ('dyn', 'any');
$$;

CREATE OR REPLACE FUNCTION cel._t_dyn_or_err(t jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT t ->> 'kind' IN ('dyn', 'any', 'error');
$$;

-- substitute (types.go:276): follow binding chains; optionally
-- collapse unbound parameters to dyn (the checker's final pass).
CREATE OR REPLACE FUNCTION cel._ck_subst(m jsonb, t jsonb, todyn boolean)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sub  jsonb;
  ps   jsonb;
  p    jsonb;
BEGIN
  IF t ->> 'kind' = 'param' THEN
    sub := m -> (t::text);
    IF sub IS NOT NULL THEN
      RETURN cel._ck_subst(m, sub, todyn);
    END IF;
    IF todyn THEN
      RETURN '{"kind":"dyn"}'::jsonb;
    END IF;
    RETURN t;
  END IF;

  CASE t ->> 'kind'
    WHEN 'opaque', 'list', 'map', 'type' THEN
      IF NOT t ? 'params' THEN
        RETURN t;
      END IF;
      ps := '[]'::jsonb;
      FOR p IN SELECT e FROM jsonb_array_elements(t -> 'params') e LOOP
        ps := ps || jsonb_build_array(cel._ck_subst(m, p, todyn));
      END LOOP;
      RETURN jsonb_set(t, '{params}', ps);
    ELSE
      RETURN t;
  END CASE;
END;
$$;

-- isEqualOrLessSpecific (types.go:58).
CREATE OR REPLACE FUNCTION cel._ck_less_specific(t1 jsonb, t2 jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k1 text := t1 ->> 'kind';
  k2 text := t2 ->> 'kind';
  i  int;
BEGIN
  IF cel._t_is_dyn(t1) OR k1 = 'param' THEN
    RETURN true;
  END IF;
  IF cel._t_is_dyn(t2) OR k2 = 'param' THEN
    RETURN false;
  END IF;
  IF k1 <> k2 THEN
    RETURN false;
  END IF;
  CASE k1
    WHEN 'opaque' THEN
      IF t1 ->> 'name' <> t2 ->> 'name'
         OR jsonb_array_length(coalesce(t1 -> 'params', '[]'))
            <> jsonb_array_length(coalesce(t2 -> 'params', '[]')) THEN
        RETURN false;
      END IF;
      FOR i IN 0 .. jsonb_array_length(coalesce(t1 -> 'params', '[]')) - 1
      LOOP
        IF NOT cel._ck_less_specific(
             t1 -> 'params' -> i, t2 -> 'params' -> i) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    WHEN 'list' THEN
      RETURN cel._ck_less_specific(
        t1 -> 'params' -> 0, t2 -> 'params' -> 0);
    WHEN 'map' THEN
      RETURN cel._ck_less_specific(
          t1 -> 'params' -> 0, t2 -> 'params' -> 0)
        AND cel._ck_less_specific(
          t1 -> 'params' -> 1, t2 -> 'params' -> 1);
    WHEN 'type' THEN
      RETURN true;
    ELSE
      RETURN t1 = t2;
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION cel._ck_most_general(t1 jsonb, t2 jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN cel._ck_less_specific(t1, t2) THEN t1 ELSE t2 END;
$$;

-- notReferencedIn (types.go:251): the occurs check.
CREATE OR REPLACE FUNCTION cel._ck_not_ref_in(m jsonb, t jsonb, w jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sub jsonb;
  p   jsonb;
BEGIN
  IF t = w THEN
    RETURN false;
  END IF;
  CASE w ->> 'kind'
    WHEN 'param' THEN
      sub := m -> (w::text);
      IF sub IS NULL THEN
        RETURN true;
      END IF;
      RETURN cel._ck_not_ref_in(m, t, sub);
    WHEN 'opaque', 'list', 'map', 'type' THEN
      FOR p IN
        SELECT e FROM jsonb_array_elements(coalesce(w -> 'params', '[]')) e
      LOOP
        IF NOT cel._ck_not_ref_in(m, t, p) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    ELSE
      RETURN true;
  END CASE;
END;
$$;

-- isLegacyNullable + internalIsAssignableNull (types.go:208).
CREATE OR REPLACE FUNCTION cel._ck_nullable(t jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT t ->> 'kind' IN
    ('opaque', 'struct', 'any', 'duration', 'timestamp',
     'wrapper', 'null');
$$;

-- internalIsAssignable (types.go:100), with the mapping threaded in
-- and out. jsonb is by-value, so "copy on trial" is just returning
-- the old value on failure -- the callers below rely on that.
CREATE OR REPLACE FUNCTION cel._ck_assign1(
  m jsonb, t1 jsonb, t2 jsonb,
  OUT ok boolean, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k1  text := t1 ->> 'kind';
  k2  text := t2 ->> 'kind';
  s   record;
BEGIN
  mo := m;

  IF k2 = 'param' THEN
    SELECT * INTO s FROM cel._ck_valid_sub(mo, t1, t2);
    IF s.ok THEN
      ok := true;
      mo := s.mo;
      RETURN;
    END IF;
    IF s.hassub THEN
      ok := false;
      RETURN;
    END IF;
  END IF;
  IF k1 = 'param' THEN
    SELECT * INTO s FROM cel._ck_valid_sub(mo, t2, t1);
    ok := s.ok;
    IF s.ok THEN
      mo := s.mo;
    END IF;
    RETURN;
  END IF;

  IF cel._t_dyn_or_err(t1) OR cel._t_dyn_or_err(t2) THEN
    ok := true;
    RETURN;
  END IF;

  IF k1 = 'null' THEN
    ok := cel._ck_nullable(t2);
    RETURN;
  END IF;
  IF k2 = 'null' THEN
    ok := cel._ck_nullable(t1);
    RETURN;
  END IF;

  -- Wrappers accept their wrapped primitive (and null, above);
  -- nothing else accepts a wrapper except another identical wrapper
  -- or the wildcards already handled.
  IF k2 = 'wrapper' THEN
    ok := (k1 = 'wrapper' AND t1 -> 'params' = t2 -> 'params')
       OR t1 = t2 -> 'params' -> 0;
    RETURN;
  END IF;
  IF k1 = 'wrapper' THEN
    ok := false;
    RETURN;
  END IF;

  CASE k1
    WHEN 'bool', 'bytes', 'double', 'int', 'string', 'uint',
         'any', 'duration', 'timestamp' THEN
      ok := k1 = k2;
      RETURN;
    WHEN 'struct' THEN
      ok := k2 = 'struct' AND t1 ->> 'name' = t2 ->> 'name';
      RETURN;
    WHEN 'type' THEN
      ok := k2 = 'type';
      RETURN;
    WHEN 'opaque', 'list', 'map' THEN
      IF k1 <> k2
         OR coalesce(t1 ->> 'name', '') <> coalesce(t2 ->> 'name', '')
      THEN
        ok := false;
        RETURN;
      END IF;
      SELECT * INTO s FROM cel._ck_assign_list(mo,
        coalesce(t1 -> 'params', '[]'),
        coalesce(t2 -> 'params', '[]'));
      ok := s.ok;
      IF s.ok THEN
        mo := s.mo;
      END IF;
      RETURN;
    ELSE
      ok := false;
      RETURN;
  END CASE;
END;
$$;

-- isValidTypeSubstitution (types.go:160): whether t2 (a parameter)
-- can substitute for t1.
CREATE OR REPLACE FUNCTION cel._ck_valid_sub(
  m jsonb, t1 jsonb, t2 jsonb,
  OUT ok boolean, OUT hassub boolean, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  t2sub jsonb;
  s     record;
  t2new jsonb;
BEGIN
  mo := m;
  IF t1 = t2 THEN
    ok := true;
    hassub := true;
    RETURN;
  END IF;

  t2sub := m -> (t2::text);
  IF t2sub IS NOT NULL THEN
    hassub := true;
    IF t1 = t2sub THEN
      ok := true;
      RETURN;
    END IF;
    SELECT * INTO s FROM cel._ck_assign1(mo, t1, t2sub);
    IF s.ok THEN
      mo := s.mo;
      t2new := cel._ck_most_general(t1, t2sub);
      IF cel._ck_not_ref_in(mo, t2, t2new) THEN
        mo := jsonb_set(mo, ARRAY[t2::text], t2new);
      END IF;
      ok := true;
      RETURN;
    END IF;
    ok := false;
    RETURN;
  END IF;

  hassub := false;
  IF cel._ck_not_ref_in(mo, t2, t1) THEN
    mo := jsonb_set(mo, ARRAY[t2::text], t1);
    ok := true;
    RETURN;
  END IF;
  ok := false;
END;
$$;

CREATE OR REPLACE FUNCTION cel._ck_assign_list(
  m jsonb, l1 jsonb, l2 jsonb,
  OUT ok boolean, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int;
  s record;
BEGIN
  mo := m;
  IF jsonb_array_length(l1) <> jsonb_array_length(l2) THEN
    ok := false;
    RETURN;
  END IF;
  FOR i IN 0 .. jsonb_array_length(l1) - 1 LOOP
    SELECT * INTO s FROM cel._ck_assign1(mo, l1 -> i, l2 -> i);
    IF NOT s.ok THEN
      ok := false;
      mo := m;
      RETURN;
    END IF;
    mo := s.mo;
  END LOOP;
  ok := true;
END;
$$;

-- joinTypes (checker.go:616) with cel-go's default dyn fallback for
-- heterogeneous aggregate literals.
CREATE OR REPLACE FUNCTION cel._ck_join(
  m jsonb, prev jsonb, cur jsonb,
  OUT t jsonb, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s record;
BEGIN
  mo := m;
  IF prev IS NULL THEN
    t := cur;
    RETURN;
  END IF;
  SELECT * INTO s FROM cel._ck_assign1(mo, prev, cur);
  IF s.ok THEN
    mo := s.mo;
    -- Joining null with a nullable type keeps the nullable type:
    -- the corpus's legacy_nullable_types section fixes this and
    -- cel-go v0.32.0 skips those cases as known-wrong (its
    -- mostGeneral would answer null) -- see the workspace
    -- measurements log for the adjudication.
    IF prev ->> 'kind' = 'null' AND cel._ck_nullable(cur)
       AND cur ->> 'kind' <> 'null' THEN
      t := cur;
    ELSIF cur ->> 'kind' = 'null' AND cel._ck_nullable(prev)
       AND prev ->> 'kind' <> 'null' THEN
      t := prev;
    ELSE
      t := cel._ck_most_general(prev, cur);
    END IF;
    RETURN;
  END IF;
  t := '{"kind":"dyn"}'::jsonb;
END;
$$;

COMMIT;

BEGIN;

-- Fresh type variables and parameter instantiation.
CREATE OR REPLACE FUNCTION cel._ck_collect_params(t jsonb)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  acc text[] := '{}';
  p   jsonb;
BEGIN
  IF t ->> 'kind' = 'param' THEN
    RETURN ARRAY[t ->> 'name'];
  END IF;
  FOR p IN
    SELECT e FROM jsonb_array_elements(coalesce(t -> 'params', '[]')) e
  LOOP
    acc := acc || cel._ck_collect_params(p);
  END LOOP;
  RETURN acc;
END;
$$;

-- Rewrites the named parameters of one overload's signature to fresh
-- _var<N> parameters (checker.go:388-396).
CREATE OR REPLACE FUNCTION cel._ck_instantiate(
  arg_types jsonb, result_type jsonb, n int,
  OUT args jsonb, OUT result jsonb, OUT nn int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  names text[] := '{}';
  nm    text;
  fresh jsonb := '{}'::jsonb;
  a     jsonb;
BEGIN
  nn := n;
  names := (
    SELECT coalesce(array_agg(DISTINCT p), '{}')
    FROM (
      SELECT unnest(cel._ck_collect_params(result_type)
        || (SELECT coalesce(array_agg(x), '{}')
            FROM (SELECT unnest(cel._ck_collect_params(e)) AS x
                  FROM jsonb_array_elements(arg_types) e) u)) AS p
    ) q);
  FOREACH nm IN ARRAY names LOOP
    fresh := fresh || jsonb_build_object(
      jsonb_build_object('kind', 'param', 'name', nm)::text,
      jsonb_build_object('kind', 'param', 'name', '_var' || nn));
    nn := nn + 1;
  END LOOP;

  args := '[]'::jsonb;
  FOR a IN SELECT e FROM jsonb_array_elements(arg_types) e LOOP
    args := args || jsonb_build_array(cel._ck_subst(fresh, a, false));
  END LOOP;
  result := cel._ck_subst(fresh, result_type, false);
END;
$$;

-- Overload resolution (checker.go:339): declaration order, fresh
-- instantiation, assignability trial against a copy of the mapping,
-- result-type widening across multiple matches.
CREATE OR REPLACE FUNCTION cel._ck_resolve(
  fn text,
  is_member boolean,
  argtypes jsonb,
  envs text[],
  st jsonb,
  OUT ref jsonb, OUT rtype jsonb, OUT sto jsonb, OUT err text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  row_r record;
  inst  record;
  a     record;
  ids   jsonb := '[]'::jsonb;
  fnres jsonb;
  m     jsonb := st -> 'map';
  n     int := (st ->> 'n')::int;
  i     int;
  fmt_args text;
BEGIN
  sto := st;

  -- The variadic-logical special case (checker.go:365): every arg
  -- must be assignable to bool; the result is bool.
  IF fn IN ('_&&_', '_||_') THEN
    FOR i IN 0 .. jsonb_array_length(argtypes) - 1 LOOP
      SELECT * INTO a FROM cel._ck_assign1(
        m, argtypes -> i, '{"kind":"bool"}');
      IF NOT a.ok THEN
        err := format('expected type ''bool'' but found %s',
          quote_literal(cel._t_fmt(argtypes -> i)));
        RETURN;
      END IF;
      m := a.mo;
    END LOOP;
    SELECT jsonb_build_object(
      'overloads', jsonb_build_array(to_jsonb(o.id)))
    INTO ref
    FROM cel.overload o
    WHERE o.function = fn ORDER BY o.ordinal LIMIT 1;
    rtype := '{"kind":"bool"}'::jsonb;
    sto := jsonb_set(jsonb_set(st, '{map}', m), '{n}', to_jsonb(n));
    RETURN;
  END IF;

  -- Registry rows first, then caller-declared overloads (options
  -- 'decls' function entries, threaded in via st -> 'fns').
  FOR row_r IN
    SELECT q.id, q.member, q.arg_types, q.result_type
    FROM (
      SELECT o.id, o.member, o.arg_types, o.result_type, o.ordinal
      FROM cel.overload o
      WHERE o.function = fn
        AND EXISTS (
          SELECT FROM cel.env_item it
          WHERE it.env = ANY (envs) AND it.kind = 'overload'
            AND it.ref = o.id)
      UNION ALL
      SELECT e ->> 'id',
             coalesce((e ->> 'member')::boolean, false),
             e -> 'arg_types', e -> 'result_type',
             1000000 + (row_number() OVER ())::int
      FROM jsonb_array_elements(
        coalesce(st -> 'fns' -> fn, '[]'::jsonb)) e
    ) q
    ORDER BY q.ordinal
  LOOP
    CONTINUE WHEN row_r.member <> is_member;

    SELECT * INTO inst
    FROM cel._ck_instantiate(row_r.arg_types, row_r.result_type, n);
    n := inst.nn;

    SELECT * INTO a
    FROM cel._ck_assign_list(m, argtypes, inst.args);
    IF a.ok THEN
      m := a.mo;
      ids := ids || to_jsonb(row_r.id);
      fnres := cel._ck_subst(m, inst.result, false);
      IF rtype IS NULL THEN
        rtype := fnres;
      ELSIF NOT cel._t_is_dyn(rtype) AND fnres <> rtype THEN
        rtype := '{"kind":"dyn"}'::jsonb;
      END IF;
    END IF;
  END LOOP;

  IF rtype IS NULL THEN
    SELECT string_agg(cel._t_fmt(cel._ck_subst(m, e, true)), ', ')
      INTO fmt_args
    FROM jsonb_array_elements(argtypes)
      WITH ORDINALITY q(e, o)
    WHERE NOT is_member OR o > 1;
    IF is_member THEN
      err := format(
        'found no matching overload for %s applied to ''%s.(%s)''',
        quote_literal(fn),
        cel._t_fmt(cel._ck_subst(m, argtypes -> 0, true)),
        coalesce(fmt_args, ''));
    ELSE
      err := format(
        'found no matching overload for %s applied to ''(%s)''',
        quote_literal(fn), coalesce(fmt_args, ''));
    END IF;
    RETURN;
  END IF;

  ref := jsonb_build_object('overloads', ids);
  sto := jsonb_set(jsonb_set(st, '{map}', m), '{n}', to_jsonb(n));
END;
$$;


-- Field-selection result typing (checker.go:215 checkSelectField):
-- shared by the select branch and the _?._ optional-select call.
-- Unwraps an optional_type operand and reports it via was_opt.
CREATE OR REPLACE FUNCTION cel._ck_sel_type(
  op_t jsonb, st jsonb,
  OUT typ jsonb, OUT sto jsonb, OUT err text, OUT was_opt boolean
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s record;
BEGIN
  sto := st;
  was_opt := op_t ->> 'kind' = 'opaque'
         AND op_t ->> 'name' = 'optional_type';
  IF was_opt THEN
    op_t := cel._ck_subst(sto -> 'map', op_t -> 'params' -> 0,
      false);
  END IF;
  CASE op_t ->> 'kind'
    WHEN 'map' THEN
      typ := op_t -> 'params' -> 1;
    WHEN 'param' THEN
      SELECT * INTO s FROM cel._ck_assign1(
        sto -> 'map', '{"kind":"dyn"}', op_t);
      IF s.ok THEN
        sto := jsonb_set(sto, '{map}', s.mo);
      END IF;
      typ := '{"kind":"dyn"}'::jsonb;
    WHEN 'dyn', 'any', 'error' THEN
      typ := '{"kind":"dyn"}'::jsonb;
    WHEN 'wrapper' THEN
      typ := '{"kind":"dyn"}'::jsonb;
    ELSE
      err := format('type %s does not support field selection',
        quote_literal(cel._t_fmt(op_t)));
  END CASE;
END;
$$;

-- Local (comprehension) scope lookup, innermost first.
CREATE OR REPLACE FUNCTION cel._ck_local(scopes jsonb, name text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int;
BEGIN
  FOR i IN REVERSE jsonb_array_length(scopes) - 1 .. 0 LOOP
    IF scopes -> i ? name THEN
      RETURN scopes -> i -> name;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

-- Simple-identifier resolution (checker/env.go:152): local scope
-- first (unless absolute), then container candidates against the
-- global declarations. Returns the qualified name and its type.
CREATE OR REPLACE FUNCTION cel._ck_ident(
  name text, scopes jsonb, globals jsonb, ctr text,
  OUT qname text, OUT typ jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  absolute boolean := name LIKE '.%';
  bare     text := ltrim(name, '.');
  cand     text;
  loc      jsonb := cel._ck_local(scopes, bare);
BEGIN
  IF loc IS NOT NULL AND NOT absolute THEN
    qname := bare;
    typ := loc;
    RETURN;
  END IF;
  FOREACH cand IN ARRAY cel._name_candidates(bare, absolute, ctr) LOOP
    IF globals ? cand THEN
      -- A shadowing local forces runtime disambiguation: the dot
      -- survives into the rewritten ident so eval skips
      -- comprehension frames (checker/env.go
      -- requiresDisambiguation).
      qname := CASE WHEN loc IS NOT NULL THEN '.' || cand
                    ELSE cand END;
      typ := globals -> cand;
      RETURN;
    END IF;
  END LOOP;
END;
$$;

-- Qualified-identifier resolution (env.go:166): a local binding of
-- the root segment forces field selection instead.
CREATE OR REPLACE FUNCTION cel._ck_qualified(
  parts text[], absolute boolean, scopes jsonb, globals jsonb,
  ctr text,
  OUT qname text, OUT typ jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cand text;
  name text;
  loc  jsonb := cel._ck_local(scopes, parts[1]);
BEGIN
  IF loc IS NOT NULL AND NOT absolute THEN
    RETURN;
  END IF;
  name := array_to_string(parts, '.');
  FOREACH cand IN ARRAY cel._name_candidates(name, absolute, ctr) LOOP
    IF globals ? cand THEN
      -- Same disambiguation rule as _ck_ident: a local root plus a
      -- won global keeps the leading dot for runtime resolution.
      qname := CASE WHEN loc IS NOT NULL THEN '.' || cand
                    ELSE cand END;
      typ := globals -> cand;
      RETURN;
    END IF;
  END LOOP;
END;
$$;

COMMIT;

BEGIN;

-- Literal kinds to checker types.
CREATE OR REPLACE FUNCTION cel._ck_lit_type(v jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('kind',
    CASE v ->> '@t' WHEN 'null' THEN 'null' ELSE v ->> '@t' END);
$$;

-- The recursive checker. Returns the (possibly rewritten) node, its
-- type, and the threaded state {"types","refs","map","n"}; err set
-- means the whole check fails with that message.
CREATE OR REPLACE FUNCTION cel._ck(
  node jsonb,
  scopes jsonb,
  globals jsonb,
  envs text[],
  ctr text,
  st jsonb,
  OUT nodeo jsonb, OUT typ jsonb, OUT sto jsonb, OUT err text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  selr record;
  k     text := node ->> 'k';
  nid   text := node ->> 'id';
  c     record;
  r     record;
  q     record;
  chain record;
  argtypes jsonb;
  newargs  jsonb;
  target_t jsonb;
  fname    text;
  cand     text;
  i        int;
  elem_t   jsonb;
  key_t    jsonb;
  val_t    jsonb;
  op_t     jsonb;
  ents     jsonb;
  frame    jsonb;
  range_t  jsonb;
  accu_t   jsonb;
  var_t    jsonb;
  var2_t   jsonb;
  s        record;
BEGIN
  sto := st;
  nodeo := node;

  CASE k
  WHEN 'lit' THEN
    typ := cel._ck_lit_type(node -> 'v');

  WHEN 'ident' THEN
    SELECT * INTO q FROM cel._ck_ident(
      node ->> 'name', scopes, globals, ctr);
    IF q.qname IS NULL THEN
      err := format(
        'undeclared reference to %s (in container %s)',
        quote_literal(node ->> 'name'), quote_literal(ctr));
      RETURN;
    END IF;
    typ := q.typ;
    nodeo := jsonb_build_object(
      'id', node -> 'id', 'k', 'ident', 'name', q.qname);
    sto := jsonb_set(sto, ARRAY['refs', nid],
      jsonb_build_object('name', q.qname));

  WHEN 'select' THEN
    -- Qualified-name interpretation first (checker.go:134).
    IF NOT coalesce((node -> 'test')::boolean, false) THEN
      SELECT * INTO chain FROM cel._attr_chain(node);
      IF chain.parts IS NOT NULL THEN
        SELECT * INTO q FROM cel._ck_qualified(
          chain.parts, chain.absolute, scopes, globals, ctr);
        IF q.qname IS NOT NULL THEN
          typ := q.typ;
          nodeo := jsonb_build_object(
            'id', node -> 'id', 'k', 'ident', 'name', q.qname);
          sto := jsonb_set(sto, ARRAY['refs', nid],
            jsonb_build_object('name', q.qname));
          sto := jsonb_set(sto, ARRAY['types', nid], typ);
          RETURN;
        END IF;
      END IF;
    END IF;

    -- Field selection.
    SELECT * INTO c FROM cel._ck(
      node -> 'op', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(node, '{op}', c.nodeo);
    op_t := cel._ck_subst(sto -> 'map', c.typ, false);

    SELECT * INTO selr FROM cel._ck_sel_type(op_t, sto);
    IF selr.err IS NOT NULL THEN
      err := selr.err;
      RETURN;
    END IF;
    sto := selr.sto;
    typ := selr.typ;

    IF coalesce((node -> 'test')::boolean, false) THEN
      typ := '{"kind":"bool"}'::jsonb;
    ELSE
      typ := cel._ck_subst(sto -> 'map', typ, false);
      -- An optional operand makes the selection optional too
      -- (checker.go:253).
      IF selr.was_opt THEN
        typ := jsonb_build_object('kind', 'opaque',
          'name', 'optional_type',
          'params', jsonb_build_array(typ));
      END IF;
    END IF;

  WHEN 'call' THEN
    -- Check the arguments first, in order.
    newargs := '[]'::jsonb;
    argtypes := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'args') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'args' -> i, scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      newargs := newargs || jsonb_build_array(c.nodeo);
      argtypes := argtypes || jsonb_build_array(c.typ);
    END LOOP;
    nodeo := jsonb_set(node, '{args}', newargs);

    fname := node ->> 'fn';

    -- The optional-select operator is typed by field-selection
    -- logic, not overload resolution (checker.go:187
    -- checkOptSelect); its reference is the fixed function id.
    IF NOT node ? 'target' AND fname = '_?._' THEN
      SELECT * INTO selr FROM cel._ck_sel_type(
        cel._ck_subst(sto -> 'map', argtypes -> 0, false), sto);
      IF selr.err IS NOT NULL THEN
        err := selr.err;
        RETURN;
      END IF;
      sto := selr.sto;
      typ := jsonb_build_object('kind', 'opaque',
        'name', 'optional_type',
        'params', jsonb_build_array(
          cel._ck_subst(sto -> 'map', selr.typ, false)));
      nodeo := nodeo || jsonb_build_object('ref',
        jsonb_build_object('overloads',
          jsonb_build_array(to_jsonb('select_optional_field'::text))));
      sto := jsonb_set(sto, ARRAY['refs', nid],
        nodeo -> 'ref');
      RETURN;
    END IF;

    IF NOT node ? 'target' THEN
      -- Global call: resolve the function name through the
      -- container.
      SELECT n.c INTO cand
      FROM unnest(cel._name_candidates(
        ltrim(fname, '.'), fname LIKE '.%', ctr)) n(c)
      WHERE sto -> 'fns' ? n.c OR EXISTS (
        SELECT FROM cel.overload o
        WHERE o.function = n.c AND EXISTS (
          SELECT FROM cel.env_item it
          WHERE it.env = ANY (envs) AND it.kind = 'overload'
            AND it.ref = o.id))
      LIMIT 1;
      IF cand IS NULL THEN
        err := format(
          'undeclared reference to %s (in container %s)',
          quote_literal(fname), quote_literal(ctr));
        RETURN;
      END IF;
      nodeo := jsonb_set(nodeo, '{fn}', to_jsonb(cand));
      SELECT * INTO r FROM cel._ck_resolve(
        cand, false, argtypes, envs, sto);
    ELSE
      -- Receiver call: namespaced-function flattening first
      -- (a.b.fn() may be global function "a.b.fn").
      SELECT * INTO chain FROM cel._attr_chain(node -> 'target');
      cand := NULL;
      IF chain.parts IS NOT NULL THEN
        SELECT n.c INTO cand
        FROM unnest(cel._name_candidates(
          array_to_string(chain.parts, '.') || '.' || fname,
          chain.absolute, ctr)) n(c)
        WHERE sto -> 'fns' ? n.c OR EXISTS (
          SELECT FROM cel.overload o
          WHERE o.function = n.c AND EXISTS (
            SELECT FROM cel.env_item it
            WHERE it.env = ANY (envs) AND it.kind = 'overload'
              AND it.ref = o.id))
        LIMIT 1;
      END IF;
      IF cand IS NOT NULL THEN
        nodeo := (nodeo - 'target');
        nodeo := jsonb_set(nodeo, '{fn}', to_jsonb(cand));
        SELECT * INTO r FROM cel._ck_resolve(
          cand, false, argtypes, envs, sto);
      ELSE
        SELECT * INTO c FROM cel._ck(
          node -> 'target', scopes, globals, envs, ctr, sto);
        IF c.err IS NOT NULL THEN
          err := c.err;
          RETURN;
        END IF;
        sto := c.sto;
        nodeo := jsonb_set(nodeo, '{target}', c.nodeo);
        target_t := c.typ;

        IF NOT (sto -> 'fns' ? fname) AND NOT EXISTS (
          SELECT FROM cel.overload o
          WHERE o.function = fname AND EXISTS (
            SELECT FROM cel.env_item it
            WHERE it.env = ANY (envs) AND it.kind = 'overload'
              AND it.ref = o.id))
        THEN
          err := format(
            'undeclared reference to %s (in container %s)',
            quote_literal(fname), quote_literal(ctr));
          RETURN;
        END IF;
        SELECT * INTO r FROM cel._ck_resolve(
          fname, true,
          jsonb_build_array(target_t) || argtypes, envs, sto);
      END IF;
    END IF;

    IF r.err IS NOT NULL THEN
      err := r.err;
      RETURN;
    END IF;
    sto := r.sto;
    typ := r.rtype;
    nodeo := nodeo || jsonb_build_object('ref', r.ref);
    sto := jsonb_set(sto, ARRAY['refs', nid], r.ref);

  WHEN 'list' THEN
    elem_t := NULL;
    newargs := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'elems') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'elems' -> i, scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      newargs := newargs || jsonb_build_array(c.nodeo);
      SELECT * INTO s FROM cel._ck_join(sto -> 'map', elem_t, c.typ);
      elem_t := s.t;
      sto := jsonb_set(sto, '{map}', s.mo);
    END LOOP;
    nodeo := jsonb_set(node, '{elems}', newargs);
    IF elem_t IS NULL THEN
      elem_t := jsonb_build_object('kind', 'param',
        'name', '_var' || (sto ->> 'n'));
      sto := jsonb_set(sto, '{n}', to_jsonb((sto ->> 'n')::int + 1));
    END IF;
    typ := jsonb_build_object(
      'kind', 'list', 'params', jsonb_build_array(elem_t));

  WHEN 'map' THEN
    key_t := NULL;
    val_t := NULL;
    ents := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'entries') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'entries' -> i -> 'k',
        scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      SELECT * INTO s FROM cel._ck_join(sto -> 'map', key_t, c.typ);
      key_t := s.t;
      sto := jsonb_set(sto, '{map}', s.mo);
      frame := jsonb_set(node -> 'entries' -> i, '{k}', c.nodeo);

      SELECT * INTO c FROM cel._ck(
        frame -> 'v', scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      SELECT * INTO s FROM cel._ck_join(sto -> 'map', val_t, c.typ);
      val_t := s.t;
      sto := jsonb_set(sto, '{map}', s.mo);
      ents := ents || jsonb_build_array(
        jsonb_set(frame, '{v}', c.nodeo));
    END LOOP;
    nodeo := jsonb_set(node, '{entries}', ents);
    IF key_t IS NULL THEN
      key_t := jsonb_build_object('kind', 'param',
        'name', '_var' || (sto ->> 'n'));
      val_t := jsonb_build_object('kind', 'param',
        'name', '_var' || ((sto ->> 'n')::int + 1));
      sto := jsonb_set(sto, '{n}', to_jsonb((sto ->> 'n')::int + 2));
    END IF;
    typ := jsonb_build_object(
      'kind', 'map', 'params', jsonb_build_array(key_t, val_t));

  WHEN 'struct' THEN
    -- Message construction resolves through cel.type; without a
    -- descriptor pool only registered (WKT/opaque) types exist.
    SELECT t.name, t.kind INTO q
    FROM unnest(cel._name_candidates(
      ltrim(node ->> 'type', '.'),
      (node ->> 'type') LIKE '.%', ctr)) n(c)
    JOIN cel.type t ON t.name = n.c
    WHERE EXISTS (
      SELECT FROM cel.env_item it
      WHERE it.env = ANY (envs) AND it.kind = 'type'
        AND it.ref = t.name)
    LIMIT 1;
    IF q.name IS NULL THEN
      err := format(
        'undeclared reference to %s (in container %s)',
        quote_literal(node ->> 'type'), quote_literal(ctr));
      RETURN;
    END IF;
    -- Field checking against WKT shapes arrives with 070_wkt.sql;
    -- primitive type names are not message types.
    IF (q.kind ->> 'kind') NOT IN
       ('struct', 'map', 'list', 'dyn', 'wrapper',
        'timestamp', 'duration', 'any')
    THEN
      err := format('%s is not a message type',
        quote_literal(q.name));
      RETURN;
    END IF;
    ents := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'fields') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'fields' -> i -> 'v',
        scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      ents := ents || jsonb_build_array(
        jsonb_set(node -> 'fields' -> i, '{v}', c.nodeo));
    END LOOP;
    nodeo := jsonb_set(node, '{fields}', ents);
    nodeo := jsonb_set(nodeo, '{type}', to_jsonb(q.name));
    sto := jsonb_set(sto, ARRAY['refs', nid],
      jsonb_build_object('name', q.name));
    typ := q.kind;

  WHEN 'comp' THEN
    SELECT * INTO c FROM cel._ck(
      node -> 'range', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(node, '{range}', c.nodeo);
    range_t := cel._ck_subst(sto -> 'map', c.typ, false);

    SELECT * INTO c FROM cel._ck(
      node -> 'init', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{init}', c.nodeo);
    accu_t := c.typ;

    CASE range_t ->> 'kind'
      WHEN 'list' THEN
        var_t := range_t -> 'params' -> 0;
        IF node ->> 'iter2' <> '' THEN
          var2_t := var_t;
          var_t := '{"kind":"int"}'::jsonb;
        END IF;
      WHEN 'map' THEN
        var_t := range_t -> 'params' -> 0;
        IF node ->> 'iter2' <> '' THEN
          var2_t := range_t -> 'params' -> 1;
        END IF;
      WHEN 'dyn', 'any', 'error', 'param' THEN
        SELECT * INTO s FROM cel._ck_assign1(
          sto -> 'map', '{"kind":"dyn"}', range_t);
        IF s.ok THEN
          sto := jsonb_set(sto, '{map}', s.mo);
        END IF;
        var_t := '{"kind":"dyn"}'::jsonb;
        var2_t := '{"kind":"dyn"}'::jsonb;
      ELSE
        err := format(
          'expression of type %s cannot be range of a comprehension '
          || '(must be list, map, or dynamic)',
          quote_literal(cel._t_fmt(range_t)));
        RETURN;
    END CASE;

    -- Accu scope, then the loop scope with the iteration variables.
    frame := jsonb_build_object(node ->> 'accu', accu_t);
    scopes := scopes || jsonb_build_array(frame);
    frame := jsonb_build_object(node ->> 'iter', var_t);
    IF node ->> 'iter2' <> '' THEN
      frame := frame || jsonb_build_object(node ->> 'iter2', var2_t);
    END IF;
    scopes := scopes || jsonb_build_array(frame);

    SELECT * INTO c FROM cel._ck(
      node -> 'cond', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{cond}', c.nodeo);
    SELECT * INTO s FROM cel._ck_assign1(
      sto -> 'map', '{"kind":"bool"}', c.typ);
    IF NOT s.ok THEN
      err := format('expected type ''bool'' but found %s',
        quote_literal(cel._t_fmt(c.typ)));
      RETURN;
    END IF;
    sto := jsonb_set(sto, '{map}', s.mo);

    SELECT * INTO c FROM cel._ck(
      node -> 'step', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{step}', c.nodeo);
    SELECT * INTO s FROM cel._ck_assign1(
      sto -> 'map', accu_t, c.typ);
    IF NOT s.ok THEN
      err := format('expected type %s but found %s',
        quote_literal(cel._t_fmt(accu_t)),
        quote_literal(cel._t_fmt(c.typ)));
      RETURN;
    END IF;
    sto := jsonb_set(sto, '{map}', s.mo);

    -- Result checks with the iteration variables out of scope.
    scopes := scopes - (jsonb_array_length(scopes) - 1);
    SELECT * INTO c FROM cel._ck(
      node -> 'result', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{result}', c.nodeo);
    typ := cel._ck_subst(sto -> 'map', c.typ, false);

  ELSE
    err := format('unexpected AST node kind: %s', k);
    RETURN;
  END CASE;

  sto := jsonb_set(sto, ARRAY['types', nid], typ);
END;
$$;

-- Checks a parse envelope under an environment. options carries the
-- per-case container and extra ident declarations (decision 7).
-- Returns the annotated envelope, or {"errors": [...]}.
CREATE OR REPLACE FUNCTION cel.check(ast jsonb, env text, options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  envs    text[];
  ctr     text := coalesce(options ->> 'container', '');
  globals jsonb;
  st      jsonb;
  fns     jsonb := '{}'::jsonb;
  c       record;
  types   jsonb := '{}'::jsonb;
  entry   record;
BEGIN
  IF ast ? 'errors' THEN
    RAISE 'cannot check a failed parse';
  END IF;
  IF NOT ast ? 'expr' THEN
    RAISE 'not an AST envelope';
  END IF;

  envs := cel._env_names(env);

  -- Global declarations: the caller's decls plus a type(T) ident for
  -- every registered type visible in the env union.
  SELECT coalesce(jsonb_object_agg(
    t.name,
    jsonb_build_object('kind', 'type',
      'params', jsonb_build_array(t.kind))), '{}'::jsonb)
  INTO globals
  FROM cel.type t
  WHERE EXISTS (
    SELECT FROM cel.env_item it
    WHERE it.env = ANY (envs) AND it.kind = 'type'
      AND it.ref = t.name);

  -- Enum constants (kind->'enum') are int-typed idents under
  -- '<type>.<name>', mirroring cel-go's Provider.FindIdent.
  SELECT globals || coalesce(jsonb_object_agg(
    t.name || '.' || e.key, '{"kind":"int"}'::jsonb), '{}'::jsonb)
  INTO globals
  FROM cel.type t
  CROSS JOIN LATERAL jsonb_each(t.kind -> 'enum') e
  WHERE t.kind ? 'enum' AND EXISTS (
    SELECT FROM cel.env_item it
    WHERE it.env = ANY (envs) AND it.kind = 'type'
      AND it.ref = t.name);

  IF options ? 'decls' THEN
    SELECT globals || coalesce(jsonb_object_agg(
      d ->> 'name', d -> 'type'), '{}'::jsonb)
    INTO globals
    FROM jsonb_array_elements(options -> 'decls') d
    WHERE d ? 'type';
    -- Function declarations become caller-scoped overloads,
    -- threaded to _ck_resolve via the checker state.
    SELECT coalesce(jsonb_object_agg(
      d ->> 'name', d -> 'function' -> 'overloads'), '{}'::jsonb)
    INTO fns
    FROM jsonb_array_elements(options -> 'decls') d
    WHERE d ? 'function';
  END IF;

  st := jsonb_build_object(
    'types', '{}'::jsonb, 'refs', '{}'::jsonb,
    'map', '{}'::jsonb, 'n', 0, 'fns', fns);

  SELECT * INTO c FROM cel._ck(
    ast -> 'expr', '[]'::jsonb, globals, envs, ctr, st);
  IF c.err IS NOT NULL THEN
    RETURN jsonb_build_object('errors',
      jsonb_build_array(jsonb_build_object('msg', c.err)));
  END IF;

  -- Final substitution: unbound parameters collapse to dyn.
  FOR entry IN SELECT key, value FROM jsonb_each(c.sto -> 'types') LOOP
    types := types || jsonb_build_object(
      entry.key, cel._ck_subst(c.sto -> 'map', entry.value, true));
  END LOOP;

  RETURN (ast || jsonb_build_object(
    'expr', c.nodeo,
    'types', types,
    'refs', c.sto -> 'refs'));
END;
$$;

CREATE OR REPLACE FUNCTION cel.check(ast jsonb, env text)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel.check(ast, env, NULL);
$$;

COMMIT;
