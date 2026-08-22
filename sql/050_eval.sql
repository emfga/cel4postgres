-- cel4postgres -- evaluator core.
--
-- Recursive tree walk over the AST envelope. Errors and unknowns are
-- tagged values flowing up (never exceptions -- a Postgres exception
-- escaping cel.eval is by definition a bug in the evaluator), and
-- every call dispatches through cel.overload rows: the absorbing
-- overload ids (logical_and/or, conditional, not_strictly_false,
-- equals/not_equals, and the index qualifiers) are implemented here
-- because their semantics control argument evaluation or belong to
-- the attribute machinery, everything else EXECUTEs the row's impl.
-- No CASE on a function name anywhere -- day-one invariant 1.

BEGIN;

-- Signature match for runtime overload selection: does an evaluated
-- argument satisfy a declared argument type? Parameterized and
-- dynamic types erase to "match anything" at runtime; containers
-- match on their kind alone.
CREATE OR REPLACE FUNCTION cel._sig_match_one(argtype jsonb, v jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  tk text := argtype ->> 'kind';
  vk text := v ->> '@t';
BEGIN
  RETURN CASE tk
    WHEN 'dyn' THEN true
    WHEN 'any' THEN true
    WHEN 'param' THEN true
    WHEN 'wrapper' THEN
      vk = 'null' OR cel._sig_match_one(argtype -> 'params' -> 0, v)
    WHEN 'opaque' THEN
      vk = 'opaque' AND v ->> 'type' = argtype ->> 'name'
    WHEN 'struct' THEN vk = 'opaque' OR vk = 'map'
    ELSE vk = tk
  END;
END;
$$;

CREATE OR REPLACE FUNCTION cel._sig_match(arg_types jsonb, args jsonb[])
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int;
BEGIN
  IF jsonb_array_length(arg_types) <> cardinality(args) THEN
    RETURN false;
  END IF;
  FOR i IN 1 .. cardinality(args) LOOP
    IF NOT cel._sig_match_one(arg_types -> (i - 1), args[i]) THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;

-- Table-driven dispatch on evaluated arguments. ref carries the
-- checker's bound overload ids when present; without it (unchecked
-- eval) the candidates are every row of the function visible in the
-- env union, tried in cel-go's declaration order.
CREATE OR REPLACE FUNCTION cel._ev_dispatch(
  fn text,
  is_member boolean,
  args jsonb[],
  ref jsonb,
  envs text[],
  node_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  row_r  record;
  result jsonb;
BEGIN
  IF ref ? 'overloads' THEN
    FOR row_r IN
      SELECT o.*
      FROM jsonb_array_elements_text(ref -> 'overloads')
        WITH ORDINALITY b(id, ord)
      JOIN cel.overload o ON o.id = b.id
      ORDER BY b.ord
    LOOP
      IF cel._sig_match(row_r.arg_types, args) THEN
        EXECUTE format('SELECT %s($1)',
          split_part(row_r.impl::text, '(', 1))
        INTO result USING args;
        RETURN result;
      END IF;
    END LOOP;
  ELSE
    FOR row_r IN
      SELECT o.*
      FROM cel.overload o
      WHERE o.function = fn
        AND o.member = is_member
        AND o.impl IS NOT NULL
        AND EXISTS (
          SELECT FROM cel.env_item i
          WHERE i.env = ANY (envs)
            AND i.kind = 'overload' AND i.ref = o.id)
      ORDER BY o.ordinal
    LOOP
      IF cel._sig_match(row_r.arg_types, args) THEN
        EXECUTE format('SELECT %s($1)',
          split_part(row_r.impl::text, '(', 1))
        INTO result USING args;
        RETURN result;
      END IF;
    END LOOP;
  END IF;

  RETURN cel._err(format('found no matching overload for %s',
    quote_literal(fn)), node_id);
END;
$$;

-- The dotted parts of a pure ident/select chain ("a.b.c" ->
-- {a,b,c}), or NULL for anything else. absolute reports a leading
-- dot (root-scoped: container resolution does not apply).
CREATE OR REPLACE FUNCTION cel._attr_chain(
  node jsonb, OUT parts text[], OUT absolute boolean
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sub record;
BEGIN
  IF node ->> 'k' = 'ident' THEN
    absolute := (node ->> 'name') LIKE '.%';
    parts := ARRAY[ltrim(node ->> 'name', '.')];
    RETURN;
  END IF;
  IF node ->> 'k' = 'select'
     AND NOT coalesce((node -> 'test')::boolean, false) THEN
    SELECT * INTO sub FROM cel._attr_chain(node -> 'op');
    IF sub.parts IS NOT NULL THEN
      parts := sub.parts || (node ->> 'field');
      absolute := sub.absolute;
    END IF;
  END IF;
END;
$$;

-- Candidate variable names for a dotted name under a container:
-- container "a.b" tries a.b.name, a.name, name -- cel-go's namespace
-- resolution order (measured: container/shadowing runs in
-- measurements.md).
CREATE OR REPLACE FUNCTION cel._name_candidates(
  name text, absolute boolean, ctr text
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cands text[] := '{}';
  c     text := ctr;
BEGIN
  IF absolute OR coalesce(ctr, '') = '' THEN
    RETURN ARRAY[name];
  END IF;
  WHILE c <> '' LOOP
    cands := cands || (c || '.' || name);
    IF position('.' IN c) = 0 THEN
      EXIT;
    END IF;
    c := substr(c, 1, length(c) - position('.' IN reverse(c)));
  END LOOP;
  RETURN cands || name;
END;
$$;

-- Resolves a dotted chain against the scope stack. Scope wins over
-- name length: an inner frame binding "y" shadows an outer binding
-- of "y.z" (measured against cel-go -- the comprehension-shadowing
-- corpus cases depend on it). Within one frame, longer names win,
-- and container-qualified candidates come before bare ones.
-- Returns NULL when nothing resolves; otherwise the value and how
-- many chain parts it consumed.
CREATE OR REPLACE FUNCTION cel._resolve_chain(
  parts text[], absolute boolean, scopes jsonb, ctr text,
  OUT val jsonb, OUT used int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f     int;
  plen  int;
  cand  text;
  name  text;
BEGIN
  -- A leading dot pins the name to the input activation: cel-go's
  -- absoluteAttribute unwraps every comprehension frame before
  -- resolving when the checker marked the name for disambiguation
  -- (attributes.go, disambiguateNames).
  FOR f IN REVERSE CASE WHEN absolute THEN 0
                        ELSE jsonb_array_length(scopes) - 1 END .. 0
  LOOP
    FOR plen IN REVERSE cardinality(parts) .. 1 LOOP
      name := array_to_string(parts[1:plen], '.');
      FOREACH cand IN ARRAY cel._name_candidates(name, absolute, ctr)
      LOOP
        IF scopes -> f ? cand THEN
          val := scopes -> f -> cand;
          used := plen;
          RETURN;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END;
$$;

-- Resolves a dotted name as a registered type identifier (-> a type
-- value) or a registered enum constant (-> its tagged value, e.g.
-- google.protobuf.NullValue.NULL_VALUE -> int 0, mirroring cel-go's
-- Provider.FindIdent). NULL when the name is neither.
CREATE OR REPLACE FUNCTION cel._type_or_enum(
  name text, absolute boolean, envs text[], ctr text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r jsonb;
BEGIN
  SELECT jsonb_build_object('@t', 'type', 'v', c) INTO r
  FROM unnest(cel._name_candidates(name, absolute, ctr)) AS c
  WHERE EXISTS (
    SELECT FROM cel.type t
    WHERE t.name = c AND EXISTS (
      SELECT FROM cel.env_item i2
      WHERE i2.env = ANY (envs) AND i2.kind = 'type'
        AND i2.ref = t.name))
  LIMIT 1;
  IF r IS NOT NULL THEN
    RETURN r;
  END IF;
  SELECT jsonb_build_object('@t', 'int', 'v', e.value::bigint)
  INTO r
  FROM unnest(cel._name_candidates(name, absolute, ctr)) AS c
  JOIN cel.type t
    ON t.kind ? 'enum' AND c LIKE t.name || '.%'
  JOIN LATERAL jsonb_each_text(t.kind -> 'enum') e ON true
  WHERE t.name || '.' || e.key = c
    AND EXISTS (
      SELECT FROM cel.env_item i2
      WHERE i2.env = ANY (envs) AND i2.kind = 'type'
        AND i2.ref = t.name)
  LIMIT 1;
  RETURN r;
END;
$$;

-- Field selection on an already-evaluated value.
CREATE OR REPLACE FUNCTION cel._sel_field(v jsonb, field text, nid bigint)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r jsonb;
BEGIN
  IF cel._is_error(v) OR cel._is_unknown(v) THEN
    RETURN v;
  END IF;
  IF v ->> '@t' = 'map' THEN
    r := cel._map_find(v,
      jsonb_build_object('@t', 'string', 'v', field));
    IF r IS NULL THEN
      RETURN cel._err(format('no such key: %s', field), nid);
    END IF;
    RETURN r;
  END IF;
  RETURN cel._err(format(
    'does not support field selection: %s', v ->> '@t'), nid);
END;
$$;

-- The recursive evaluator.
CREATE OR REPLACE FUNCTION cel._ev(
  node jsonb,
  scopes jsonb,
  envs text[],
  ctr text,
  d int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k    text := node ->> 'k';
  nid  bigint := (node ->> 'id')::bigint;
  fn   text;
  v    jsonb;
  l    jsonb;
  r    jsonb;
  args jsonb[];
  unk  jsonb;
  i    int;
  elems jsonb;
  entries jsonb;
  key  jsonb;
  nm   text;
  eq   boolean;
  row_r record;
  chain record;
  res  record;
BEGIN
  IF d >= 200 THEN
    RETURN cel._err('expression recursion limit exceeded: 200', nid);
  END IF;

  CASE k
  WHEN 'lit' THEN
    RETURN node -> 'v';

  WHEN 'ident' THEN
    SELECT * INTO chain FROM cel._attr_chain(node);
    SELECT * INTO res
    FROM cel._resolve_chain(chain.parts, chain.absolute, scopes, ctr);
    IF res.val IS NOT NULL THEN
      RETURN res.val;
    END IF;
    -- Registered type names are identifiers of type type(T); enum
    -- constants resolve to their values.
    v := cel._type_or_enum(
      ltrim(node ->> 'name', '.'), chain.absolute, envs, ctr);
    IF v IS NOT NULL THEN
      RETURN v;
    END IF;
    RETURN cel._err(format('no such attribute: %s',
      ltrim(node ->> 'name', '.')), nid);

  WHEN 'select' THEN
    key := jsonb_build_object('@t', 'string', 'v', node ->> 'field');

    IF coalesce((node -> 'test')::boolean, false) THEN
      v := cel._ev(node -> 'op', scopes, envs, ctr, d + 1);
      IF cel._is_error(v) OR cel._is_unknown(v) THEN
        RETURN v;
      END IF;
      IF v ->> '@t' = 'map' THEN
        RETURN cel._bool_val(cel._map_find(v, key) IS NOT NULL);
      END IF;
      RETURN cel._err(format(
        'does not support field selection: %s', v ->> '@t'), nid);
    END IF;

    -- Qualified-name resolution: the scope stack decides between a
    -- bound "a.b" and field-selecting a bound "a".
    SELECT * INTO chain FROM cel._attr_chain(node);
    IF chain.parts IS NOT NULL THEN
      SELECT * INTO res
      FROM cel._resolve_chain(chain.parts, chain.absolute, scopes, ctr);
      IF res.val IS NOT NULL THEN
        v := res.val;
        FOR i IN res.used + 1 .. cardinality(chain.parts) LOOP
          v := cel._sel_field(v, chain.parts[i], nid);
        END LOOP;
        RETURN v;
      END IF;
      -- A fully-qualified type name or enum constant written as a
      -- select chain (unchecked ASTs only; the checker rewrites
      -- these to qualified idents).
      v := cel._type_or_enum(
        array_to_string(chain.parts, '.'), chain.absolute, envs,
        ctr);
      IF v IS NOT NULL THEN
        RETURN v;
      END IF;
    END IF;

    v := cel._ev(node -> 'op', scopes, envs, ctr, d + 1);
    IF cel._is_error(v) OR cel._is_unknown(v) THEN
      RETURN v;
    END IF;
    RETURN cel._sel_field(v, node ->> 'field', nid);

  WHEN 'call' THEN
    fn := node ->> 'fn';

    -- Core-absorbed overload ids: found by the same registry lookup
    -- as everything else (impl IS NULL marks them), implemented here
    -- because their semantics control argument evaluation. The
    -- dispatch is on the row's *id*, not the function name.
    SELECT o.id INTO nm
    FROM cel.overload o
    WHERE o.function = fn AND o.impl IS NULL
      AND o.member = (node ? 'target')
      AND EXISTS (
        SELECT FROM cel.env_item i2
        WHERE i2.env = ANY (envs) AND i2.kind = 'overload'
          AND i2.ref = o.id)
    ORDER BY o.ordinal
    LIMIT 1;

    IF nm = 'logical_and' OR nm = 'logical_or' THEN
      -- false && x = false in either order; true || x = true in
      -- either order; otherwise merged unknown beats first error
      -- beats the boolean identity.
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF l ->> '@t' = 'bool'
         AND (l ->> 'v')::boolean = (nm = 'logical_or') THEN
        RETURN l;
      END IF;
      r := cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      IF r ->> '@t' = 'bool'
         AND (r ->> 'v')::boolean = (nm = 'logical_or') THEN
        RETURN r;
      END IF;
      IF l ->> '@t' = 'bool' AND r ->> '@t' = 'bool' THEN
        RETURN l;   -- both are the identity value
      END IF;
      IF cel._is_unknown(l) AND cel._is_unknown(r) THEN
        RETURN cel._unknown_merge(l, r);
      END IF;
      IF cel._is_unknown(l) THEN RETURN l; END IF;
      IF cel._is_unknown(r) THEN RETURN r; END IF;
      IF cel._is_error(l) THEN RETURN l; END IF;
      IF cel._is_error(r) THEN RETURN r; END IF;
      RETURN cel._err('no such overload', nid);

    ELSIF nm = 'conditional' THEN
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF cel._is_error(l) OR cel._is_unknown(l) THEN
        RETURN l;
      END IF;
      IF l ->> '@t' <> 'bool' THEN
        RETURN cel._err('no such overload', nid);
      END IF;
      IF (l ->> 'v')::boolean THEN
        RETURN cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      END IF;
      RETURN cel._ev(node -> 'args' -> 2, scopes, envs, ctr, d + 1);

    ELSIF nm = 'not_strictly_false' THEN
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF l ->> '@t' = 'bool' THEN
        RETURN l;
      END IF;
      RETURN cel._bool_val(true);

    ELSIF nm = 'equals' OR nm = 'not_equals' THEN
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF cel._is_error(l) THEN
        RETURN l;
      END IF;
      r := cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      IF cel._is_error(r) THEN
        RETURN r;
      END IF;
      IF cel._is_unknown(l) AND cel._is_unknown(r) THEN
        RETURN cel._unknown_merge(l, r);
      END IF;
      IF cel._is_unknown(l) THEN RETURN l; END IF;
      IF cel._is_unknown(r) THEN RETURN r; END IF;
      eq := cel._equal(l, r);
      RETURN cel._bool_val(eq = (nm = 'equals'));

    ELSIF nm IN ('index_list', 'index_map') THEN
      -- Indexing is attribute machinery in cel-go's interpreter (the
      -- planner turns _[_] into a qualifier), which is what admits
      -- losslessly-coercible double/uint list indices at runtime;
      -- plain signature dispatch could not. Strict in both args.
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF cel._is_error(l) THEN RETURN l; END IF;
      r := cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      IF cel._is_error(r) THEN RETURN r; END IF;
      IF cel._is_unknown(l) AND cel._is_unknown(r) THEN
        RETURN cel._unknown_merge(l, r);
      END IF;
      IF cel._is_unknown(l) THEN RETURN l; END IF;
      IF cel._is_unknown(r) THEN RETURN r; END IF;
      IF l ->> '@t' = 'list' THEN
        RETURN cel._f_index_list(ARRAY[l, r]);
      ELSIF l ->> '@t' = 'map' THEN
        RETURN cel._f_index_map(ARRAY[l, r]);
      END IF;
      RETURN cel._err('no such overload', nid);
    END IF;

    -- Strict call: arguments left to right; first error wins, then
    -- merged unknowns.
    args := '{}';
    unk := NULL;
    IF node ? 'target' THEN
      v := cel._ev(node -> 'target', scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      args := args || v;
    END IF;
    FOR i IN 0 .. jsonb_array_length(node -> 'args') - 1 LOOP
      v := cel._ev(node -> 'args' -> i, scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      args := args || v;
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;

    RETURN cel._ev_dispatch(
      fn, node ? 'target', args, node -> 'ref', envs, nid);

  WHEN 'list' THEN
    elems := '[]'::jsonb;
    unk := NULL;
    FOR i IN 0 .. jsonb_array_length(node -> 'elems') - 1 LOOP
      v := cel._ev(node -> 'elems' -> i, scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      elems := elems || jsonb_build_array(v);
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;
    RETURN jsonb_build_object('@t', 'list', 'v', elems);

  WHEN 'map' THEN
    entries := '[]'::jsonb;
    unk := NULL;
    FOR i IN 0 .. jsonb_array_length(node -> 'entries') - 1 LOOP
      key := cel._ev(node -> 'entries' -> i -> 'k',
        scopes, envs, ctr, d + 1);
      IF cel._is_error(key) THEN RETURN key; END IF;
      v := cel._ev(node -> 'entries' -> i -> 'v',
        scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(key) THEN
        unk := CASE WHEN unk IS NULL THEN key
                    ELSE cel._unknown_merge(unk, key) END;
      END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      IF unk IS NULL THEN
        -- Key type restriction and duplicate rejection are dynamic
        -- (corpus-first rulings: forbidden double/null keys and
        -- normalized duplicates both error at construction).
        IF key ->> '@t' NOT IN ('bool', 'int', 'uint', 'string') THEN
          RETURN cel._err(format(
            'unsupported map key type: %s', key ->> '@t'), nid);
        END IF;
        IF cel._map_find(
             jsonb_build_object('@t', 'map', 'v', entries), key)
           IS NOT NULL THEN
          RETURN cel._err('Failed with repeated key', nid);
        END IF;
        entries := entries || jsonb_build_array(
          jsonb_build_object('k', key, 'v', v));
      END IF;
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;
    RETURN jsonb_build_object('@t', 'map', 'v', entries);

  WHEN 'struct' THEN
    nm := ltrim(node ->> 'type', '.');
    SELECT t.* INTO row_r
    FROM cel.type t
    WHERE t.name = ANY (cel._name_candidates(
        nm, (node ->> 'type') LIKE '.%', ctr))
      AND t.construct IS NOT NULL
      AND EXISTS (
        SELECT FROM cel.env_item i2
        WHERE i2.env = ANY (envs) AND i2.kind = 'type'
          AND i2.ref = t.name)
    LIMIT 1;
    IF NOT FOUND THEN
      RETURN cel._err(format('unknown message type: %s', nm), nid);
    END IF;
    -- Evaluate fields into an object, then hand to the type row's
    -- construct impl (invariant 3: WKTs and opaque extension types
    -- ride the same path).
    entries := '{}'::jsonb;
    unk := NULL;
    FOR i IN 0 .. jsonb_array_length(node -> 'fields') - 1 LOOP
      v := cel._ev(node -> 'fields' -> i -> 'v',
        scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      entries := entries || jsonb_build_object(
        node -> 'fields' -> i ->> 'name', v);
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;
    EXECUTE format('SELECT %s($1)',
      split_part(row_r.construct::text, '(', 1))
    INTO v USING entries;
    RETURN v;

  WHEN 'comp' THEN
    RETURN cel._ev_comp(node, scopes, envs, ctr, d);

  ELSE
    RETURN cel._err(format('unsupported AST node kind: %s', k), nid);
  END CASE;
END;
$$;

-- The comprehension fold (workspace doc 06). The loop-termination
-- rule is load-bearing: only a genuine bool false stops iteration --
-- an error or unknown condition keeps folding, which is how exists
-- recovers from early errors when a later element is true.
CREATE OR REPLACE FUNCTION cel._ev_comp(
  node jsonb,
  scopes jsonb,
  envs text[],
  ctr text,
  d int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  nid    bigint := (node ->> 'id')::bigint;
  iter   text := node ->> 'iter';
  iter2  text := node ->> 'iter2';
  accu_n text := node ->> 'accu';
  range_v jsonb;
  accu   jsonb;
  cond   jsonb;
  frame  jsonb;
  item1  jsonb;
  item2  jsonb;
  i      int;
  rk     text;
BEGIN
  range_v := cel._ev(node -> 'range', scopes, envs, ctr, d + 1);
  IF cel._is_error(range_v) OR cel._is_unknown(range_v) THEN
    RETURN range_v;
  END IF;
  rk := range_v ->> '@t';
  IF rk NOT IN ('list', 'map') THEN
    RETURN cel._err(format(
      'cannot iterate over: %s', rk), nid);
  END IF;

  accu := cel._ev(node -> 'init', scopes, envs, ctr, d + 1);
  IF cel._is_error(accu) OR cel._is_unknown(accu) THEN
    RETURN accu;
  END IF;

  FOR i IN 0 .. jsonb_array_length(range_v -> 'v') - 1 LOOP
    IF rk = 'list' THEN
      item1 := CASE WHEN iter2 = '' THEN range_v -> 'v' -> i
                    ELSE cel._int_val(i) END;
      item2 := range_v -> 'v' -> i;
    ELSE
      item1 := range_v -> 'v' -> i -> 'k';
      item2 := range_v -> 'v' -> i -> 'v';
    END IF;

    frame := jsonb_build_object(accu_n, accu, iter, item1);
    IF iter2 <> '' THEN
      frame := frame || jsonb_build_object(iter2, item2);
    END IF;

    cond := cel._ev(node -> 'cond',
      scopes || jsonb_build_array(frame), envs, ctr, d + 1);
    IF cond ->> '@t' = 'bool' AND NOT (cond ->> 'v')::boolean THEN
      EXIT;
    END IF;

    accu := cel._ev(node -> 'step',
      scopes || jsonb_build_array(frame), envs, ctr, d + 1);
  END LOOP;

  RETURN cel._ev(node -> 'result',
    scopes || jsonb_build_array(jsonb_build_object(accu_n, accu)),
    envs, ctr, d + 1);
END;
$$;

-- Evaluates a parsed (or checked) AST envelope under an activation
-- of tagged values. options carries what the corpus calls per-case
-- environment shape: today just "container", which unchecked
-- evaluation needs for name resolution (checked ASTs resolve names
-- at check time). STABLE, not IMMUTABLE: dispatch reads the
-- registry.
CREATE OR REPLACE FUNCTION cel.eval(
  ast jsonb,
  activation jsonb,
  env text,
  options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  envs text[];
BEGIN
  IF ast ? 'errors' THEN
    RAISE 'cannot evaluate a failed parse';
  END IF;
  IF NOT ast ? 'expr' THEN
    RAISE 'not an AST envelope';
  END IF;

  envs := cel._env_names(env);
  RETURN cel._ev(
    ast -> 'expr',
    jsonb_build_array(coalesce(activation, '{}'::jsonb)),
    envs,
    -- A checked AST already carries fully-qualified names; applying
    -- the container again would mis-resolve deliberately-bare names
    -- (the corpus disambiguation cases: a checked ident "y" must not
    -- become "com.example.y" at runtime).
    CASE WHEN ast ? 'types' THEN ''
         ELSE coalesce(options ->> 'container', '') END,
    0);
END;
$$;

CREATE OR REPLACE FUNCTION cel.eval(
  ast jsonb,
  activation jsonb,
  env text
)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel.eval(ast, activation, env, '{}'::jsonb);
$$;

COMMIT;
