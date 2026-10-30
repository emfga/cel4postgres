-- The encoders extension (cel-go ext/encoders.go at the pinned
-- v0.33.1): base64.encode / base64.decode, and from library version
-- 2 their URL-safe twins base64.encodeUrl / base64.decodeUrl.
-- Registered under the 'encoders' env.
--
-- Not implemented: json.encode (version 1) and json.parse,
-- yaml.encode, yaml.parse (version 2). docs/CONFORMANCE.md says why,
-- and conformance/library_test.go names them as known-missing.

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

-- The URL-safe alphabet (RFC 4648 section 5) swaps '+' and '/' for
-- '-' and '_'. Postgres decode() knows only the standard alphabet, so
-- translate in both directions; a standard-only character in the
-- input is invalid here, as it is in Go's URLEncoding. Like
-- base64.decode, padded and unpadded input are both accepted.
CREATE OR REPLACE FUNCTION cel._f_base64_decode_url(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
BEGIN
  IF s ~ '[+/]' THEN
    RAISE 'not base64url';
  END IF;
  s := translate(s, '-_', '+/');
  IF length(s) % 4 <> 0 THEN
    s := rpad(s, length(s) + 4 - length(s) % 4, '=');
  END IF;
  RETURN jsonb_build_object('@t', 'bytes', 'v',
    translate(encode(decode(s, 'base64'), 'base64'), E'\n', ''));
EXCEPTION WHEN OTHERS THEN
  RETURN cel._err(format('illegal base64 data in %s',
    quote_literal(args[1] ->> 'v')));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_base64_encode_url(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    translate(args[1] ->> 'v', '+/', '-_'));
$$;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('base64_decode_string', 'base64.decode', false,
   '[{"kind": "string"}]', '{"kind": "bytes"}',
   'cel._f_base64_decode(jsonb[])', 10),
  ('base64_encode_bytes', 'base64.encode', false,
   '[{"kind": "bytes"}]', '{"kind": "string"}',
   'cel._f_base64_encode(jsonb[])', 10),
  ('base64_decode_url_string', 'base64.decodeUrl', false,
   '[{"kind": "string"}]', '{"kind": "bytes"}',
   'cel._f_base64_decode_url(jsonb[])', 10),
  ('base64_encode_url_bytes', 'base64.encodeUrl', false,
   '[{"kind": "bytes"}]', '{"kind": "string"}',
   'cel._f_base64_encode_url(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('encoders', 'overload', 'base64_decode_string'),
  ('encoders', 'overload', 'base64_encode_bytes'),
  ('encoders', 'overload', 'base64_decode_url_string'),
  ('encoders', 'overload', 'base64_encode_url_bytes')
ON CONFLICT DO NOTHING;
