-- The encoders extension (cel-go ext/encoders.go at the pinned
-- v0.32.0): base64.encode / base64.decode. Registered under the
-- 'encoders' env.

BEGIN;

-- Go accepts both padded and raw (unpadded) standard base64
-- (encoders.go:143-150); Postgres decode requires padding, so pad
-- first.
CREATE OR REPLACE FUNCTION cel._f_base64_decode(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
BEGIN
  IF length(s) % 4 <> 0 THEN
    s := rpad(s, length(s) + 4 - length(s) % 4, '=');
  END IF;
  RETURN jsonb_build_object('@t', 'bytes', 'v',
    translate(encode(decode(s, 'base64'), 'base64'),
      E'\n', ''));
EXCEPTION WHEN OTHERS THEN
  RETURN cel._err(format('illegal base64 data in %s',
    quote_literal(args[1] ->> 'v')));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_base64_encode(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    translate(encode(decode(args[1] ->> 'v', 'base64'), 'base64'),
      E'\n', ''));
$$;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('base64_decode_string', 'base64.decode', false,
   '[{"kind": "string"}]', '{"kind": "bytes"}',
   'cel._f_base64_decode(jsonb[])', 10),
  ('base64_encode_bytes', 'base64.encode', false,
   '[{"kind": "bytes"}]', '{"kind": "string"}',
   'cel._f_base64_encode(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('encoders', 'overload', 'base64_decode_string'),
  ('encoders', 'overload', 'base64_encode_bytes')
ON CONFLICT DO NOTHING;

COMMIT;
