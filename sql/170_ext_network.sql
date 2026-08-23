-- The network extension (cel-go ext/network.go at the pinned
-- v0.32.0): net.IP / net.CIDR opaque types over Postgres inet
-- machinery, 21 overloads. Registered under the 'network' env.
--
-- Values store canonical text: net.IP as the canonical address
-- string, net.CIDR as '<canonical addr>/<bits>' with host bits
-- preserved (netip.Prefix keeps them; masked() is explicit).
-- Structural payload identity in cel._equal then matches cel-go's
-- equality.
--
-- Parsing is Go netip's strictness, which Postgres inet does not
-- share: no leading zeros in IPv4 octets, no partial addresses, no
-- zone suffixes, no IPv4-mapped IPv6, and a CIDR requires an
-- explicit /bits.

BEGIN;

-- Strict address parse. Returns the canonical text or NULL when the
-- input is not a valid address under netip.ParseAddr rules.
CREATE OR REPLACE FUNCTION cel._net_parse_ip(s text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v inet;
BEGIN
  IF s ~ '%' THEN
    RETURN NULL;  -- zones are not allowed
  END IF;
  IF position(':' IN s) = 0 THEN
    -- IPv4: exactly four octets, 0-255, no leading zeros.
    IF s !~ '^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$' THEN
      RETURN NULL;
    END IF;
    IF EXISTS (
      SELECT FROM unnest(string_to_array(s, '.')) o
      WHERE o::int > 255) THEN
      RETURN NULL;
    END IF;
    RETURN s;
  END IF;
  BEGIN
    v := s::inet;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
  IF family(v) <> 6 OR masklen(v) <> 128 THEN
    RETURN NULL;
  END IF;
  -- IPv4-mapped IPv6: the dotted text form is rejected, the hex
  -- form parses and unmaps to the IPv4 address (corpus
  -- network_ext/parse_invalid_ipv4_in_ipv6 vs ipv4_equals_ipv6 --
  -- cel-go v0.32.0 rejects both and does not run this file in its
  -- own conformance; the corpus is the authority).
  IF v <<= inet '::ffff:0.0.0.0/96' THEN
    IF position('.' IN s) > 0 THEN
      RETURN NULL;
    END IF;
    RETURN (regexp_match(host(v), '([^:]*)$'))[1];
  END IF;
  RETURN host(v);
END;
$$;

-- Strict prefix parse. Returns canonical '<addr>/<bits>' or NULL.
CREATE OR REPLACE FUNCTION cel._net_parse_cidr(s text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  addr text;
  bits text;
  a    text;
BEGIN
  IF s !~ '^[^/]+/[^/]+$' THEN
    RETURN NULL;
  END IF;
  addr := split_part(s, '/', 1);
  bits := split_part(s, '/', 2);
  a := cel._net_parse_ip(addr);
  IF a IS NULL THEN
    RETURN NULL;
  END IF;
  IF bits !~ '^(0|[1-9]\d{0,2})$' THEN
    RETURN NULL;
  END IF;
  IF position(':' IN a) > 0 THEN
    IF bits::int > 128 THEN
      RETURN NULL;
    END IF;
  ELSIF bits::int > 32 THEN
    RETURN NULL;
  END IF;
  RETURN a || '/' || bits::int;
END;
$$;

CREATE OR REPLACE FUNCTION cel._net_ip_val(t text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'net.IP',
    'v', t);
$$;

CREATE OR REPLACE FUNCTION cel._net_cidr_val(t text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'net.CIDR',
    'v', t);
$$;

CREATE OR REPLACE FUNCTION cel._f_net_string_to_ip(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_ip(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format(
      'IP Address %s parse error during conversion from string',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN cel._net_ip_val(a);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_string_to_cidr(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_cidr(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format(
      'CIDR %s parse error during conversion from string',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN cel._net_cidr_val(a);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_is_ip(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    cel._net_parse_ip(args[1] ->> 'v') IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_net_is_cidr(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    cel._net_parse_cidr(args[1] ->> 'v') IS NOT NULL);
$$;

-- isCanonical: parses and compares against the canonical rendering
-- (RFC 5952 for IPv6 -- Postgres inet output follows it).
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_canonical(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_ip(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format(
      'IP Address %s parse error during conversion from string',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN cel._bool_val(a = (args[1] ->> 'v'));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', args[1] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', args[1] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_family(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(family((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_ip(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._net_ip_val(host((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_masked(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._net_cidr_val(
    host(network((args[1] ->> 'v')::inet)) || '/'
    || masklen((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_prefix_length(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(masklen((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_is_mask(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    host((args[1] ->> 'v')::inet)
      = host(network((args[1] ->> 'v')::inet)));
$$;

-- Containment: families must match (netip returns false, never an
-- error, on family mismatch), then Postgres's network containment
-- compares the masked prefixes.
CREATE OR REPLACE FUNCTION cel._net_contains(
  parent inet, child inet, cidr_child boolean
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF family(parent) <> family(child) THEN
    RETURN false;
  END IF;
  IF cidr_child AND masklen(child) < masklen(parent) THEN
    RETURN false;
  END IF;
  RETURN network(child) <<= network(parent)
      OR network(child) = network(parent);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_contains_ip(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text;
BEGIN
  IF args[2] ->> '@t' = 'string' THEN
    a := cel._net_parse_ip(args[2] ->> 'v');
    IF a IS NULL THEN
      RETURN cel._err(format(
        'IP Address %s parse error during conversion from string',
        quote_literal(args[2] ->> 'v')));
    END IF;
  ELSE
    a := args[2] ->> 'v';
  END IF;
  RETURN cel._bool_val(cel._net_contains(
    (args[1] ->> 'v')::inet, a::inet, false));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_contains_cidr(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text;
BEGIN
  IF args[2] ->> '@t' = 'string' THEN
    a := cel._net_parse_cidr(args[2] ->> 'v');
    IF a IS NULL THEN
      RETURN cel._err(format(
        'CIDR %s parse error during conversion from string',
        quote_literal(args[2] ->> 'v')));
    END IF;
  ELSE
    a := args[2] ->> 'v';
  END IF;
  RETURN cel._bool_val(cel._net_contains(
    (args[1] ->> 'v')::inet, a::inet, true));
END;
$$;

-- Address classification (Go net/netip semantics).
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_loopback(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    CASE WHEN family((args[1] ->> 'v')::inet) = 4
      THEN (args[1] ->> 'v')::inet <<= inet '127.0.0.0/8'
      ELSE (args[1] ->> 'v')::inet = inet '::1'
    END);
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_is_unspecified(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    (args[1] ->> 'v')::inet = inet '0.0.0.0'
    OR (args[1] ->> 'v')::inet = inet '::');
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_is_ll_unicast(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    CASE WHEN family((args[1] ->> 'v')::inet) = 4
      THEN (args[1] ->> 'v')::inet <<= inet '169.254.0.0/16'
      ELSE (args[1] ->> 'v')::inet <<= inet 'fe80::/10'
    END);
$$;

-- Link-local multicast: 224.0.0.0/24, or IPv6 ffX2::/16 (first byte
-- 0xff, low nibble of the second byte 0x2 -- the flags nibble is
-- arbitrary, so mask with ff0f::).
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_ll_mcast(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    CASE WHEN family((args[1] ->> 'v')::inet) = 4
      THEN (args[1] ->> 'v')::inet <<= inet '224.0.0.0/24'
      ELSE ((args[1] ->> 'v')::inet & inet 'ff0f::')
             = inet 'ff02::'
    END);
$$;

-- Global unicast: everything except unspecified, loopback,
-- multicast, link-local unicast, and the IPv4 broadcast address.
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_global_ucast(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v inet := (args[1] ->> 'v')::inet;
BEGIN
  IF family(v) = 4 THEN
    RETURN cel._bool_val(NOT (
      v = inet '0.0.0.0'
      OR v = inet '255.255.255.255'
      OR v <<= inet '127.0.0.0/8'
      OR v <<= inet '169.254.0.0/16'
      OR v <<= inet '224.0.0.0/4'));
  END IF;
  RETURN cel._bool_val(NOT (
    v = inet '::'
    OR v = inet '::1'
    OR v <<= inet 'fe80::/10'
    OR v <<= inet 'ff00::/8'));
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.type (name, kind) VALUES
  ('net.IP', '{"kind": "opaque", "name": "net.IP"}'),
  ('net.CIDR', '{"kind": "opaque", "name": "net.CIDR"}')
ON CONFLICT (name) DO UPDATE SET kind = excluded.kind;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('string_to_ip', 'ip', false,
   '[{"kind": "string"}]',
   '{"kind": "opaque", "name": "net.IP"}',
   'cel._f_net_string_to_ip(jsonb[])', 10),
  ('cidr_ip', 'ip', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]',
   '{"kind": "opaque", "name": "net.IP"}',
   'cel._f_net_cidr_ip(jsonb[])', 20),
  ('string_to_cidr', 'cidr', false,
   '[{"kind": "string"}]',
   '{"kind": "opaque", "name": "net.CIDR"}',
   'cel._f_net_string_to_cidr(jsonb[])', 10),
  ('ip_to_string', 'string', false,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "string"}',
   'cel._f_net_ip_to_string(jsonb[])', 90),
  ('cidr_to_string', 'string', false,
   '[{"kind": "opaque", "name": "net.CIDR"}]', '{"kind": "string"}',
   'cel._f_net_cidr_to_string(jsonb[])', 100),
  ('ip_family', 'family', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "int"}',
   'cel._f_net_ip_family(jsonb[])', 10),
  ('ip_is_canonical', 'ip.isCanonical', false,
   '[{"kind": "string"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_canonical(jsonb[])', 10),
  ('is_ip', 'isIP', false,
   '[{"kind": "string"}]', '{"kind": "bool"}',
   'cel._f_net_is_ip(jsonb[])', 10),
  ('is_cidr', 'isCIDR', false,
   '[{"kind": "string"}]', '{"kind": "bool"}',
   'cel._f_net_is_cidr(jsonb[])', 10),
  ('cidr_contains_ip_ip', 'containsIP', true,
   '[{"kind": "opaque", "name": "net.CIDR"},
     {"kind": "opaque", "name": "net.IP"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_ip(jsonb[])', 10),
  ('cidr_contains_ip_string', 'containsIP', true,
   '[{"kind": "opaque", "name": "net.CIDR"}, {"kind": "string"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_ip(jsonb[])', 20),
  ('cidr_contains_cidr', 'containsCIDR', true,
   '[{"kind": "opaque", "name": "net.CIDR"},
     {"kind": "opaque", "name": "net.CIDR"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_cidr(jsonb[])', 10),
  ('cidr_contains_cidr_string', 'containsCIDR', true,
   '[{"kind": "opaque", "name": "net.CIDR"}, {"kind": "string"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_cidr(jsonb[])', 20),
  ('ip_is_loopback', 'isLoopback', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_loopback(jsonb[])', 10),
  ('ip_is_unspecified', 'isUnspecified', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_unspecified(jsonb[])', 10),
  ('ip_is_link_local_unicast', 'isLinkLocalUnicast', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_ll_unicast(jsonb[])', 10),
  ('ip_is_link_local_multicast', 'isLinkLocalMulticast', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_ll_mcast(jsonb[])', 10),
  ('ip_is_global_unicast', 'isGlobalUnicast', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_global_ucast(jsonb[])', 10),
  ('cidr_masked', 'masked', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]',
   '{"kind": "opaque", "name": "net.CIDR"}',
   'cel._f_net_cidr_masked(jsonb[])', 10),
  ('cidr_prefix_length', 'prefixLength', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]', '{"kind": "int"}',
   'cel._f_net_cidr_prefix_length(jsonb[])', 10),
  ('cidr_is_mask', 'isMask', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]', '{"kind": "bool"}',
   'cel._f_net_cidr_is_mask(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'network', 'overload', id FROM cel.overload
WHERE id IN (
  'string_to_ip', 'cidr_ip', 'string_to_cidr', 'ip_to_string',
  'cidr_to_string', 'ip_family', 'ip_is_canonical', 'is_ip',
  'is_cidr', 'cidr_contains_ip_ip', 'cidr_contains_ip_string',
  'cidr_contains_cidr', 'cidr_contains_cidr_string',
  'ip_is_loopback', 'ip_is_unspecified',
  'ip_is_link_local_unicast', 'ip_is_link_local_multicast',
  'ip_is_global_unicast', 'cidr_masked', 'cidr_prefix_length',
  'cidr_is_mask')
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('network', 'type', 'net.IP'),
  ('network', 'type', 'net.CIDR')
ON CONFLICT DO NOTHING;

COMMIT;
