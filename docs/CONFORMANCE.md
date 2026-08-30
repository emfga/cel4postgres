# Conformance

What "cel4postgres is CEL-conformant" claims, what it excludes, and
every place it knowingly answers differently from cel-go.

The numbers live in [conformance-report.md](conformance-report.md),
which is generated from an actual run and kept current by a test. This
document is the part that does not come out of a machine: what was
measured, against what, and why the exceptions are what they are.

## The claim

Every in-scope case of the [cel-spec][cel-spec] simple conformance
corpus passes against a fresh cel4postgres install, with no failures
and no unnamed omissions.

Three things pin what that sentence means:

| | |
|---|---|
| corpus | cel-spec at `ba58ae5007845f3a1279b488cdeb79645ce958bb` |
| reference | cel-go `v0.32.0` |
| substrate | PostgreSQL 18 |

All three are pinned deliberately and move only with a
re-measurement behind them. Which expressions two implementations
agree on changes with the version of either, so a bumped dependency
is a changed claim, not a routine upgrade. The corpus commit lives in
`internal/corpus.Pin`, the cel-go version in `internal/oracle.Version`,
and tests fail when either drifts from what the build actually uses.

## What is in scope

The cel-spec core language over the JSON-representable types — `bool`,
`int`, `uint`, `double`, `string`, `bytes`, `null`, `list`, `map`,
`type` — the standard library, the standard macros, overflow and
conversion semantics, and error and unknown propagation.

The well-known types are in scope and implemented: `Timestamp`,
`Duration`, `Struct`, `Value`, `ListValue`, `Any` (name resolution),
and the nine `Int32Value`-family wrappers. These are JSON-shaped and
need no descriptor pool, so they are ordinary registered type rows.

The extension libraries — `strings`, `math`, `lists`, `encoders`,
`bindings`, `optionals`, two-variable comprehensions, and `network` —
are implemented and conformance-tested, each behind its own
environment name. **None of them is enabled in the default
environment.** That is load-bearing: a spec-conformance number
measured in an environment that quietly gained an extension is
measuring something else.

## What is not attempted, and why

Nothing is skipped silently. Every omission is a named entry the test
binary prints on each run and the generated report lists in full.

**Protobuf messages are out of scope**, and with them field selection
over messages, proto2/proto3 presence semantics, and enums. They
require a descriptor pool inside PostgreSQL and buy nothing for the
JSON-shaped data cel4postgres exists to serve. Six corpus files are
not attempted for this reason (`proto2`, `proto3`, `enums`,
`wrappers`, `proto2_ext`) or because they exercise a cel-go-internal
form with no consumer (`block_ext`).

Inside attempted files, cases are skipped in exactly two categories,
both derived mechanically from the corpus rather than listed by hand,
so the list cannot drift from what the corpus actually contains:

- **Requires protobuf descriptors** — the case constructs or
  references `TestAllTypes`, `NestedTestAllTypes`,
  `Proto2ExtensionScopedMessage`, or an `Any` wrapping serialized
  proto bytes. Same exclusion as above, at case granularity.
- **PostgreSQL text cannot represent NUL in strings** — PostgreSQL
  `text` and `jsonb` categorically reject U+0000. Twenty-nine corpus
  cases carry one: twenty expect a string value containing NUL, and
  nine spell a NUL byte directly in the expression text. This is a
  substrate limit, not a CEL one, and it is the one place a
  conformance gap is permanent rather than out of scope. Bytes
  containing NUL are unaffected, and so are raw-string literals like
  `r'\000'`, whose value is backslash characters rather than a NUL.

## How it is measured

Each corpus file runs under the environment its features require, as a
union of registered environment names: `basic` and `comparisons` under
`standard`; `string_ext` under `standard,strings`; `math_ext` under
`standard,math`, and so on. The per-file environment is printed in the
report.

This is **stricter than cel-go's own conformance harness**, which
builds one environment with every extension enabled globally and
selects only macros on or off per test. The stricter form is the
point: cel4postgres's extension model is registry rows, and per-file
environments are what demonstrates that an extension is genuinely
absent until registered. A file that passes only because the default
environment gained an extension is not a passing file.

Both sides of every comparison are configured the same way. The
reference environment is assembled in exactly one place
(`internal/oracle`), from the same environment string the database
side receives, and the same comparator judges both outcomes. A
comparison against a reference configured ad hoc per call site
measures two different references and reports it as one.

## The reference, and what happens when it disagrees

cel-go is the behavioural authority: a claim about CEL semantics that
has not been run against it is a hypothesis. cel-java is the second
opinion where cel-go's behaviour looks like an implementation detail
rather than a specified one — two independent implementations
agreeing is evidence about the spec, one is evidence about that
implementation.

Where the corpus and cel-go disagree, **cel4postgres follows the
corpus.** The corpus is the specification's own executable statement
of intent; cel-go is an implementation of it, and its maintainers
mark several of these cases as known-failing in their own build. Each
such case was adjudicated individually before being encoded, with the
spec text read and cel-java consulted.

The consequence is that the divergence list below is, with one
exception, a list of cases where cel-go does not satisfy the corpus.
It is generated by running both implementations over every attempted
case, so it is measured on each regeneration rather than remembered.

## Divergence register

Ten cases, in six groups. The report names each one with its
expression and both verdicts.

### Map keys: forbidden types and duplicates

`fields/qualified_identifier_resolution/map_key_float`,
`map_value_repeat_key`, `map_value_repeat_key_heterogeneous`

The spec text is settled: `double` and `null` are not valid map key
types, and duplicate keys are an error at construction — including
keys that collide only after `int`/`uint` normalization, as in
`{0: 1, 0u: 2}`. The corpus expects an error; cel-go v0.32.0 returns a
value and annotates the cases with its current behaviour as a
comment. cel4postgres errors.

(`map_key_null` is not a divergence: cel-go rejects it too, when
planning rather than when evaluating.)

### `duration.getMilliseconds()`

`timestamps/duration_converters/get_milliseconds`

The corpus expects the sub-second component — `321` for a duration of
123s 321456789ns. cel-go v0.32.0 returns total milliseconds
(`123321`). cel-java's `GetMillisecondsFunction` computes
`toMillis(arg) % 1000`, agreeing with the corpus, and the corpus's own
description marks the total-milliseconds reading as the one being
deprecated. Corpus and cel-java against cel-go alone is not a
three-way split. cel4postgres returns the component.

### `indexOf` / `lastIndexOf` with an out-of-range offset

`string_ext/value_errors/indexof_out_of_range`,
`lastindexof_out_of_range`

`'tacocat'.indexOf('a', 30)` errors per the corpus; cel-go returns
`-1`. cel-java's `CelStringExtensions` throws "Offset out of range"
for `offset < 0 || offset >= length`, agreeing with the corpus — and
cel-go itself errors on the negative-offset and `substring` variants,
so its own behaviour is internally inconsistent here. cel4postgres
errors. The empty-substring special case returns the offset before
the bounds check, matching both implementations.

### `has()` through an optional chain

`optionals/optionals/map_optional_select_has`

`has({'foo': optional.none()}.foo.bar)` is `false` per the corpus;
cel-go raises "no such key: bar". Optional qualification is
if-present throughout cel4postgres: qualifying a present optional
with a missing key or index yields `optional.none()`, never an error.

### Joining `null` with a legacy nullable type

`type_deduction/legacy_nullable_types/null_assignable_to_abstract_parameter_candidate`

The one entry where no implementation agrees with the corpus.
`[optional.of(1), null][0]` should deduce `optional_type(int)`;
cel-go's `joinTypes`/`mostGeneral` answers `null`, and cel-java's
checker is the same algorithm. cel-go's conformance build skips all
four `legacy_nullable_types` cases as known-failing, which marks its
own behaviour as pending a fix rather than as intended. cel4postgres
encodes the corpus: joining `null` with a legacy-nullable type keeps
the nullable type.

### IPv4-mapped IPv6 addresses

`network_ext/ipv4/ipv4_equals_ipv6`, `ipv4_not_equals_ipv6`

The corpus accepts the hex form `::ffff:c0a8:1` and treats it as
equal to the IPv4 address it maps to, while rejecting the dotted form
`::ffff:192.168.0.1`. cel-go v0.32.0's `parseIPAddr` rejects both, and
its conformance harness does not run `network_ext` at all — so there
is no reference position to weigh here, only the corpus, and the
corpus is what cel4postgres implements.

## Divergences the corpus does not cover

Three behaviours differ from cel-go without a corpus case to record
it. They are stated here because a divergence nothing tests is the
kind that surprises someone in production.

- **`matches()` uses PostgreSQL's regex engine (ARE), not RE2.** All
  nine patterns the corpus uses were measured to agree. ARE and RE2
  differ in corners — ARE has backreferences, escape classes differ —
  so a pattern outside the measured set is not covered by the
  conformance claim.
- **`optional.or` and `orValue` are strict**, evaluating both sides,
  where cel-go's interpreter special-cases them to short-circuit.
  Every corpus case passes either way; the difference is observable
  only when the right-hand side errors and the left is present.
- **Unknown propagation has no corpus coverage at all** —
  `unknowns.textproto` is an empty stub upstream. It is covered
  instead by a 24-case suite diffed against cel-go's partial
  evaluation, which passes: unknowns win over errors in `&&` and `||`
  in either order, conditionals propagate only the taken branch, and
  comprehensions absorb unknowns exactly as `&&` and `||` do.

## Reproducing it

```bash
docker compose up -d --wait     # installs the schema during initdb
go test ./conformance/...       # the suite; prints every skip
go run ./internal/cmd/confreport  # regenerates the report
```

The corpus is read from a local cel-spec checkout named by
`CEL_EXPR_DIR`, never a hard-coded path. The report regenerates
deterministically from a run, and `TestReportCurrent` fails when the
committed copy stops describing this tree.

[cel-spec]: https://github.com/cel-expr/cel-spec
