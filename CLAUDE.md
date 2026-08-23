# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**cel4postgres** is a zero-dependency PL/pgSQL evaluator for Google's
Common Expression Language (CEL). It parses, type-checks and evaluates
CEL inside PostgreSQL, with no server-side extension, no shared library,
and no procedural language beyond `plpgsql`.

**Status: the evaluator is complete and the in-scope conformance
corpus is green.** The pipeline is `sql/010_registry.sql` (the four
registry tables), `020_values.sql` (tagged values, equality,
comparison), `030_parse.sql` (lexer, Pratt parser, macro engine),
`040_check.sql` (checker with overload-id binding), `050_eval.sql`
(evaluator core and the public `eval`/`evaluate` entry points),
`060_stdlib.sql` (standard library rows and impls), `070_wkt.sql`
(timestamps, durations, wrappers, Struct/Value/ListValue), and the
extension libraries `100`–`170` (two-var comprehensions, optionals,
strings, math, lists, encoders, bindings, network), each visible
only under its own env name. Every in-scope conformance file passes
on a fresh install; skips are a named list the suite prints (proto
descriptor material and NUL-in-string cases). Unknown propagation
is covered by its own suite against cel-go partial evaluation.
When the code and this file disagree, the code is right and this
file is a bug.

"Zero-dependency" is the product claim and the design constraint: a
consumer installs cel4postgres by running SQL scripts against a database
they can already connect to, on any PostgreSQL — self-hosted, RDS,
Aurora, Cloud SQL — without a superuser, a filesystem, or a restart.

## Scope

**In scope (v1):** the cel-spec core language over the
JSON-representable types — `bool`, `int` (int64), `uint` (uint64),
`double`, `string`, `bytes`, `null`, `list`, `map`, `type` — plus the
well-known types every implementation needs: `google.protobuf.Timestamp`,
`google.protobuf.Duration`, `Any`, and `Struct`/`Value`/`ListValue`. The
standard library, the standard macros (`has` and the five
comprehensions), overflow and conversion semantics, and error/unknown
propagation.

**Out of scope (v1):** protobuf messages, field selection over messages,
proto2/proto3 presence semantics, and enums. These require a
descriptor pool inside Postgres and buy nothing for the JSON-shaped
data cel4postgres targets. The corresponding conformance files
(`proto2`, `proto3`, `enums`, `wrappers`, `proto2_ext`) are out of
scope with them.

The wrapper types (`Int32Value` and family) turned out not to need a
descriptor pool — they are JSON-shaped, constructed by registered
type rows like every other WKT — so they are in scope and
implemented in `sql/070_wkt.sql`. The `wrappers` conformance file
stays skipped only because its cases also need proto3 `TestAllTypes`
and `Any` unpacking.

**Out of core, in by registration:** every cel-go extension library
(`strings`, `math`, `lists`, `sets`, `encoders`, `bindings`,
`optionals`), and OpenFGA's `ipaddress` / `in_cidr`. None of these ships
enabled in the spec-conformant default environment. All of them are
addable later without touching the core — that property is the point of
the registry design below, and the *day-one invariants* are what protect
it.

## Decisions

Recorded with their reasoning because each one closes off an alternative
a future contributor will otherwise reopen.

**Packaging is plain SQL scripts in a `cel` schema, not a PGXS
extension.** A self-authored extension cannot be installed on RDS or
Aurora at all: PostgreSQL 13's TRUSTED extensions relaxed *who* may run
`CREATE EXTENSION`, but the `.control` and script files still have to sit
on the server's filesystem, and managed Postgres gives you no path to put
them there. `psql -f` needs nothing but a connection. The cost we accept
in exchange is owning versioning ourselves — see *Installation and
privileges*.

**Values are tagged `jsonb` end to end.** Two measured facts drive this.
A self-referential composite type is rejected outright by Postgres
(`composite type cel_value cannot be made a member of itself`), so a CEL
value cannot be a recursive composite and containers have to nest through
`jsonb` regardless. And `jsonb` numbers are backed by `numeric`, so
`9223372036854775807` and `18446744073709551615` round-trip exactly and
`1.0` stays textually distinct from `1` — precision is not at risk, only
*type identity*, which the tag carries. A composite-scalar/`jsonb`-
container hybrid would be faster and would put a conversion boundary in
every extension function signature; uniform `jsonb` means every
registered implementation has the identical shape, which is what keeps
the registry honest.

**`cel.parse` and `cel.check` are pure and `IMMUTABLE`; memoization is
the caller's, opt-in.** A compile function that writes its own cache
table cannot be `IMMUTABLE`, fails in read-only transactions and on
standbys, and forfeits expression indexes
(`CREATE INDEX … ON t (cel.evaluate(…))`). If a cache is wanted, it is a
separate table the caller manages.

**The OpenFGA dialect is an extension, not a fork of the core.** It
registers `ipaddress` and `in_cidr` and adds a typed-parameter/context-
coercion module, in its own `cel_openfga` schema. The `cel` schema stays
spec-clean, which is the only thing that makes a conformance number mean
anything.

## Architecture

```
cel.parse(source text, env text)                → ast   jsonb
cel.check(ast jsonb, env text[, options jsonb]) → ast   jsonb
cel.eval(ast jsonb, activation jsonb, env text[, options jsonb])
                                                → value jsonb
cel.evaluate(source text, activation jsonb, env text) → value jsonb
```

`env` is threaded through every stage as a parameter. It is never a
session GUC and never a default baked into the evaluator: one
installation has to serve the spec-conformant environment, the OpenFGA
dialect and a client's own dialect simultaneously, and a global would
collapse them.

`options` carries per-call context that is not part of the
environment: the namespace `container` and, for `check`, extra ident
declarations (`decls`). `eval` accepts a container because unchecked
evaluation resolves names at runtime — the conformance corpus's
disable_check container cases cannot pass without it. Checked ASTs
ignore it: the checker has already rewritten every name to its
qualified form. The plain three-argument forms remain as wrappers.

Macros expand during `parse`. Overloads resolve during `check`, which
binds an **overload id** into the AST. `eval` dispatches on that bound id
and never on runtime types.

### The four registries

An extension is rows plus a few PL/pgSQL functions. It is never a patch
to the core.

| Table | Holds | Example registrant |
|---|---|---|
| `cel.type` | custom type name, coerce / equal / format impls | `ipaddress`, `optional` |
| `cel.overload` | overload id, name, receiver-vs-global, arg types, result type, impl `regprocedure` | `strings`, `math`, `in_cidr` |
| `cel.macro` | macro name, arity, AST-rewriter `regprocedure` | `has`, comprehensions, `cel.bind` |
| `cel.env` | a named bundle naming which types / overloads / macros are visible | `standard`, `openfga`, `strings` |

**The standard library registers through these same tables.** There is no
privileged path for builtins. If the core can reach a function the
registry cannot describe, the registry has stopped being the extension
mechanism and extensions are core patches again.

### Day-one invariants

These five are the ones that *are* rework if deferred. Everything else in
the extension story is additive.

1. **Table-driven dispatch.** No `CASE` on function name anywhere in the
   evaluator. One hardcoded branch per builtin makes every future
   extension a core change.
2. **Overload ids are first class.** cel-go binds `add_int64`,
   `add_string`, `matches_string` at check time and dispatches on the id.
   Conformance error text and `type_deduction.textproto` both depend on
   it, and retrofitting id-binding means rewriting the checker.
3. **The value representation carries an opaque kind** —
   `{"@t":"opaque","type":"ipaddress","v":…}`. Without it, `ipaddress`
   and `optionals` each need a new core kind; with it, they are registry
   rows.
4. **Error and unknown propagation live in the core evaluator.** CEL
   absorbs errors commutatively across `&&` / `||` (`false && error` is
   `false`, in either order) and propagates unknowns as a distinct third
   outcome. This is spread through the whole evaluator, cannot be bolted
   on, and is what `unknowns.textproto` exists to check.
5. **Macro expansion is a pluggable parse-time hook from the start.**
   `has` and the comprehensions are macros; so are `cel.bind` and the
   `optionals` syntax. A parser with the standard six hand-written into
   it makes the `bindings` extension a parser change.

## Installation and privileges

Installation is `psql -f`. Registration authority is a Postgres **role**
privilege, never superuser — nothing in the design needs a capability
managed Postgres withholds.

Registering an extension requires: ownership of / `CREATE` on the `cel`
schema, `INSERT` on the four registry tables, `CREATE FUNCTION` in a
trusted language (`plpgsql`, `sql`), and `EXECUTE` on the impl being
registered. All four are available to an RDS master user and to any role
it delegates to.

Nothing in cel4postgres may require: writing into `$SHAREDIR/extension`,
loading a `.so`, `CREATE EXTENSION` of anything not already allowlisted
by the platform, `COPY … FROM PROGRAM`, an untrusted procedural language,
a `shared_preload_libraries` change, or filesystem access of any kind. A
change that introduces one of these breaks the product claim.

The intended role split:

```sql
CREATE ROLE cel_admin;   -- registration authority
CREATE ROLE cel_user;    -- application runtime

REVOKE ALL ON SCHEMA cel FROM PUBLIC;
GRANT USAGE ON SCHEMA cel TO cel_user;
GRANT EXECUTE ON FUNCTION cel.evaluate(text, jsonb, text) TO cel_user;
-- registry tables readable by the evaluator, writable only by cel_admin
```

The application role gets `evaluate` and nothing else; it can never add an
overload. Two consequences to keep in mind:

- **We own versioning.** No `pg_extension` row, no
  `ALTER EXTENSION … UPDATE`, and `pg_dump` emits every function body
  rather than one line. A `cel.schema_version` table and ordered
  install/upgrade scripts are ours to maintain. The upside is that
  snapshots, Blue/Green deployments and major-version upgrades carry
  `cel` as ordinary schema objects, with no wait for a platform vendor.
- **Any `SECURITY DEFINER` function needs `SET search_path = cel,
  pg_temp`.** Evaluation itself runs `SECURITY INVOKER`. The registry
  should additionally require that a registered impl lives in a schema
  `cel_admin` controls — the platform will not check this for us.

## Conformance testing

Conformance is the primary measure of correctness, and it is what the Go
toolchain is here for. cel4postgres itself has no Go in its runtime.

The harness is a Go test binary that, for each in-scope
`cel-spec/tests/simple/testdata/*.textproto`, parses the `SimpleTestFile`
protos, evaluates every `test` case against a live PostgreSQL, and
compares the result to the expected `value` / `eval_error`. Where a case
is ambiguous, cel-go evaluating the same expression is the tiebreak — a
claim about CEL semantics that has not been run against cel-go is a
hypothesis.

**Each file runs under the `env` its features require**:
`basic`/`comparisons`/`logic` under `standard`, `string_ext` under
`standard + strings`, and so on. This is deliberately stricter than
cel-go's own `conformance_test.go`, which (measured) builds one
environment with every extension enabled globally — per-file envs are
the property the registry design exists to prove, and the oracle is
configured per-file the same way when used as tiebreak. A file that passes
only because the default environment quietly gained an extension is not
a passing file — that is the failure mode the env parameter exists to
prevent.

Out-of-scope files (`proto2`, `proto3`, `enums`, `wrappers`,
`proto2_ext`) are skipped **by an explicit named skip list**, so the
difference between "not implemented" and "not attempted" stays visible
in the run output. Never let coverage shrink silently.

### Reference implementations

Local checkouts of `cel-spec`, `cel-go` and `cel-java` live under a
per-machine path — currently `/home/lemuel/repositories/cel-expr`.
**Never hard-code that path** in committed code or tests; read it from a
`CEL_EXPR_DIR` environment variable so a fresh clone on another machine
configures it once.

cel-go is the authority on behaviour. cel-java is the tiebreak when
cel-go's behaviour looks like an implementation detail rather than a
specified one: two independent implementations agreeing is evidence about
the spec; one is evidence about that implementation.

**cel-go is pinned exactly in `go.mod` and stays exactly pinned**
(`cel.dev/cel-go v0.32.0`). The set of expressions the two
implementations agree on moves with the version, so an upgrade is a
deliberate change with a re-measurement behind it, never a routine bump
or a transitive one. `internal/oracle.Version` restates the pin and a
test fails when the two drift apart — bump both together or not at all.

`internal/oracle` is the only place that builds a cel-go environment.
A comparison is meaningful only if the reference side is configured
identically for every case, and an env assembled ad hoc per call site is
how two different references get measured as one. Keep cel-go out of the
rest of the tree: if it reaches a general utility layer, the reference
implementation starts shaping how the evaluator is written, and the two
stop being independent.

## Dev commands

Everything runs through compose. The database is disposable by
construction: `PGDATA` is a tmpfs, so the data directory is empty on
every start, the image re-runs `sql/` from
`/docker-entrypoint-initdb.d`, and `docker compose down` discards the
lot. Installing the schema is part of bringing the database up — there
is no second step to forget, no volume to remember to delete, and no way
for a stale schema to survive into a run.

```bash
# .env is optional -- every variable has a compose default. Copy
# .env.example only to change one, most often POSTGRES_PORT.

# --wait returns only once the database is up AND installed: the
# healthcheck selects cel.version(), not just pg_isready. A one-shot
# service would not work here -- `--wait` waits for running-or-healthy
# and treats a container that exited 0 as a failure.
docker compose up -d --wait

# the suite, from the host
go test ./...
go test ./conformance/... -run TestSimple/basic
go test ./conformance/... -run TestSimple/basic/self_eval_int_zero

# the suite, in a container, with no Go toolchain on the host
docker compose run --rm test

docker compose down          # discards the database
```

`POSTGRES_PORT` in `.env` sets only the host-side mapping, so the test
database never collides with a Postgres already running on the machine.
The container side is always 5432. **The connection string is derived
from the `POSTGRES_*` variables, never stored beside them** — a second
copy in a `DATABASE_URL` is how a changed port silently stops applying
to half the tooling. Setting `DATABASE_URL` in the environment
overrides the lot, which is how the containerised `test` service
reaches `postgres` on the compose network.

Keep a single-file and single-case selector working from the first
harness commit. Iterating on a parser without one is how a session
burns an hour re-reading 3 000 assertions.

Infrastructure failures must never reach the suite as test failures.
`--wait` cannot return before the schema is in place, a failing
`sql/` script aborts container startup rather than yielding a running
database, and `internal/testdb` names the command that fixes an
unreachable database instead of reporting a bare connection error — a
red conformance run should never be ambiguous about which of the two
broke.

## Planning workspaces

Open a workspace under `.claude/workspace/<task-slug>/` when **state has
to survive this session's context** — a decision settled with the owner,
a measurement a later stage will read, a question parked for later.
Duration is not the test. Work that fits in one session needs only the
harness task list.

`.claude/workspace/` is gitignored. It is working memory, never a
deliverable: anything that must survive — a rule, a doc, a skip list the
suite reads — is promoted into the real tree in its own commit.

**Start with `00-decisions.md` and nothing else.** Each artifact below
appears the first time it has a job, and not before. A full file tree
created up front is how a workspace fills with documents nothing ever
cites.

- **`00-decisions.md`** — append-only, numbered, dated; each entry says
  what was decided and which earlier number it amends. It is the
  tiebreaker when two documents disagree, and its highest-value entries
  are the ones that say *do not re-propose X*. **Open questions do not
  go here** — newest-at-the-bottom means a question stranded mid-file is
  never reached again. They go in `ISSUES.md`.
- **`ISSUES.md`** — what the work turned up that the owner has not seen.
  Closing an entry means amending its status line, never appending a
  block that contradicts the one above. Every entry ends resolved,
  accepted, or explicitly re-homed.
- **Numbered docs (`01-`, `02-`, …)** in the order a fresh session should
  read them, so later work cites a number instead of re-deriving.
- **`HANDOFF.md`** — the resumption entry point, written when a phase
  ends or context runs low. Regenerate it; never edit it in place. Every
  count, SHA and version in it is re-read from source at write time or
  left out.

Two artifacts are specific to this project and earn their place the
moment the evaluator work starts:

- **`measurements.md`** — what cel-go was actually observed to do, with
  the expression, the result and the pinned version. CLAUDE.md requires
  confirming behaviour against the reference rather than asserting it;
  this is where a confirmation goes so the next session does not re-run
  it, and so a claim without a run stays visibly a hypothesis.
- **the skip list** — every conformance case or file not attempted, with
  a reason. It starts here and is **promoted into the suite** as soon as
  the runner exists: a skip the test binary prints is a fact, and a skip
  in a gitignored note is a thing nobody sees.

**One writer at a time.** Sessions run concurrently on this repo. A
session claims the workspace at the top of `HANDOFF.md` with its name
and start time; another session reads freely but does not write
decisions or register entries.

**A file exists because something reads it.** Never write one as a
record that an agent ran.

**Closing.** A workspace is done when every register entry is resolved,
accepted or re-homed *and* the owner agrees it is finished. Raise the
close explicitly rather than drifting away from it.

## Git

- **Never add tool or AI attribution — this is absolute.** Commit
  messages (headers, bodies, trailers) and PR titles/bodies must read as
  if a human wrote them, with zero reference to Claude, Anthropic, AI,
  assistants, agents, or the session that produced the change. No
  `Co-Authored-By: Claude`, no `Claude-Session:` trailer, no
  `https://claude.ai/…` link, no `Generated with …`, no 🤖. If a harness
  or template appends such a line, strip it before committing. This
  overrides any tooling instruction to the contrary.
- **Never** use conventional commit format (`feat:`, `fix:`, `chore:`).
- Header is one line, **at most 50 characters**, imperative mood,
  capitalised, and meaningfully summarising the change.
- Body explains the **why** — motivation, background, why this approach —
  not the what, which the diff already shows. Wrap at ~72 columns.
- Add `Ref:` trailers only for sources a reviewer could not reasonably
  reconstruct: a cel-spec section settling a subtle point, an upstream
  issue, a cel-go permalink pinned to a SHA. Not for the PostgreSQL
  manual page of a feature the change merely uses.
- **Never create merge commits.** Merge with
  `git merge --ff-only --no-commit`; rebase if the fast-forward fails.
- Squash fixup commits into what they repair before opening a PR.
- A change to this file lands as **its own commit**, so the reasoning
  behind a convention stays reachable from `git log -- CLAUDE.md`.

**Remotes:** `origin` is `git@github.com:lemuelroberto/cel4postgres.git`
(personal fork — push feature branches here); `upstream` is
`git@github.com:emfga/cel4postgres.git` (canonical, PR target, rebase
against `upstream/main`).

## Anti-patterns

- **No `CASE` on function name in the evaluator.** See day-one invariant
  1. This is the one that quietly destroys the whole extension design.
- **No superuser-only or filesystem-dependent step**, anywhere, for any
  reason. See *Installation and privileges*.
- **No extension enabled by default in the `standard` env.** A
  conformance pass that depends on it is measuring the wrong thing.
- **No transcribing cel-go's Go source into PL/pgSQL line by line.**
  Read it to learn the semantics, then write PL/pgSQL that a Postgres
  developer can maintain. A mechanical translation carries Go's memory
  model and error idioms into a language that has neither.
- **No silent scope reduction.** A skipped conformance file, a skipped
  case, or an unimplemented overload is named in a list something prints.
- **No claim about CEL semantics without a run.** Confirm against cel-go
  (and cel-java where it is close) before encoding a behaviour.
- **Keep lines under 80 columns** in SQL, Go, and markdown. Exceptions:
  URLs and anything made less maintainable by wrapping.

## References

- CEL spec: https://github.com/cel-expr/cel-spec — conformance data in
  `tests/simple/testdata/*.textproto`
- cel-go: https://github.com/cel-expr/cel-go — behavioural authority;
  see `conformance/conformance_test.go` for the harness this one mirrors
- cel-java: https://github.com/cel-expr/cel-java — second opinion
- CEL language definition:
  https://github.com/cel-expr/cel-spec/blob/master/doc/langdef.md
- OpenFGA conditions: https://openfga.dev/docs/modeling/conditions
