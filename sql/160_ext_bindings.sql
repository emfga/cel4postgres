-- The bindings extension (cel-go ext/bindings.go at the pinned
-- v0.32.0): the cel.bind(var, init, expr) macro, expanding to the
-- bind-style comprehension (empty range, accumulator = the bound
-- variable). Registered under the 'bindings' env.

BEGIN;

CREATE OR REPLACE FUNCTION cel._mx_cel_bind(
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
  nm text;
  init jsonb;
  cond jsonb;
  step jsonb;
BEGIN
  next_id_out := next_id;
  -- Decline unless the receiver is the cel namespace.
  IF target ->> 'k' <> 'ident'
     OR ltrim(target ->> 'name', '.') <> 'cel' THEN
    RETURN;
  END IF;
  IF args -> 0 ->> 'k' <> 'ident' THEN
    err := 'cel.bind() variable names must be simple identifiers';
    RETURN;
  END IF;
  nm := args -> 0 ->> 'name';
  id := id + 1;
  init := jsonb_build_object('id', id, 'k', 'list',
    'elems', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'ident',
    'name', nm, 's', cs, 'e', ce);
  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', init, 'iter', '#unused', 'iter2', '',
    'accu', nm,
    'init', args -> 1, 'cond', cond, 'step', step,
    'result', args -> 2, 's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('bind', 3, true, 'cel._mx_cel_bind(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('bindings', 'macro', 'bind/3/1')
ON CONFLICT DO NOTHING;

COMMIT;
