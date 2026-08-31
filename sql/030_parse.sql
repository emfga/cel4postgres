-- cel4postgres -- lexer, parser, macro engine.
--
-- Hand-written lexer + precedence-climbing parser (cel-go itself
-- carries a Pratt parser with these semantics). Errors travel as
-- OUT parameters, never exceptions: cel.parse is labelled
-- PARALLEL SAFE, and a BEGIN/EXCEPTION block's subtransaction would
-- break that promise inside a parallel worker.
--
-- The reference grammar is cel-go's parser/gen/CEL.g4 (v0.32.0);
-- lexical rules follow it exactly, including the newline
-- normalization applied to every literal form.

BEGIN;

-- Lexes one string or bytes literal. pos points at the opening quote
-- (prefixes r/R/b/B already consumed by the caller). Returns the
-- decoded value: text for strings, base64 text for bytes. ni is the
-- position after the closing quote. err set on failure.
CREATE OR REPLACE FUNCTION cel._lex_string(
  source text,
  pos int,
  raw boolean,
  is_bytes boolean,
  OUT val text,
  OUT ni int,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n      int := length(source);
  q      text := substr(source, pos, 1);
  triple boolean := substr(source, pos, 3) = repeat(q, 3);
  i      int;
  ch     text;
  sacc   text := '';
  bacc   bytea := ''::bytea;
  code   int;
  hex    text;
  esc    text;
  width  int;
BEGIN
  i := pos + CASE WHEN triple THEN 3 ELSE 1 END;

  LOOP
    IF i > n THEN
      err := 'unterminated string';
      ni := i;
      RETURN;
    END IF;
    ch := substr(source, i, 1);

    -- Closing quote.
    IF triple THEN
      IF substr(source, i, 3) = repeat(q, 3) THEN
        i := i + 3;
        EXIT;
      END IF;
    ELSIF ch = q THEN
      i := i + 1;
      EXIT;
    ELSIF ch = E'\n' OR ch = E'\r' THEN
      err := 'unterminated string';
      ni := i;
      RETURN;
    END IF;

    -- Raw literals keep backslashes verbatim.
    IF ch <> E'\\' OR raw THEN
      -- Newline normalization applies to literal source text in
      -- every form (raw included): CRLF and CR become LF. Escape-
      -- produced \r (code 13) is not source text and stays.
      IF ch = E'\r' THEN
        ch := E'\n';
        IF substr(source, i + 1, 1) = E'\n' THEN
          i := i + 1;
        END IF;
      END IF;
      IF is_bytes THEN
        bacc := bacc || convert_to(ch, 'UTF8');
      ELSE
        sacc := sacc || ch;
      END IF;
      i := i + 1;
      CONTINUE;
    END IF;

    -- Escape sequence.
    i := i + 1;
    IF i > n THEN
      err := 'unterminated escape';
      ni := i;
      RETURN;
    END IF;
    esc := substr(source, i, 1);

    IF esc IN ('a','b','f','n','r','t','v','\','''','"','?','`') THEN
      code := CASE esc
        WHEN 'a' THEN 7  WHEN 'b' THEN 8  WHEN 'f' THEN 12
        WHEN 'n' THEN 10 WHEN 'r' THEN 13 WHEN 't' THEN 9
        WHEN 'v' THEN 11
        ELSE ascii(esc)
      END;
      i := i + 1;
    ELSIF esc IN ('x', 'X') THEN
      hex := substr(source, i + 1, 2);
      IF hex !~ '^[0-9a-fA-F]{2}$' THEN
        err := 'invalid escape sequence \x';
        ni := i;
        RETURN;
      END IF;
      code := ('x' || hex)::bit(8)::int;
      i := i + 3;
    ELSIF esc IN ('u', 'U') THEN
      IF is_bytes THEN
        err := format(
          'invalid escape sequence \%s in bytes literal', esc);
        ni := i;
        RETURN;
      END IF;
      width := CASE WHEN esc = 'u' THEN 4 ELSE 8 END;
      hex := substr(source, i + 1, width);
      IF hex !~ ('^[0-9a-fA-F]{' || width || '}$') THEN
        err := format('invalid escape sequence \%s', esc);
        ni := i;
        RETURN;
      END IF;
      code := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
      i := i + 1 + width;
    ELSIF esc ~ '^[0-3]$' THEN
      hex := substr(source, i, 3);
      IF hex !~ '^[0-3][0-7][0-7]$' THEN
        err := 'invalid octal escape sequence';
        ni := i;
        RETURN;
      END IF;
      code := (substr(hex, 1, 1)::int * 64)
        + (substr(hex, 2, 1)::int * 8)
        + substr(hex, 3, 1)::int;
      i := i + 3;
    ELSE
      err := format('invalid escape sequence \%s', esc);
      ni := i;
      RETURN;
    END IF;

    IF is_bytes THEN
      IF code > 255 THEN
        err := 'byte escape out of range';
        ni := i;
        RETURN;
      END IF;
      bacc := bacc || decode(lpad(to_hex(code), 2, '0'), 'hex');
    ELSE
      IF code = 0 THEN
        -- PostgreSQL text cannot carry NUL; the conformance cases
        -- that need it are skipped by name. Still a clean error.
        err := 'NUL code point not representable in PostgreSQL text';
        ni := i;
        RETURN;
      ELSIF code < 0 OR code > 1114111
            OR (code >= 55296 AND code <= 57343) THEN
        err := 'invalid unicode code point';
        ni := i;
        RETURN;
      END IF;
      sacc := sacc || chr(code);
    END IF;
  END LOOP;

  ni := i;
  IF is_bytes THEN
    val := replace(encode(bacc, 'base64'), E'\n', '');
  ELSE
    val := sacc;
  END IF;
END;
$$;

-- Lexes one numeric literal starting at pos (a digit, or '.' followed
-- by a digit). Emits t = 'int' | 'uint' | 'float' with the raw text
-- as v (uint without its u suffix, hex kept as 0x...); the parser
-- converts to a value so that a preceding '-' can fold in first.
CREATE OR REPLACE FUNCTION cel._lex_number(
  source text,
  pos int,
  OUT t text,
  OUT v text,
  OUT ni int,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  rest text := substr(source, pos);
  m    text;
BEGIN
  -- Hex integer.
  m := (regexp_match(rest, '^0[xX][0-9a-fA-F]+'))[1];
  IF m IS NOT NULL THEN
    IF substr(rest, length(m) + 1, 1) IN ('u', 'U') THEN
      t := 'uint';
      v := m;
      ni := pos + length(m) + 1;
    ELSE
      t := 'int';
      v := m;
      ni := pos + length(m);
    END IF;
    RETURN;
  END IF;

  -- Float: d+.d+[exp] | d+exp | .d+[exp]
  m := (regexp_match(rest,
    '^(\d+\.\d+([eE][+-]?\d+)?|\d+[eE][+-]?\d+|\.\d+([eE][+-]?\d+)?)'
  ))[1];
  IF m IS NOT NULL THEN
    t := 'float';
    v := m;
    ni := pos + length(m);
    RETURN;
  END IF;

  -- Decimal integer.
  m := (regexp_match(rest, '^\d+'))[1];
  IF m IS NULL THEN
    err := 'invalid numeric literal';
    ni := pos;
    RETURN;
  END IF;
  IF substr(rest, length(m) + 1, 1) IN ('u', 'U') THEN
    t := 'uint';
    v := m;
    ni := pos + length(m) + 1;
  ELSE
    t := 'int';
    v := m;
    ni := pos + length(m);
  END IF;
END;
$$;

-- Lexes a whole expression into a flat token array:
--   {"t": <type>, "v": <value>, "s": <start>, "e": <end>}
-- with 0-based code-point offsets and a final {"t": "eof"} token.
-- Token types: operator/punctuation text ('&&', '(', ...), 'ident',
-- 'esc_ident', 'int', 'uint', 'float', 'string', 'bytes', 'bool',
-- 'null', 'in', 'reserved', 'eof'.
CREATE OR REPLACE FUNCTION cel._lex(
  source text,
  flags jsonb,
  OUT toks jsonb,
  OUT err text,
  OUT errpos int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n        int := length(source);
  i        int := 1;
  ch       text;
  two      text;
  start    int;
  m        text;
  raw      boolean;
  is_bytes boolean;
  qpos     int;
  s        record;
  acc      jsonb[] := '{}';
BEGIN
  WHILE i <= n LOOP
    ch := substr(source, i, 1);

    -- Whitespace.
    IF ch IN (' ', E'\t', E'\r', E'\n', E'\f', E'\v') THEN
      i := i + 1;
      CONTINUE;
    END IF;

    -- Comment to end of line.
    IF ch = '/' AND substr(source, i + 1, 1) = '/' THEN
      WHILE i <= n AND substr(source, i, 1) <> E'\n' LOOP
        i := i + 1;
      END LOOP;
      CONTINUE;
    END IF;

    start := i;

    -- Two-character operators.
    two := substr(source, i, 2);
    IF two IN ('&&', '||', '<=', '>=', '==', '!=') THEN
      acc := acc || jsonb_build_object(
        't', two, 's', start - 1, 'e', start + 1);
      i := i + 2;
      CONTINUE;
    END IF;

    -- Number (before '.'-punctuation: '.5' is a float).
    IF ch BETWEEN '0' AND '9'
       OR (ch = '.' AND substr(source, i + 1, 1) BETWEEN '0' AND '9')
    THEN
      SELECT * INTO s FROM cel._lex_number(source, i);
      IF s.err IS NOT NULL THEN
        err := s.err;
        errpos := s.ni - 1;
        RETURN;
      END IF;
      acc := acc || jsonb_build_object(
        't', s.t, 'v', s.v, 's', start - 1, 'e', s.ni - 1);
      i := s.ni;
      CONTINUE;
    END IF;

    -- Single-character operators and punctuation.
    IF ch IN ('(', ')', '[', ']', '{', '}', ',', '.', ':', '?',
              '+', '-', '*', '/', '%', '!', '<', '>', '=')
    THEN
      acc := acc || jsonb_build_object(
        't', ch, 's', start - 1, 'e', start);
      i := i + 1;
      CONTINUE;
    END IF;

    -- String and bytes literals, with r/R/b/B prefixes. Per the
    -- grammar, bytes is (b|B) followed by a string, whose own raw
    -- prefix comes second: br'' is valid, rb'' is not.
    raw := false;
    is_bytes := false;
    qpos := i;
    IF ch IN ('b', 'B') THEN
      IF substr(source, i + 1, 1) IN ('r', 'R')
         AND substr(source, i + 2, 1) IN ('''', '"') THEN
        is_bytes := true;
        raw := true;
        qpos := i + 2;
      ELSIF substr(source, i + 1, 1) IN ('''', '"') THEN
        is_bytes := true;
        qpos := i + 1;
      END IF;
    ELSIF ch IN ('r', 'R') THEN
      IF substr(source, i + 1, 1) IN ('''', '"') THEN
        raw := true;
        qpos := i + 1;
      END IF;
    END IF;

    IF ch IN ('''', '"') OR qpos > i THEN
      SELECT * INTO s
      FROM cel._lex_string(source, qpos, raw, is_bytes);
      IF s.err IS NOT NULL THEN
        err := s.err;
        errpos := s.ni - 1;
        RETURN;
      END IF;
      acc := acc || jsonb_build_object(
        't', CASE WHEN is_bytes THEN 'bytes' ELSE 'string' END,
        'v', s.val, 's', start - 1, 'e', s.ni - 1);
      i := s.ni;
      CONTINUE;
    END IF;

    -- Escaped identifier `a-b.c/d ` -- letters, digits, and _.-/
    -- plus space; valid only where the parser allows it, and only
    -- when the env enables the syntax.
    IF ch = '`' THEN
      IF NOT coalesce((flags ->> 'ident_escape')::boolean, false) THEN
        err := 'unsupported syntax: ''`''';
        errpos := start - 1;
        RETURN;
      END IF;
      m := (regexp_match(substr(source, i), '^`([A-Za-z0-9_./\- ]*)`'))[1];
      IF m IS NULL OR m = '' THEN
        err := 'invalid escaped identifier';
        errpos := start - 1;
        RETURN;
      END IF;
      acc := acc || jsonb_build_object(
        't', 'esc_ident', 'v', m,
        's', start - 1, 'e', start + length(m) + 1);
      i := i + length(m) + 2;
      CONTINUE;
    END IF;

    -- Identifier, keyword literal, 'in', or reserved word.
    IF ch = '_' OR (ch >= 'a' AND ch <= 'z') OR (ch >= 'A' AND ch <= 'Z')
    THEN
      m := (regexp_match(substr(source, i), '^[A-Za-z_][A-Za-z0-9_]*'))[1];
      IF m = 'true' OR m = 'false' THEN
        acc := acc || jsonb_build_object(
          't', 'bool', 'v', m = 'true',
          's', start - 1, 'e', start - 1 + length(m));
      ELSIF m = 'null' THEN
        acc := acc || jsonb_build_object(
          't', 'null', 's', start - 1, 'e', start - 1 + length(m));
      ELSIF m = 'in' THEN
        acc := acc || jsonb_build_object(
          't', 'in', 's', start - 1, 'e', start - 1 + length(m));
      ELSIF m IN ('as', 'break', 'const', 'continue', 'else', 'for',
                  'function', 'if', 'import', 'let', 'loop', 'package',
                  'namespace', 'return', 'var', 'void', 'while')
      THEN
        acc := acc || jsonb_build_object(
          't', 'reserved', 'v', m,
          's', start - 1, 'e', start - 1 + length(m));
      ELSE
        acc := acc || jsonb_build_object(
          't', 'ident', 'v', m,
          's', start - 1, 'e', start - 1 + length(m));
      END IF;
      i := i + length(m);
      CONTINUE;
    END IF;

    err := format('unexpected character %s', quote_literal(ch));
    errpos := start - 1;
    RETURN;
  END LOOP;

  acc := acc || jsonb_build_object('t', 'eof', 's', n, 'e', n);
  toks := to_jsonb(acc);
END;
$$;

COMMIT;

BEGIN;

-- Line/column (both 0-based line, 0-based col) for an offset, for
-- parse error reporting. Conformance never string-matches parse
-- errors; this exists for humans.
CREATE OR REPLACE FUNCTION cel._line_col(
  source text, off int, OUT line int, OUT col int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  before text := substr(source, 1, off);
  last_nl int;
BEGIN
  line := length(before) - length(replace(before, E'\n', ''));
  last_nl := length(before)
    - position(E'\n' IN reverse(before)) + 1;
  IF position(E'\n' IN before) = 0 THEN
    col := off;
  ELSE
    col := off - last_nl;
  END IF;
END;
$$;

-- The parse-failure envelope: {"errors": [{"msg","line","col"}]}.
CREATE OR REPLACE FUNCTION cel._parse_errors(
  source text, msg text, off int
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('errors', jsonb_build_array(
    jsonb_build_object(
      'msg', msg,
      'line', lc.line + 1,
      'col', lc.col + 1
    )))
  FROM cel._line_col(source, coalesce(off, 0)) lc;
$$;

-- Rebalances a chained && / || into a balanced binary tree, as
-- cel-go's default balancer does, keeping eval recursion logarithmic
-- in chain length.
CREATE OR REPLACE FUNCTION cel._p_balance(
  elems jsonb,
  fn text,
  id bigint,
  OUT node jsonb,
  OUT nid bigint
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cnt int := jsonb_array_length(elems);
  mid int;
  l   record;
  r   record;
BEGIN
  IF cnt = 1 THEN
    node := elems -> 0;
    nid := id;
    RETURN;
  END IF;

  mid := (cnt + 1) / 2;

  SELECT b.node, b.nid INTO l
  FROM cel._p_balance(
    (SELECT jsonb_agg(e) FROM jsonb_array_elements(elems)
       WITH ORDINALITY t(e, o) WHERE o <= mid),
    fn, id) b;
  SELECT b.node, b.nid INTO r
  FROM cel._p_balance(
    (SELECT jsonb_agg(e) FROM jsonb_array_elements(elems)
       WITH ORDINALITY t(e, o) WHERE o > mid),
    fn, l.nid) b;

  nid := r.nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'call', 'fn', fn,
    'args', jsonb_build_array(l.node, r.node),
    's', l.node -> 's', 'e', r.node -> 'e');
END;
$$;

-- Walks a finished tree: extracts {"<id>": [start, stop]} offsets and
-- the macro_calls recorded inline under "mc", stripping the working
-- keys from the nodes.
CREATE OR REPLACE FUNCTION cel._p_finalize(
  node jsonb,
  OUT clean jsonb,
  OUT offsets jsonb,
  OUT macro_calls jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k       text := node ->> 'k';
  child   record;
  entry   jsonb;
  cleaned jsonb;
  n_ent   jsonb[] := '{}';
  key     text;
BEGIN
  offsets := '{}'::jsonb;
  macro_calls := '{}'::jsonb;

  IF node ? 's' THEN
    offsets := jsonb_build_object(
      node ->> 'id', jsonb_build_array(node -> 's', node -> 'e'));
  END IF;
  IF node ? 'mc' THEN
    SELECT f.clean INTO cleaned FROM cel._p_finalize(node -> 'mc') f;
    macro_calls := jsonb_build_object(node ->> 'id', cleaned);
  END IF;

  clean := node - 's' - 'e' - 'mc';

  -- Recurse into child expression positions per kind.
  FOR key IN
    SELECT unnest(CASE k
      WHEN 'select' THEN ARRAY['op']
      WHEN 'call'   THEN ARRAY['target']
      WHEN 'comp'   THEN ARRAY['range','init','cond','step','result']
      ELSE ARRAY[]::text[]
    END)
  LOOP
    IF clean ? key THEN
      SELECT * INTO child FROM cel._p_finalize(clean -> key);
      clean := jsonb_set(clean, ARRAY[key], child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
    END IF;
  END LOOP;

  IF k = 'call' AND clean ? 'args' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'args') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry);
      n_ent := n_ent || child.clean;
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
    END LOOP;
    clean := jsonb_set(clean, '{args}', to_jsonb(n_ent));
  ELSIF k = 'list' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'elems') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry);
      n_ent := n_ent || child.clean;
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
    END LOOP;
    clean := jsonb_set(clean, '{elems}', to_jsonb(n_ent));
  ELSIF k = 'map' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'entries') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry -> 'k');
      entry := jsonb_set(entry, '{k}', child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
      SELECT * INTO child FROM cel._p_finalize(entry -> 'v');
      entry := jsonb_set(entry, '{v}', child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
      n_ent := n_ent || entry;
    END LOOP;
    clean := jsonb_set(clean, '{entries}', to_jsonb(n_ent));
  ELSIF k = 'struct' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'fields') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry -> 'v');
      entry := jsonb_set(entry, '{v}', child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
      n_ent := n_ent || entry;
    END LOOP;
    clean := jsonb_set(clean, '{fields}', to_jsonb(n_ent));
  END IF;
END;
$$;

COMMIT;

BEGIN;

-- Hex digits to numeric (uint64-sized values overflow bigint).
CREATE OR REPLACE FUNCTION cel._p_hex(h text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n numeric := 0;
  c text;
BEGIN
  FOREACH c IN ARRAY string_to_array(lower(h), NULL) LOOP
    n := n * 16 + position(c IN '0123456789abcdef') - 1;
  END LOOP;
  RETURN n;
END;
$$;

-- Converts a numeric literal token into a tagged value, applying an
-- already-folded sign. The sign folds at this level so that
-- -9223372036854775808 -- whose absolute value overflows int64 --
-- parses exactly, as in cel-go, where the minus is part of the
-- literal production.
CREATE OR REPLACE FUNCTION cel._p_number_lit(
  tok jsonb,
  negate boolean,
  OUT val jsonb,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  t   text := tok ->> 't';
  raw text := tok ->> 'v';
  n   numeric;
BEGIN
  IF t = 'float' THEN
    n := raw::numeric;
    IF negate THEN
      n := -n;
    END IF;
    IF abs(n) > 1.7976931348623157e308::numeric THEN
      -- Overflow is a parse error in cel-go ("invalid double
      -- literal", measured); underflow is not: values at or below
      -- half the minimum subnormal (2^-1075, ties-to-even) round to
      -- signed zero, which Postgres's cast would instead reject as
      -- out of range, so they short-circuit here.
      err := 'invalid double literal';
      RETURN;
    END IF;
    IF n <> 0
       AND abs(n) <= 2.4703282292062327e-324::numeric THEN
      val := jsonb_build_object('@t', 'double', 'v',
        to_jsonb((CASE WHEN n < 0 THEN '-0' ELSE '0' END)::float8));
      RETURN;
    END IF;
    val := jsonb_build_object('@t', 'double', 'v', to_jsonb(n::float8));
    RETURN;
  END IF;

  IF raw ~ '^0[xX]' THEN
    n := cel._p_hex(substr(raw, 3));
  ELSE
    n := raw::numeric;
  END IF;

  IF t = 'uint' THEN
    IF negate OR n > 18446744073709551615::numeric THEN
      err := 'invalid uint literal';
      RETURN;
    END IF;
    val := jsonb_build_object('@t', 'uint', 'v', to_jsonb(n));
    RETURN;
  END IF;

  IF negate THEN
    n := -n;
  END IF;
  IF n < -9223372036854775808::numeric
     OR n > 9223372036854775807::numeric THEN
    err := 'invalid int literal';
    RETURN;
  END IF;
  val := jsonb_build_object('@t', 'int', 'v', to_jsonb(n));
END;
$$;

-- Builds a call node, expanding it through the macro registry when a
-- (function, arity, receiver-style) row is visible in the env --
-- day-one invariant 5: the standard macros take this exact path. An
-- expansion records the original call under "mc" for source info.
CREATE OR REPLACE FUNCTION cel._p_call(
  fn text,
  target jsonb,
  args jsonb,
  id bigint,
  s int,
  e int,
  mac jsonb,
  is_member boolean,
  OUT node jsonb,
  OUT nid bigint,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  arity    int := jsonb_array_length(args);
  proc     text;
  original jsonb;
  x        record;
BEGIN
  nid := id + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'call', 'fn', fn, 'args', args, 's', s, 'e', e);
  IF target IS NOT NULL THEN
    node := node || jsonb_build_object('target', target);
  END IF;

  proc := coalesce(
    mac ->> format('%s/%s/%s', fn, arity, is_member::int),
    mac ->> format('%s/-1/%s', fn, is_member::int));
  IF proc IS NULL THEN
    RETURN;
  END IF;

  original := node;
  EXECUTE format('SELECT * FROM %s($1, $2, $3)', proc)
  INTO x
  USING target, args, nid;

  IF x.err IS NOT NULL THEN
    err := x.err;
    RETURN;
  END IF;
  IF x.expr IS NULL THEN
    RETURN;   -- expander declined; keep the plain call
  END IF;

  node := x.expr || jsonb_build_object('mc', original);
  nid := x.next_id_out;
END;
$$;

COMMIT;

BEGIN;

-- The recursive grammar. Every function shares one signature:
--   (tk, p, id, d, mac, fl) -> (node, np, nid, err, ep)
-- tk: token array; p: cursor; id: last assigned node id; d: depth
-- budget consumed; mac: visible macros; fl: env flags. Nodes carry
-- their source span inline as s/e until cel._p_finalize lifts the
-- spans into the envelope. err/ep report the first failure; every
-- call site checks err and bails, because errors are values here,
-- not exceptions.

-- expr: or ('?' or ':' expr)?  (ternary is right-associative)
CREATE OR REPLACE FUNCTION cel._p_expr(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c record;
  t record;
  f record;
  x record;
BEGIN
  IF d >= 200 THEN
    err := 'expression recursion limit exceeded: 200';
    ep := (tk -> p ->> 's')::int;
    RETURN;
  END IF;

  SELECT * INTO c FROM cel._p_or(tk, p, id, d + 1, mac, fl);
  IF c.err IS NOT NULL THEN
    node := NULL; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  IF tk -> np ->> 't' <> '?' THEN
    RETURN;
  END IF;

  SELECT * INTO t FROM cel._p_or(tk, np + 1, nid, d + 1, mac, fl);
  IF t.err IS NOT NULL THEN
    err := t.err; ep := t.ep;
    RETURN;
  END IF;
  IF tk -> t.np ->> 't' <> ':' THEN
    err := 'expected '':'' in ternary';
    ep := (tk -> t.np ->> 's')::int;
    RETURN;
  END IF;
  SELECT * INTO f FROM cel._p_expr(tk, t.np + 1, t.nid, d + 1, mac, fl);
  IF f.err IS NOT NULL THEN
    err := f.err; ep := f.ep;
    RETURN;
  END IF;

  SELECT * INTO x FROM cel._p_call(
    '_?_:_', NULL,
    jsonb_build_array(node, t.node, f.node),
    f.nid, (node ->> 's')::int, (f.node ->> 'e')::int, mac, false);
  IF x.err IS NOT NULL THEN
    err := x.err; ep := (node ->> 's')::int;
    RETURN;
  END IF;
  node := x.node; np := f.np; nid := x.nid;
END;
$$;

-- Chained || gathers operands and rebalances into a balanced tree.
CREATE OR REPLACE FUNCTION cel._p_or(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c     record;
  b     record;
  elems jsonb;
BEGIN
  SELECT * INTO c FROM cel._p_and(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;
  elems := jsonb_build_array(node);

  WHILE tk -> np ->> 't' = '||' LOOP
    SELECT * INTO c FROM cel._p_and(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    elems := elems || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;
  END LOOP;

  IF jsonb_array_length(elems) > 1 THEN
    SELECT * INTO b FROM cel._p_balance(elems, '_||_', nid);
    node := b.node; nid := b.nid;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION cel._p_and(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c     record;
  b     record;
  elems jsonb;
BEGIN
  SELECT * INTO c FROM cel._p_rel(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;
  elems := jsonb_build_array(node);

  WHILE tk -> np ->> 't' = '&&' LOOP
    SELECT * INTO c FROM cel._p_rel(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    elems := elems || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;
  END LOOP;

  IF jsonb_array_length(elems) > 1 THEN
    SELECT * INTO b FROM cel._p_balance(elems, '_&&_', nid);
    node := b.node; nid := b.nid;
  END IF;
END;
$$;

-- Left-associative binary tiers: relations, additive,
-- multiplicative. One implementation parameterized by the operator
-- map and the next-tighter parser would need dynamic SQL per call;
-- three small copies keep the hot path static.
CREATE OR REPLACE FUNCTION cel._p_rel(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c  record;
  x  record;
  tt text;
  fn text;
BEGIN
  SELECT * INTO c FROM cel._p_add(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  LOOP
    tt := tk -> np ->> 't';
    fn := CASE tt
      WHEN '<'  THEN '_<_'  WHEN '<=' THEN '_<=_'
      WHEN '>'  THEN '_>_'  WHEN '>=' THEN '_>=_'
      WHEN '==' THEN '_==_' WHEN '!=' THEN '_!=_'
      WHEN 'in' THEN '@in'
    END;
    EXIT WHEN fn IS NULL;

    SELECT * INTO c FROM cel._p_add(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      fn, NULL, jsonb_build_array(node, c.node), c.nid,
      (node ->> 's')::int, (c.node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (node ->> 's')::int;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION cel._p_add(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c  record;
  x  record;
  tt text;
  fn text;
BEGIN
  SELECT * INTO c FROM cel._p_mul(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  LOOP
    tt := tk -> np ->> 't';
    fn := CASE tt WHEN '+' THEN '_+_' WHEN '-' THEN '_-_' END;
    EXIT WHEN fn IS NULL;

    SELECT * INTO c FROM cel._p_mul(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      fn, NULL, jsonb_build_array(node, c.node), c.nid,
      (node ->> 's')::int, (c.node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (node ->> 's')::int;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION cel._p_mul(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c  record;
  x  record;
  tt text;
  fn text;
BEGIN
  SELECT * INTO c FROM cel._p_unary(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  LOOP
    tt := tk -> np ->> 't';
    fn := CASE tt
      WHEN '*' THEN '_*_' WHEN '/' THEN '_/_' WHEN '%' THEN '_%_'
    END;
    EXIT WHEN fn IS NULL;

    SELECT * INTO c FROM cel._p_unary(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      fn, NULL, jsonb_build_array(node, c.node), c.nid,
      (node ->> 's')::int, (c.node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (node ->> 's')::int;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
  END LOOP;
END;
$$;

-- Unary ! and -. Even-length chains collapse to the operand; an odd
-- chain of - directly on a numeric literal folds into the literal
-- (which is how -9223372036854775808 parses exactly).
CREATE OR REPLACE FUNCTION cel._p_unary(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  op    text := tk -> p ->> 't';
  cnt   int := 0;
  q     int := p;
  c     record;
  x     record;
  s0    int;
  tok   jsonb;
BEGIN
  IF op NOT IN ('!', '-') THEN
    SELECT * INTO c FROM cel._p_member(tk, p, id, d, mac, fl);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  s0 := (tk -> p ->> 's')::int;
  WHILE tk -> q ->> 't' = op LOOP
    cnt := cnt + 1;
    q := q + 1;
  END LOOP;

  -- Sign fold: odd minus chain directly on a numeric literal.
  tok := tk -> q;
  IF op = '-' AND cnt % 2 = 1 AND tok ->> 't' IN ('int', 'float') THEN
    SELECT * INTO x FROM cel._p_number_lit(tok, true);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (tok ->> 's')::int;
      RETURN;
    END IF;
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit', 'v', x.val,
      's', s0, 'e', tok -> 'e');
    -- Postfix still applies to the folded literal.
    SELECT * INTO c FROM cel._p_postfix(node, tk, q + 1, nid, d, mac, fl);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  SELECT * INTO c FROM cel._p_member(tk, q, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  IF cnt % 2 = 1 THEN
    SELECT * INTO x FROM cel._p_call(
      CASE op WHEN '!' THEN '!_' ELSE '-_' END,
      NULL, jsonb_build_array(node), nid,
      s0, (node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := s0;
      RETURN;
    END IF;
    node := x.node; nid := x.nid;
  END IF;
END;
$$;

-- member: primary + the postfix chain.
CREATE OR REPLACE FUNCTION cel._p_member(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c record;
BEGIN
  SELECT * INTO c FROM cel._p_primary(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  SELECT * INTO c
  FROM cel._p_postfix(c.node, tk, c.np, c.nid, d, mac, fl);
  node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
END;
$$;

-- The postfix chain on an already-parsed operand: .field, .f(args),
-- [index], and the optional-syntax forms .?field and [?index], which
-- are errors unless the env sets optional_syntax.
CREATE OR REPLACE FUNCTION cel._p_postfix(
  operand jsonb, tk jsonb, p int, id bigint, d int,
  mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  tt       text;
  nt       jsonb;
  name     text;
  optional boolean;
  c        record;
  x        record;
  args     jsonb;
  s0       int := (operand ->> 's')::int;
  opt_on   boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  node := operand; np := p; nid := id;

  LOOP
    tt := tk -> np ->> 't';

    IF tt = '.' THEN
      optional := false;
      nt := tk -> (np + 1);
      IF nt ->> 't' = '?' THEN
        IF NOT opt_on THEN
          err := 'unsupported syntax ''.?''';
          ep := (tk -> np ->> 's')::int;
          RETURN;
        END IF;
        optional := true;
        nt := tk -> (np + 2);
      END IF;

      -- Reserved words are permitted as selectors (the corpus's
      -- parse/selectors section) -- only true/false/null/in are
      -- full keywords and stay excluded.
      IF nt ->> 't' NOT IN ('ident', 'esc_ident', 'reserved') THEN
        err := 'expected field or method name after ''.''';
        ep := (nt ->> 's')::int;
        RETURN;
      END IF;
      name := nt ->> 'v';
      np := np + CASE WHEN optional THEN 3 ELSE 2 END;

      IF optional THEN
        -- .?f  =>  _?._(operand, "f")
        nid := nid + 1;
        SELECT * INTO x FROM cel._p_call(
          '_?._', NULL,
          jsonb_build_array(node, jsonb_build_object(
            'id', nid, 'k', 'lit',
            'v', jsonb_build_object('@t', 'string', 'v', name),
            's', nt -> 's', 'e', nt -> 'e')),
          nid, s0, (nt ->> 'e')::int, mac, false);
        IF x.err IS NOT NULL THEN
          err := x.err; ep := s0;
          RETURN;
        END IF;
        node := x.node; nid := x.nid;
        CONTINUE;
      END IF;

      IF tk -> np ->> 't' = '(' THEN
        -- Receiver-style call.
        SELECT * INTO c FROM cel._p_args(tk, np + 1, nid, d, mac, fl);
        IF c.err IS NOT NULL THEN
          err := c.err; ep := c.ep;
          RETURN;
        END IF;
        SELECT * INTO x FROM cel._p_call(
          name, node, c.node, c.nid,
          s0, (tk -> (c.np - 1) ->> 'e')::int, mac, true);
        IF x.err IS NOT NULL THEN
          err := x.err; ep := (nt ->> 's')::int;
          RETURN;
        END IF;
        node := x.node; np := c.np; nid := x.nid;
        CONTINUE;
      END IF;

      nid := nid + 1;
      node := jsonb_build_object(
        'id', nid, 'k', 'select', 'op', node, 'field', name,
        's', s0, 'e', nt -> 'e');
      CONTINUE;
    END IF;

    IF tt = '[' THEN
      optional := false;
      IF tk -> (np + 1) ->> 't' = '?' THEN
        IF NOT opt_on THEN
          err := 'unsupported syntax ''[?''';
          ep := (tk -> np ->> 's')::int;
          RETURN;
        END IF;
        optional := true;
      END IF;

      SELECT * INTO c FROM cel._p_expr(
        tk, np + CASE WHEN optional THEN 2 ELSE 1 END,
        nid, d + 1, mac, fl);
      IF c.err IS NOT NULL THEN
        err := c.err; ep := c.ep;
        RETURN;
      END IF;
      IF tk -> c.np ->> 't' <> ']' THEN
        err := 'expected '']''';
        ep := (tk -> c.np ->> 's')::int;
        RETURN;
      END IF;
      SELECT * INTO x FROM cel._p_call(
        CASE WHEN optional THEN '_[?_]' ELSE '_[_]' END,
        NULL, jsonb_build_array(node, c.node), c.nid,
        s0, (tk -> c.np ->> 'e')::int, mac, false);
      IF x.err IS NOT NULL THEN
        err := x.err; ep := s0;
        RETURN;
      END IF;
      node := x.node; np := c.np + 1; nid := x.nid;
      CONTINUE;
    END IF;

    EXIT;
  END LOOP;
END;
$$;

-- Call argument list: '(' already consumed; returns a jsonb array of
-- argument nodes and leaves np just past ')'.
CREATE OR REPLACE FUNCTION cel._p_args(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c record;
BEGIN
  node := '[]'::jsonb; np := p; nid := id;

  IF tk -> np ->> 't' = ')' THEN
    np := np + 1;
    RETURN;
  END IF;

  LOOP
    SELECT * INTO c FROM cel._p_expr(tk, np, nid, d + 1, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    node := node || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
      CONTINUE;
    END IF;
    EXIT;
  END LOOP;

  IF tk -> np ->> 't' <> ')' THEN
    err := 'expected '')''';
    ep := (tk -> np ->> 's')::int;
    RETURN;
  END IF;
  np := np + 1;
END;
$$;

COMMIT;

BEGIN;

-- List literal: '[' consumed. Trailing comma allowed. '?e' elements
-- (optionals extension) record their indices under "opt".
CREATE OR REPLACE FUNCTION cel._p_list(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb, s0 int,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c     record;
  elems jsonb := '[]';
  opts  jsonb := '[]';
  idx   int := 0;
  opt_on boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  np := p; nid := id;

  WHILE tk -> np ->> 't' <> ']' LOOP
    IF tk -> np ->> 't' = '?' THEN
      IF NOT opt_on THEN
        err := 'unsupported syntax ''?''';
        ep := (tk -> np ->> 's')::int;
        RETURN;
      END IF;
      opts := opts || to_jsonb(idx);
      np := np + 1;
    END IF;

    SELECT * INTO c FROM cel._p_expr(tk, np, nid, d + 1, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    elems := elems || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;
    idx := idx + 1;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
    ELSIF tk -> np ->> 't' <> ']' THEN
      err := 'expected '','' or '']''';
      ep := (tk -> np ->> 's')::int;
      RETURN;
    END IF;
  END LOOP;

  nid := nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'list', 'elems', elems,
    's', s0, 'e', tk -> np -> 'e');
  IF jsonb_array_length(opts) > 0 THEN
    node := node || jsonb_build_object('opt', opts);
  END IF;
  np := np + 1;
END;
$$;

-- Map literal: '{' consumed. Keys are full expressions (the checker
-- restricts them); entries carry their own ids as in cel-go.
CREATE OR REPLACE FUNCTION cel._p_map(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb, s0 int,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k       record;
  v       record;
  entries jsonb := '[]';
  optional boolean;
  opt_on  boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  np := p; nid := id;

  WHILE tk -> np ->> 't' <> '}' LOOP
    optional := false;
    IF tk -> np ->> 't' = '?' THEN
      IF NOT opt_on THEN
        err := 'unsupported syntax ''?''';
        ep := (tk -> np ->> 's')::int;
        RETURN;
      END IF;
      optional := true;
      np := np + 1;
    END IF;

    SELECT * INTO k FROM cel._p_expr(tk, np, nid, d + 1, mac, fl);
    IF k.err IS NOT NULL THEN
      err := k.err; ep := k.ep;
      RETURN;
    END IF;
    IF tk -> k.np ->> 't' <> ':' THEN
      err := 'expected '':''';
      ep := (tk -> k.np ->> 's')::int;
      RETURN;
    END IF;
    SELECT * INTO v FROM cel._p_expr(tk, k.np + 1, k.nid, d + 1, mac, fl);
    IF v.err IS NOT NULL THEN
      err := v.err; ep := v.ep;
      RETURN;
    END IF;

    nid := v.nid + 1;
    entries := entries || jsonb_build_array(jsonb_build_object(
      'id', nid, 'k', k.node, 'v', v.node, 'opt', optional));
    np := v.np;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
    ELSIF tk -> np ->> 't' <> '}' THEN
      err := 'expected '','' or ''}''';
      ep := (tk -> np ->> 's')::int;
      RETURN;
    END IF;
  END LOOP;

  nid := nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'map', 'entries', entries,
    's', s0, 'e', tk -> np -> 'e');
  np := np + 1;
END;
$$;

-- Message literal: the type name and '{' are consumed. Field names
-- are identifiers or escaped identifiers.
CREATE OR REPLACE FUNCTION cel._p_struct(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  type_name text, s0 int,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v       record;
  fields  jsonb := '[]';
  fname   text;
  optional boolean;
  nt      jsonb;
  opt_on  boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  np := p; nid := id;

  WHILE tk -> np ->> 't' <> '}' LOOP
    optional := false;
    IF tk -> np ->> 't' = '?' THEN
      IF NOT opt_on THEN
        err := 'unsupported syntax ''?''';
        ep := (tk -> np ->> 's')::int;
        RETURN;
      END IF;
      optional := true;
      np := np + 1;
    END IF;

    nt := tk -> np;
    IF nt ->> 't' NOT IN ('ident', 'esc_ident') THEN
      err := 'expected field name';
      ep := (nt ->> 's')::int;
      RETURN;
    END IF;
    fname := nt ->> 'v';
    IF tk -> (np + 1) ->> 't' <> ':' THEN
      err := 'expected '':''';
      ep := (tk -> (np + 1) ->> 's')::int;
      RETURN;
    END IF;

    SELECT * INTO v FROM cel._p_expr(tk, np + 2, nid, d + 1, mac, fl);
    IF v.err IS NOT NULL THEN
      err := v.err; ep := v.ep;
      RETURN;
    END IF;

    nid := v.nid + 1;
    fields := fields || jsonb_build_array(jsonb_build_object(
      'id', nid, 'name', fname, 'v', v.node, 'opt', optional));
    np := v.np;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
    ELSIF tk -> np ->> 't' <> '}' THEN
      err := 'expected '','' or ''}''';
      ep := (tk -> np ->> 's')::int;
      RETURN;
    END IF;
  END LOOP;

  nid := nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'struct', 'type', type_name, 'fields', fields,
    's', s0, 'e', tk -> np -> 'e');
  np := np + 1;
END;
$$;

-- primary: literals, identifiers, global calls, parens, list/map/
-- message literals. A dotted identifier path followed by '{' is a
-- message literal; the lookahead scan consumes nothing on miss.
CREATE OR REPLACE FUNCTION cel._p_primary(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  tok    jsonb := tk -> p;
  tt     text := tk -> p ->> 't';
  s0     int := (tk -> p ->> 's')::int;
  c      record;
  x      record;
  name   text;
  j      int;
  leading_dot boolean := false;
BEGIN
  np := p; nid := id;

  -- Literals.
  IF tt IN ('int', 'uint', 'float') THEN
    SELECT * INTO x FROM cel._p_number_lit(tok, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := s0;
      RETURN;
    END IF;
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit', 'v', x.val, 's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'string' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'string', 'v', tok -> 'v'),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'bytes' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bytes', 'v', tok -> 'v'),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'bool' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', tok -> 'v'),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'null' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'null', 'v', NULL),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  END IF;

  -- Parenthesized expression.
  IF tt = '(' THEN
    SELECT * INTO c FROM cel._p_expr(tk, p + 1, id, d + 1, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    IF tk -> c.np ->> 't' <> ')' THEN
      err := 'expected '')''';
      ep := (tk -> c.np ->> 's')::int;
      RETURN;
    END IF;
    node := c.node; np := c.np + 1; nid := c.nid;
    RETURN;
  END IF;

  IF tt = '[' THEN
    SELECT * INTO c
    FROM cel._p_list(tk, p + 1, id, d, mac, fl, s0);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  IF tt = '{' THEN
    SELECT * INTO c
    FROM cel._p_map(tk, p + 1, id, d, mac, fl, s0);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  IF tt = 'reserved' THEN
    err := format('reserved identifier: %s', tok ->> 'v');
    ep := s0;
    RETURN;
  END IF;

  -- Leading '.' root-qualifies the identifier that follows.
  IF tt = '.' THEN
    leading_dot := true;
    np := p + 1;
    tok := tk -> np;
    tt := tok ->> 't';
    IF tt = 'reserved' THEN
      err := format('reserved identifier: %s', tok ->> 'v');
      ep := (tok ->> 's')::int;
      RETURN;
    END IF;
    IF tt <> 'ident' THEN
      err := 'expected identifier after ''.''';
      ep := (tok ->> 's')::int;
      RETURN;
    END IF;
  END IF;

  IF tt <> 'ident' THEN
    IF tt = 'eof' THEN
      err := 'unexpected end of expression';
    ELSE
      err := format('unexpected token %s',
        quote_literal(coalesce(tok ->> 'v', tt)));
    END IF;
    ep := s0;
    RETURN;
  END IF;

  name := tok ->> 'v';

  -- Message-literal lookahead: ident ('.' ident)* '{'. The scan
  -- consumes nothing unless the '{' really is there.
  j := np + 1;
  WHILE tk -> j ->> 't' = '.' AND tk -> (j + 1) ->> 't' = 'ident' LOOP
    j := j + 2;
  END LOOP;
  IF tk -> j ->> 't' = '{' THEN
    -- Rebuild the dotted name from the scanned tokens.
    DECLARE
      k2 int := np + 1;
    BEGIN
      WHILE k2 < j LOOP
        name := name || '.' || (tk -> (k2 + 1) ->> 'v');
        k2 := k2 + 2;
      END LOOP;
    END;
    IF leading_dot THEN
      name := '.' || name;
    END IF;
    SELECT * INTO c
    FROM cel._p_struct(tk, j + 1, id, d, mac, fl, name, s0);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  -- Global call.
  IF tk -> (np + 1) ->> 't' = '(' THEN
    SELECT * INTO c FROM cel._p_args(tk, np + 2, id, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      CASE WHEN leading_dot THEN '.' || name ELSE name END,
      NULL, c.node, c.nid,
      s0, (tk -> (c.np - 1) ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := s0;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
    RETURN;
  END IF;

  -- Plain identifier.
  nid := id + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'ident',
    'name', CASE WHEN leading_dot THEN '.' || name ELSE name END,
    's', s0, 'e', tok -> 'e');
  np := np + 1;
END;
$$;

COMMIT;

BEGIN;

-- Macro expanders. Each has the registry signature
--   (target jsonb, args jsonb, next_id bigint)
--     -> (expr jsonb, next_id bigint, err text)
-- and builds the exact comprehension shapes cel-go's standard macros
-- produce, accumulator named @result. The standard six register
-- through cel.macro like any extension's -- no privileged path.

-- Validates a comprehension iteration variable argument.
CREATE OR REPLACE FUNCTION cel._mx_itervar(
  arg jsonb, OUT name text, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF arg ->> 'k' <> 'ident' THEN
    IF arg ->> 'k' = 'select' THEN
      err := 'argument must be a simple name';
    ELSE
      err := 'argument is not an identifier';
    END IF;
    RETURN;
  END IF;
  name := arg ->> 'name';
  IF name IN ('@result', '__result__') THEN
    err := 'iteration variable overwrites accumulator variable';
  END IF;
END;
$$;

-- has(e): a select becomes a presence test; anything else is an
-- error. No new ids are needed.
CREATE OR REPLACE FUNCTION cel._mx_has(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  arg jsonb := args -> 0;
BEGIN
  next_id_out := next_id;
  IF arg ->> 'k' <> 'select' THEN
    err := 'invalid argument to has() macro';
    RETURN;
  END IF;
  expr := arg || jsonb_build_object('test', true);
END;
$$;

-- Shared assembly for the five standard comprehensions. kind picks
-- the init/cond/step/result wiring; p and t are the predicate /
-- transform arguments where the macro has them.
CREATE OR REPLACE FUNCTION cel._mx_fold(
  kind text,
  target jsonb, iter text, p jsonb, t jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  id bigint := next_id;
  cs jsonb := target -> 's';
  ce jsonb := coalesce(t, p, target) -> 'e';
  init jsonb;
  cond jsonb;
  step jsonb;
  result jsonb;
  accu jsonb;
  tmp jsonb;
BEGIN
  -- Helper shapes reused below; each use re-stamps a fresh id.

  IF kind = 'all' THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', true),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'call',
      'fn', '@not_strictly_false', 'args', jsonb_build_array(accu),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_&&_', 'args', jsonb_build_array(accu, p),
      's', cs, 'e', ce);
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);

  ELSIF kind = 'exists' THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', false),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'call',
      'fn', '!_', 'args', jsonb_build_array(accu),
      's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'call',
      'fn', '@not_strictly_false', 'args', jsonb_build_array(tmp),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_||_', 'args', jsonb_build_array(accu, p),
      's', cs, 'e', ce);
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);

  ELSIF kind = 'exists_one' THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'int', 'v', 0),
      's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', true),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'int', 'v', 1),
      's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_+_', 'args', jsonb_build_array(accu, tmp),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_?_:_', 'args', jsonb_build_array(p, tmp, accu),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'int', 'v', 1),
      's', cs, 'e', ce);
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_==_', 'args', jsonb_build_array(accu, tmp),
      's', cs, 'e', ce);

  ELSIF kind IN ('map', 'map_filter', 'filter') THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'list',
      'elems', '[]'::jsonb, 's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', true),
      's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'list',
      'elems', jsonb_build_array(
        CASE WHEN kind = 'filter'
             THEN jsonb_build_object('k', 'ident', 'name', iter,
                                     's', cs, 'e', ce)
             ELSE t END),
      's', cs, 'e', ce);
    -- The filter element ident needs its own id.
    IF kind = 'filter' THEN
      id := id + 1;
      tmp := jsonb_set(tmp, '{elems,0,id}', to_jsonb(id));
    END IF;
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_+_', 'args', jsonb_build_array(accu, tmp),
      's', cs, 'e', ce);
    IF kind <> 'map' THEN
      id := id + 1;
      accu := jsonb_build_object('id', id, 'k', 'ident',
        'name', '@result', 's', cs, 'e', ce);
      id := id + 1;
      step := jsonb_build_object('id', id, 'k', 'call',
        'fn', '_?_:_', 'args', jsonb_build_array(p, step, accu),
        's', cs, 'e', ce);
    END IF;
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
  ELSE
    err := format('unknown fold kind %s', kind);
    RETURN;
  END IF;

  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', target, 'iter', iter, 'iter2', '',
    'accu', '@result',
    'init', init, 'cond', cond, 'step', step, 'result', result,
    's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_all(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('all', target, v.name, args -> 1, NULL, next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_exists(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('exists', target, v.name, args -> 1, NULL, next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_exists_one(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('exists_one', target, v.name, args -> 1, NULL,
                    next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

-- map has arity 2 (transform) and arity 3 (filter + transform).
CREATE OR REPLACE FUNCTION cel._mx_map(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  IF jsonb_array_length(args) = 3 THEN
    SELECT * INTO f FROM cel._mx_fold(
      'map_filter', target, v.name, args -> 1, args -> 2, next_id);
  ELSE
    SELECT * INTO f FROM cel._mx_fold(
      'map', target, v.name, NULL, args -> 1, next_id);
  END IF;
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_filter(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('filter', target, v.name, args -> 1, NULL, next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

-- The standard macro rows and their visibility in the standard env.
INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('has',        1, false, 'cel._mx_has(jsonb,jsonb,bigint)'),
  ('all',        2, true,  'cel._mx_all(jsonb,jsonb,bigint)'),
  ('exists',     2, true,  'cel._mx_exists(jsonb,jsonb,bigint)'),
  ('exists_one', 2, true,  'cel._mx_exists_one(jsonb,jsonb,bigint)'),
  ('map',        2, true,  'cel._mx_map(jsonb,jsonb,bigint)'),
  ('map',        3, true,  'cel._mx_map(jsonb,jsonb,bigint)'),
  ('filter',     2, true,  'cel._mx_filter(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE SET expander = excluded.expander;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'macro', format('%s/%s/%s', name, arity, member::int)
FROM cel.macro
ON CONFLICT DO NOTHING;

-- Parses CEL source under an environment. Returns the AST envelope,
-- or {"errors": [...]} when the expression is rejected -- callers
-- and the conformance runner key on the "errors" field.
CREATE OR REPLACE FUNCTION cel.parse(source text, env text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  fl  jsonb;
  mac jsonb;
  lx  record;
  px  record;
  fin record;
  lines jsonb;
BEGIN
  IF length(source) > 100000 THEN
    RETURN cel._parse_errors(source, 'expression size limit exceeded', 0);
  END IF;

  fl := cel._env_flags(env);
  mac := cel._env_macros(env);

  SELECT * INTO lx FROM cel._lex(source, fl);
  IF lx.err IS NOT NULL THEN
    RETURN cel._parse_errors(source, lx.err, lx.errpos);
  END IF;

  SELECT * INTO px FROM cel._p_expr(lx.toks, 0, 0, 0, mac, fl);
  IF px.err IS NOT NULL THEN
    RETURN cel._parse_errors(source, px.err, px.ep);
  END IF;
  IF lx.toks -> px.np ->> 't' <> 'eof' THEN
    RETURN cel._parse_errors(
      source,
      format('unexpected token %s', quote_literal(coalesce(
        lx.toks -> px.np ->> 'v', lx.toks -> px.np ->> 't'))),
      (lx.toks -> px.np ->> 's')::int);
  END IF;
  IF px.nid > 100000 THEN
    RETURN cel._parse_errors(source, 'expression node limit exceeded', 0);
  END IF;

  SELECT * INTO fin FROM cel._p_finalize(px.node);

  SELECT coalesce(jsonb_agg(o - 1), '[]'::jsonb) INTO lines
  FROM (
    SELECT o
    FROM unnest(string_to_array(source, NULL)) WITH ORDINALITY t(ch, o)
    WHERE ch = E'\n'
  ) nl;

  RETURN jsonb_build_object(
    'v', 1,
    'expr', fin.clean,
    'source', jsonb_build_object(
      'desc', '<input>',
      'lines', lines,
      'offsets', fin.offsets,
      'macro_calls', fin.macro_calls));
END;
$$;

COMMIT;
