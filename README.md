# cel4postgres

> CEL, natively in Postgres: a zero-dependency PL/pgSQL evaluator for
> Google's Common Expression Language.

**Status: the evaluator is complete and the in-scope conformance
corpus is green.** Parser, checker and evaluator install as plain SQL,
with the standard library, the well-known types and eight extension
libraries. Every in-scope case of the [cel-spec][cel-spec] corpus
passes on a fresh install, with nothing omitted silently — see
[docs/CONFORMANCE.md](docs/CONFORMANCE.md) for what that claim covers
and [the generated report](docs/conformance-report.md) for the
numbers.

## Why

[CEL][cel] is a small, non-Turing-complete expression language designed
to be embedded — policy conditions, validation rules, feature gates.
Evaluating it usually means shipping the data to an application. This
project evaluates it where the data already is.

*Zero-dependency* is a hard constraint, not a slogan: cel4postgres
installs as plain SQL scripts into a schema. No compiled extension, no
shared library, no procedural language beyond `plpgsql`. That means it
installs on a managed database — RDS, Aurora, Cloud SQL — with no
superuser, no filesystem access and no restart, which a `CREATE
EXTENSION` package fundamentally cannot do.

## Quick start

The only prerequisite is Docker.

```bash
docker compose up -d
```

That is the whole setup. It starts PostgreSQL 18 and installs the `cel`
schema into it. The container reports healthy only once the schema is
actually there, so when the command returns, the database is ready to
use:

```bash
docker compose exec postgres psql -U cel -d cel \
  -c "SELECT cel.evaluate('[1, 2, 3].exists(n, n % 2 == 0)', '{}', 'standard')"
```

```
         evaluate
---------------------------
 {"v": true, "@t": "bool"}
```

Values are tagged JSON in and out, and the third argument names the
environment. Expressions with free variables need those variables
declared, which means the staged form — `parse`, `check` with
declarations, `eval` with an activation:

```sql
SELECT cel.eval(
  cel.check(cel.parse('size(x) > 2', 'standard'), 'standard',
            '{"decls": [{"name": "x", "type": {"kind": "string"}}]}'),
  '{"x": {"@t": "string", "v": "abc"}}', 'standard');
```

Every stage is pure — nothing writes, so all of them work on standbys
and in read-only transactions, and a compiled AST can be cached in a
table of your own. `parse` is `IMMUTABLE`; `check`, `eval` and
`evaluate` are `STABLE`, since they read the registry. All are
`PARALLEL SAFE`.

Run the test suite — no Go toolchain needed on your machine:

```bash
docker compose run --rm test
```

And tear it down:

```bash
docker compose down
```

## The database is disposable

`PGDATA` is a tmpfs. The data directory is empty on every start, so the
schema is reinstalled from `sql/` on every start, and `docker compose
down` discards everything. There is no volume to clean up and no way for
a stale schema to survive into a test run — if you want a clean
database, you already have one.

This database exists only to test against. Do not put anything in it you
would miss.

## Configuration

Everything has a working default, so `.env` is optional. Copy
`.env.example` to `.env` when you need to change something — most often
the port, if PostgreSQL is already running on your machine:

```bash
cp .env.example .env
$EDITOR .env          # POSTGRES_PORT=5433
```

| Variable | Default | Notes |
|---|---|---|
| `POSTGRES_PORT` | `5432` | Host side only; the container is always 5432 |
| `POSTGRES_DB` | `cel` | |
| `POSTGRES_USER` | `cel` | |
| `POSTGRES_PASSWORD` | `password` | Test database; it is not a secret |
| `PREFIX` | `cel4postgres` | Container and network name prefix |

The test harness builds its connection string from these rather than
keeping a second copy in a `DATABASE_URL`, so changing the port here
changes it everywhere. Setting `DATABASE_URL` in the environment
overrides all of them.

## Developing with a local Go toolchain

The containerised suite is the reference, but running the tests directly
is faster to iterate on. Go 1.26 or newer:

```bash
docker compose up -d
go test ./...
go test ./conformance/... -run TestSimple/basic
go test ./conformance/... -run TestSimple/basic/self_eval_zeroish/self_eval_int_zero
```

Both paths run the same tests against the same database. The
conformance suite reads the corpus from a local cel-spec checkout
named by `CEL_EXPR_DIR`, and regenerating the report after a change
is one command:

```bash
go run ./internal/cmd/confreport
```

## Installing into your own database

The `sql/` scripts are ordinary, idempotent SQL, ordered by their
numeric prefix. Nothing about them is specific to the compose setup:

```bash
for f in sql/*.sql; do
  psql -v ON_ERROR_STOP=1 -f "$f" "$YOUR_DATABASE_URL"
done
```

It needs a role that may create the `cel` schema. It does not need
superuser. [docs/INSTALL.md](docs/INSTALL.md) is the full guide:
release artifacts and their checksums, self-hosted and AWS
RDS/Aurora instructions — including installing as a real extension
via [pg_tle](https://github.com/aws/pg_tle) — and the grants an
application role needs.

## Scope

The cel-spec core language over JSON-representable types, plus the
well-known types — `Timestamp`, `Duration`, `Any`, `Struct`, `Value`,
`ListValue` and the `Int32Value`-family wrappers, all of which are
JSON-shaped and need no descriptor pool. The rest of the protobuf
message surface — message construction, field presence, enums — is out
of scope: it needs descriptors inside PostgreSQL and buys nothing for
the JSON-shaped data this targets.

The extension libraries (`strings`, `math`, `lists`, `encoders`,
`bindings`, `optionals`, two-variable comprehensions, `network`) are
implemented, each behind its own environment name and none enabled by
default. They register into the evaluator rather than modifying it, and
consumers can register their own the same way.

Conformance is measured against the [cel-spec][cel-spec] corpus with
[cel-go][cel-go] as the behavioural reference, both pinned exactly:
which expressions two implementations agree on moves with the version
of either, so an upgrade re-measures conformance rather than bumping a
dependency. [docs/CONFORMANCE.md](docs/CONFORMANCE.md) states what is
excluded and every place cel4postgres deliberately answers differently
from cel-go; [docs/conformance-report.md](docs/conformance-report.md)
is generated from a run and lists every case not attempted, by name.

## References

- [cel-spec][cel-spec] — the specification and the conformance corpus
- [cel-go][cel-go] — the reference implementation
- [CEL language definition][langdef]

[cel]: https://cel.dev/
[cel-spec]: https://github.com/cel-expr/cel-spec
[cel-go]: https://github.com/cel-expr/cel-go
[langdef]: https://github.com/cel-expr/cel-spec/blob/master/doc/langdef.md
