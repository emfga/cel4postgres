-- The strings extension (cel-go ext/strings.go at the pinned
-- v0.32.0, latest library version): charAt, indexOf, lastIndexOf,
-- lowerAscii, upperAscii, replace, split, substring, trim, join,
-- reverse, strings.quote and string.format. Registered under the
-- 'strings' env.
--
-- All index arithmetic is in code points; Postgres text functions
-- are character-based under UTF8, which lines up. One deliberate
-- divergence from cel-go: indexOf/lastIndexOf with an out-of-range
-- offset error instead of returning -1 -- the corpus and cel-java
-- agree against cel-go v0.32.0 there.

BEGIN;

CREATE OR REPLACE FUNCTION cel._str_val(s text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', s);
$$;

CREATE OR REPLACE FUNCTION cel._f_char_at(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
  i numeric := (args[2] ->> 'v')::numeric;
BEGIN
  IF i < 0 OR i > length(s) THEN
    RETURN cel._err(format('index out of range: %s', i));
  END IF;
  RETURN cel._str_val(substr(s, i::int + 1, 1));
END;
$$;

-- Shared scan for indexOf / lastIndexOf. The empty-substring case
-- returns the clamped offset before the bounds check (matching both
-- cel-go and cel-java); a non-empty search with an out-of-range
-- offset errors (corpus + cel-java adjudication).
CREATE OR REPLACE FUNCTION cel._str_index(
  s text, sub text, off numeric, backwards boolean
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l  int := length(s);
  ls int := length(sub);
  i  int;
BEGIN
  IF off < 0 THEN
    RETURN cel._err(format('index out of range: %s', off));
  END IF;
  IF sub = '' THEN
    RETURN cel._int_val(least(off, l::numeric));
  END IF;
  IF off >= l THEN
    RETURN cel._err(format('index out of range: %s', off));
  END IF;
  IF backwards THEN
    i := least(off::int, l - ls);
    WHILE i >= 0 LOOP
      IF substr(s, i + 1, ls) = sub THEN
        RETURN cel._int_val(i);
      END IF;
      i := i - 1;
    END LOOP;
  ELSE
    i := off::int;
    WHILE i <= l - ls LOOP
      IF substr(s, i + 1, ls) = sub THEN
        RETURN cel._int_val(i);
      END IF;
      i := i + 1;
    END LOOP;
  END IF;
  RETURN cel._int_val(-1);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_index_of(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_index(args[1] ->> 'v', args[2] ->> 'v',
    CASE WHEN cardinality(args) > 2
         THEN (args[3] ->> 'v')::numeric ELSE 0 END,
    false);
$$;

CREATE OR REPLACE FUNCTION cel._f_last_index_of(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  sub text := args[2] ->> 'v';
BEGIN
  IF cardinality(args) > 2 THEN
    RETURN cel._str_index(s, sub, (args[3] ->> 'v')::numeric, true);
  END IF;
  -- The 2-argument form never errors: it searches from the end.
  IF sub = '' THEN
    RETURN cel._int_val(length(s));
  END IF;
  IF length(s) < length(sub) THEN
    RETURN cel._int_val(-1);
  END IF;
  RETURN cel._str_index(s, sub, (length(s) - 1)::numeric, true);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_lower_ascii(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(translate(args[1] ->> 'v',
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'));
$$;

CREATE OR REPLACE FUNCTION cel._f_upper_ascii(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(translate(args[1] ->> 'v',
    'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'));
$$;

-- Go strings.Replace semantics: n < 0 replaces all, n = 0 none.
CREATE OR REPLACE FUNCTION cel._f_replace(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  old text := args[2] ->> 'v';
  new text := args[3] ->> 'v';
  n   numeric := CASE WHEN cardinality(args) > 3
                      THEN (args[4] ->> 'v')::numeric ELSE -1 END;
  res text := '';
  p   int;
BEGIN
  IF n < 0 THEN
    IF old = '' THEN
      -- Go inserts new between every rune and at both ends.
      res := new;
      FOR p IN 1 .. length(s) LOOP
        res := res || substr(s, p, 1) || new;
      END LOOP;
      RETURN cel._str_val(res);
    END IF;
    RETURN cel._str_val(replace(s, old, new));
  END IF;
  WHILE n > 0 LOOP
    IF old = '' THEN
      res := res || new;
      IF s = '' THEN
        EXIT;
      END IF;
      res := res || substr(s, 1, 1);
      s := substr(s, 2);
    ELSE
      p := strpos(s, old);
      EXIT WHEN p = 0;
      res := res || substr(s, 1, p - 1) || new;
      s := substr(s, p + length(old));
    END IF;
    n := n - 1;
  END LOOP;
  RETURN cel._str_val(res || s);
END;
$$;

-- Go strings.SplitN semantics, in code points; sep = '' splits into
-- characters.
CREATE OR REPLACE FUNCTION cel._f_split(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  sep text := args[2] ->> 'v';
  n   numeric := CASE WHEN cardinality(args) > 2
                      THEN (args[3] ->> 'v')::numeric ELSE -1 END;
  parts jsonb := '[]'::jsonb;
  p   int;
  cnt int := 0;
BEGIN
  IF n = 0 THEN
    RETURN jsonb_build_object('@t', 'list', 'v', '[]'::jsonb);
  END IF;
  IF sep = '' THEN
    FOR p IN 1 .. length(s) LOOP
      EXIT WHEN n > 0 AND cnt = n - 1;
      parts := parts || jsonb_build_array(
        cel._str_val(substr(s, p, 1)));
      cnt := cnt + 1;
    END LOOP;
    IF n > 0 AND length(s) > cnt THEN
      parts := parts || jsonb_build_array(
        cel._str_val(substr(s, cnt + 1)));
    END IF;
    RETURN jsonb_build_object('@t', 'list', 'v', parts);
  END IF;
  LOOP
    EXIT WHEN n > 0 AND cnt = n - 1;
    p := strpos(s, sep);
    EXIT WHEN p = 0;
    parts := parts || jsonb_build_array(
      cel._str_val(substr(s, 1, p - 1)));
    s := substr(s, p + length(sep));
    cnt := cnt + 1;
  END LOOP;
  parts := parts || jsonb_build_array(cel._str_val(s));
  RETURN jsonb_build_object('@t', 'list', 'v', parts);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_substring(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
  a numeric := (args[2] ->> 'v')::numeric;
  b numeric;
  l int := length(s);
BEGIN
  IF cardinality(args) = 2 THEN
    IF a < 0 OR a > l THEN
      RETURN cel._err(format('index out of range: %s', a));
    END IF;
    RETURN cel._str_val(substr(s, a::int + 1));
  END IF;
  b := (args[3] ->> 'v')::numeric;
  IF a > b THEN
    RETURN cel._err(format(
      'invalid substring range. start: %s, end: %s', a, b));
  END IF;
  IF a < 0 OR a > l THEN
    RETURN cel._err(format('index out of range: %s', a));
  END IF;
  IF b < 0 OR b > l THEN
    RETURN cel._err(format('index out of range: %s', b));
  END IF;
  RETURN cel._str_val(substr(s, a::int + 1, (b - a)::int));
END;
$$;

-- Go strings.TrimSpace: the Unicode white-space set.
CREATE OR REPLACE FUNCTION cel._f_trim(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(btrim(args[1] ->> 'v',
    E' \t\n\f\r' || chr(11) || chr(133) || chr(160) || chr(5760)
    || chr(8192) || chr(8193) || chr(8194) || chr(8195)
    || chr(8196) || chr(8197) || chr(8198) || chr(8199)
    || chr(8200) || chr(8201) || chr(8202) || chr(8232)
    || chr(8233) || chr(8239) || chr(8287) || chr(12288)));
$$;

CREATE OR REPLACE FUNCTION cel._f_str_reverse(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(reverse(args[1] ->> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_join(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sep text := CASE WHEN cardinality(args) > 1
                   THEN args[2] ->> 'v' ELSE '' END;
  res text := '';
  i   int;
  e   jsonb;
BEGIN
  FOR i IN 0 .. jsonb_array_length(args[1] -> 'v') - 1 LOOP
    e := args[1] -> 'v' -> i;
    IF e ->> '@t' <> 'string' THEN
      RETURN cel._err(format('join: invalid input: %s', e ->> 'v'));
    END IF;
    IF i > 0 THEN
      res := res || sep;
    END IF;
    res := res || (e ->> 'v');
  END LOOP;
  RETURN cel._str_val(res);
END;
$$;

-- strings.quote: CEL escape sequences, double-quoted.
CREATE OR REPLACE FUNCTION cel._f_quote(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  res text := '';
  c   text;
  i   int;
BEGIN
  FOR i IN 1 .. length(s) LOOP
    c := substr(s, i, 1);
    res := res || CASE c
      WHEN chr(7)  THEN '\a'
      WHEN chr(8)  THEN '\b'
      WHEN chr(12) THEN '\f'
      WHEN chr(10) THEN '\n'
      WHEN chr(13) THEN '\r'
      WHEN chr(9)  THEN '\t'
      WHEN chr(11) THEN '\v'
      WHEN '\'     THEN '\\'
      WHEN '"'     THEN '\"'
      ELSE c
    END;
  END LOOP;
  RETURN cel._str_val('"' || res || '"');
END;
$$;

COMMIT;

BEGIN;

-- string.format ------------------------------------------------------

-- Round-half-even of an exact numeric at scale p, returned as a
-- numeric of exactly scale p (multiplication by the exact decimal
-- 1e-p preserves exactness; numeric division would not).
CREATE OR REPLACE FUNCTION cel._fmt_round_even(x numeric, p int)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a numeric := abs(x) * (10::numeric ^ p);
  i numeric := trunc(a);
  f numeric := a - i;
BEGIN
  IF f > 0.5 OR (f = 0.5 AND mod(i, 2) = 1) THEN
    i := i + 1;
  END IF;
  RETURN sign(x) * i * ('1e-' || p)::numeric;
END;
$$;

-- The %s formatter (formatting_v2.go formatStringV2): recursive over
-- lists and maps, map entries sorted by their formatted key.
CREATE OR REPLACE FUNCTION cel._fmt_s(v jsonb, OUT o text, OUT err text)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := v ->> '@t';
  i int;
  r record;
  parts text[];
  ents  text[];
  kv    record;
BEGIN
  CASE k
    WHEN 'string' THEN o := v ->> 'v';
    WHEN 'bool' THEN o := CASE WHEN (v ->> 'v')::boolean
                              THEN 'true' ELSE 'false' END;
    WHEN 'int', 'uint' THEN o := v ->> 'v';
    WHEN 'double' THEN
      o := CASE v ->> 'v'
        WHEN 'NaN' THEN 'NaN'
        WHEN 'Infinity' THEN 'Infinity'
        WHEN '-Infinity' THEN '-Infinity'
        ELSE cel._sci_to_plain(
          cel._double_text((v ->> 'v')::float8))
      END;
    WHEN 'bytes' THEN
      o := convert_from(decode(v ->> 'v', 'base64'), 'UTF8');
    WHEN 'null' THEN o := 'null';
    WHEN 'type' THEN o := v ->> 'v';
    WHEN 'duration' THEN
      o := cel._f_duration_to_string(ARRAY[v]) ->> 'v';
    WHEN 'timestamp' THEN
      -- Formatting renders in UTC regardless of the value's offset.
      o := cel._f_timestamp_to_string(ARRAY[
        jsonb_set(v, '{v,tz}', '0'::jsonb)]) ->> 'v';
    WHEN 'list' THEN
      parts := '{}';
      FOR i IN 0 .. jsonb_array_length(v -> 'v') - 1 LOOP
        SELECT * INTO r FROM cel._fmt_s(v -> 'v' -> i);
        IF r.err IS NOT NULL THEN
          err := r.err;
          RETURN;
        END IF;
        parts := parts || r.o;
      END LOOP;
      o := '[' || array_to_string(parts, ', ') || ']';
    WHEN 'map' THEN
      ents := '{}';
      FOR i IN 0 .. jsonb_array_length(v -> 'v') - 1 LOOP
        SELECT * INTO r FROM cel._fmt_s(v -> 'v' -> i -> 'k');
        IF r.err IS NOT NULL THEN
          err := r.err;
          RETURN;
        END IF;
        ents := ents || (r.o || chr(1));
        SELECT * INTO r FROM cel._fmt_s(v -> 'v' -> i -> 'v');
        IF r.err IS NOT NULL THEN
          err := r.err;
          RETURN;
        END IF;
        ents[cardinality(ents)] := ents[cardinality(ents)] || r.o;
      END LOOP;
      SELECT array_agg(e ORDER BY split_part(e, chr(1), 1)
                                  COLLATE "C")
      INTO ents FROM unnest(ents) e;
      o := '{' || coalesce((
        SELECT string_agg(replace(e, chr(1), ': '), ', ')
        FROM unnest(ents) e), '') || '}';
    ELSE
      err := format('string clause can only be used on strings, '
        || 'bools, bytes, ints, doubles, maps, lists, types, '
        || 'durations, and timestamps, was given %s',
        CASE WHEN k = 'opaque' THEN v ->> 'type' ELSE k END);
  END CASE;
END;
$$;

-- Integer rendering in bases 2, 8 and 16 (sign + digits of the
-- absolute value, matching Go strconv.FormatInt).
CREATE OR REPLACE FUNCTION cel._fmt_base(n numeric, b int, up boolean)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a numeric := abs(n);
  digits text := '0123456789abcdef';
  o text := '';
  d int;
BEGIN
  IF a = 0 THEN
    o := '0';
  END IF;
  WHILE a > 0 LOOP
    d := mod(a, b)::int;
    o := substr(digits, d + 1, 1) || o;
    a := div(a, b);
  END LOOP;
  IF up THEN
    o := upper(o);
  END IF;
  RETURN CASE WHEN n < 0 THEN '-' || o ELSE o END;
END;
$$;

-- Fixed-point (%f) and scientific (%e) rendering over the exact
-- decimal expansion of the double (cel._f2n), rounded half-even the
-- way Go's correctly-rounded formatter behaves.
CREATE OR REPLACE FUNCTION cel._fmt_fixed(f float8, p int)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r numeric := cel._fmt_round_even(cel._f2n(f), p);
  neg boolean := f < 0 OR (f = 0 AND f::text = '-0');
BEGIN
  RETURN CASE WHEN neg AND r >= 0 THEN '-' ELSE '' END || r::text;
END;
$$;

CREATE OR REPLACE FUNCTION cel._fmt_sci(f float8, p int)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  m numeric := cel._f2n(f);
  e int := 0;
  am numeric;
  es text;
BEGIN
  am := abs(m);
  IF am <> 0 THEN
    WHILE am >= 10 LOOP
      am := am * 0.1;
      e := e + 1;
    END LOOP;
    WHILE am < 1 LOOP
      am := am * 10;
      e := e - 1;
    END LOOP;
  END IF;
  am := cel._fmt_round_even(am, p);
  IF am >= 10 THEN
    am := am * 0.1;
    e := e + 1;
    am := cel._fmt_round_even(am, p);
  END IF;
  es := lpad(abs(e)::text, 2, '0');
  RETURN CASE WHEN m < 0 OR (f = 0 AND f::text = '-0')
              THEN '-' ELSE '' END
      || am::text || 'e'
      || CASE WHEN e < 0 THEN '-' ELSE '+' END || es;
END;
$$;

-- One formatting clause applied to one argument. kinds follow
-- formatting_v2.go's per-clause type admission exactly.
CREATE OR REPLACE FUNCTION cel._fmt_clause(
  c text, p int, v jsonb, OUT o text, OUT err text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := v ->> '@t';
  r record;
  tn text := CASE k
    WHEN 'opaque' THEN v ->> 'type'
    WHEN 'timestamp' THEN 'google.protobuf.Timestamp'
    WHEN 'duration' THEN 'google.protobuf.Duration'
    ELSE k END;
BEGIN
  CASE c
    WHEN 's' THEN
      SELECT * INTO r FROM cel._fmt_s(v);
      o := r.o;
      err := r.err;
    WHEN 'd' THEN
      IF k IN ('int', 'uint') THEN
        o := v ->> 'v';
      ELSIF k = 'double'
            AND v ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
        o := v ->> 'v';
      ELSE
        err := format('decimal clause can only be used on '
          || 'integers, was given %s', tn);
      END IF;
    WHEN 'f' THEN
      IF k IN ('int', 'uint', 'double') THEN
        IF k = 'double'
           AND v ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
          o := v ->> 'v';
        ELSE
          o := cel._fmt_fixed((v ->> 'v')::float8, p);
        END IF;
      ELSE
        err := format('fixed-point clause can only be used on '
          || 'numeric types, was given %s', tn);
      END IF;
    WHEN 'e' THEN
      IF k IN ('int', 'uint', 'double') THEN
        IF k = 'double'
           AND v ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
          o := v ->> 'v';
        ELSE
          o := cel._fmt_sci((v ->> 'v')::float8, p);
        END IF;
      ELSE
        err := format('scientific clause can only be used on '
          || 'numeric types, was given %s', tn);
      END IF;
    WHEN 'b' THEN
      IF k IN ('int', 'uint') THEN
        o := cel._fmt_base((v ->> 'v')::numeric, 2, false);
      ELSIF k = 'bool' THEN
        o := CASE WHEN (v ->> 'v')::boolean THEN '1' ELSE '0' END;
      ELSE
        err := format('only integers and bools can be formatted '
          || 'as binary, was given %s', tn);
      END IF;
    WHEN 'x', 'X' THEN
      IF k IN ('int', 'uint') THEN
        o := cel._fmt_base((v ->> 'v')::numeric, 16, c = 'X');
      ELSIF k = 'string' THEN
        o := encode(convert_to(v ->> 'v', 'UTF8'), 'hex');
        IF c = 'X' THEN o := upper(o); END IF;
      ELSIF k = 'bytes' THEN
        o := encode(decode(v ->> 'v', 'base64'), 'hex');
        IF c = 'X' THEN o := upper(o); END IF;
      ELSE
        err := format('only integers, byte buffers, and strings '
          || 'can be formatted as hex, was given %s', tn);
      END IF;
    WHEN 'o' THEN
      IF k IN ('int', 'uint') THEN
        o := cel._fmt_base((v ->> 'v')::numeric, 8, false);
      ELSE
        err := format('octal clause can only be used on integers, '
          || 'was given %s', tn);
      END IF;
    ELSE
      err := NULL;  -- unreachable; clauses validated by the caller
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_format(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s    text := args[1] ->> 'v';
  lst  jsonb := args[2] -> 'v';
  n    int := jsonb_array_length(lst);
  res  text := '';
  i    int := 1;
  ai   int := 0;
  l    int := length(s);
  c    text;
  p    int;
  ptxt text;
  r    record;
BEGIN
  WHILE i <= l LOOP
    c := substr(s, i, 1);
    IF c <> '%' THEN
      res := res || c;
      i := i + 1;
      CONTINUE;
    END IF;
    IF substr(s, i + 1, 1) = '%' THEN
      res := res || '%';
      i := i + 2;
      CONTINUE;
    END IF;
    IF i = l THEN
      RETURN cel._err('unexpected end of string');
    END IF;
    -- precision
    i := i + 1;
    p := 6;
    IF substr(s, i, 1) = '.' THEN
      i := i + 1;
      ptxt := '';
      WHILE i <= l AND substr(s, i, 1) BETWEEN '0' AND '9' LOOP
        ptxt := ptxt || substr(s, i, 1);
        i := i + 1;
      END LOOP;
      IF i > l THEN
        RETURN cel._err('could not parse formatting clause: '
          || 'could not find end of precision specifier');
      END IF;
      IF ptxt = '' THEN
        RETURN cel._err('could not parse formatting clause: error '
          || 'while converting precision to integer');
      END IF;
      p := ptxt::int;
    END IF;
    c := substr(s, i, 1);
    i := i + 1;
    IF c NOT IN ('s', 'd', 'f', 'e', 'b', 'x', 'X', 'o') THEN
      RETURN cel._err(format('could not parse formatting clause: '
        || 'unrecognized formatting clause "%s"', c));
    END IF;
    IF ai >= n THEN
      RETURN cel._err(format('index %s out of range', ai));
    END IF;
    SELECT * INTO r FROM cel._fmt_clause(c, p, lst -> ai);
    IF r.err IS NOT NULL THEN
      RETURN cel._err('error during formatting: ' || r.err);
    END IF;
    res := res || r.o;
    ai := ai + 1;
  END LOOP;
  RETURN cel._str_val(res);
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('string_char_at_int', 'charAt', true,
   '[{"kind": "string"}, {"kind": "int"}]', '{"kind": "string"}',
   'cel._f_char_at(jsonb[])', 10),
  ('string_index_of_string', 'indexOf', true,
   '[{"kind": "string"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_index_of(jsonb[])', 10),
  ('string_index_of_string_int', 'indexOf', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "int"}]',
   '{"kind": "int"}', 'cel._f_index_of(jsonb[])', 20),
  ('string_last_index_of_string', 'lastIndexOf', true,
   '[{"kind": "string"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_last_index_of(jsonb[])', 10),
  ('string_last_index_of_string_int', 'lastIndexOf', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "int"}]',
   '{"kind": "int"}', 'cel._f_last_index_of(jsonb[])', 20),
  ('string_lower_ascii', 'lowerAscii', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_lower_ascii(jsonb[])', 10),
  ('string_upper_ascii', 'upperAscii', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_upper_ascii(jsonb[])', 10),
  ('string_replace_string_string', 'replace', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "string"}]',
   '{"kind": "string"}', 'cel._f_replace(jsonb[])', 10),
  ('string_replace_string_string_int', 'replace', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "string"},
     {"kind": "int"}]',
   '{"kind": "string"}', 'cel._f_replace(jsonb[])', 20),
  ('string_split_string', 'split', true,
   '[{"kind": "string"}, {"kind": "string"}]',
   '{"kind": "list", "params": [{"kind": "string"}]}',
   'cel._f_split(jsonb[])', 10),
  ('string_split_string_int', 'split', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "string"}]}',
   'cel._f_split(jsonb[])', 20),
  ('string_substring_int', 'substring', true,
   '[{"kind": "string"}, {"kind": "int"}]', '{"kind": "string"}',
   'cel._f_substring(jsonb[])', 10),
  ('string_substring_int_int', 'substring', true,
   '[{"kind": "string"}, {"kind": "int"}, {"kind": "int"}]',
   '{"kind": "string"}', 'cel._f_substring(jsonb[])', 20),
  ('string_trim', 'trim', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_trim(jsonb[])', 10),
  ('string_reverse', 'reverse', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_str_reverse(jsonb[])', 10),
  ('list_join', 'join', true,
   '[{"kind": "list", "params": [{"kind": "string"}]}]',
   '{"kind": "string"}', 'cel._f_join(jsonb[])', 10),
  ('list_join_string', 'join', true,
   '[{"kind": "list", "params": [{"kind": "string"}]},
     {"kind": "string"}]',
   '{"kind": "string"}', 'cel._f_join(jsonb[])', 20),
  ('strings_quote', 'strings.quote', false,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_quote(jsonb[])', 10),
  ('string_format', 'format', true,
   '[{"kind": "string"},
     {"kind": "list", "params": [{"kind": "dyn"}]}]',
   '{"kind": "string"}', 'cel._f_format(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'strings', 'overload', id FROM cel.overload
WHERE id IN (
  'string_char_at_int', 'string_index_of_string',
  'string_index_of_string_int', 'string_last_index_of_string',
  'string_last_index_of_string_int', 'string_lower_ascii',
  'string_upper_ascii', 'string_replace_string_string',
  'string_replace_string_string_int', 'string_split_string',
  'string_split_string_int', 'string_substring_int',
  'string_substring_int_int', 'string_trim', 'string_reverse',
  'list_join', 'list_join_string', 'strings_quote',
  'string_format')
ON CONFLICT DO NOTHING;

COMMIT;
