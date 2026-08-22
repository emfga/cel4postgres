# cel4postgres

> CEL, natively in Postgres: a zero-dependency PL/pgSQL evaluator for
> Google's Common Expression Language.

**Status: scaffolding.** The development environment, the schema
installer and the test harness exist and are green. The evaluator does
not — there is no parser, checker or evaluator yet, and nothing reads
the [cel-spec][cel-spec] conformance corpus. See [CLAUDE.md](CLAUDE.md)
for the design the next commits are building toward.

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
docker compose exec postgres psql -U cel -d cel -c 'SELECT cel.version()'
```

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
go test ./... -v -run TestSchemaInstalled
```

Both paths run the same tests against the same database.

## Installing into your own database

The `sql/` scripts are ordinary, idempotent SQL, ordered by their
numeric prefix. Nothing about them is specific to the compose setup:

```bash
for f in sql/*.sql; do
  psql -v ON_ERROR_STOP=1 -f "$f" "$YOUR_DATABASE_URL"
done
```

It needs a role that may create the `cel` schema. It does not need
superuser.

## Scope

Targeting the cel-spec core language over JSON-representable types, plus
the well-known types (`Timestamp`, `Duration`, `Any`, `Struct`). The
protobuf message surface — message construction, field presence, enums,
wrapper types — is out of scope.

Extension libraries (`strings`, `math`, `lists`, `sets`, `encoders`,
`bindings`, `optionals`) and the OpenFGA dialect (`ipaddress`,
`in_cidr`) are not enabled by default; they register into the evaluator
rather than modifying it, and consumers will be able to register their
own the same way.

Conformance is measured against the [cel-spec][cel-spec] corpus with
[cel-go][cel-go] as the behavioural reference, pinned at `v0.32.0`. The
target is 100% of what is in scope, with anything skipped named
explicitly rather than quietly dropped.

The pin is exact and deliberate: which expressions the two
implementations agree on moves with the cel-go version, so upgrading it
means re-measuring conformance, not bumping a dependency.

## References

- [cel-spec][cel-spec] — the specification and the conformance corpus
- [cel-go][cel-go] — the reference implementation
- [CEL language definition][langdef]

[cel]: https://cel.dev/
[cel-spec]: https://github.com/cel-expr/cel-spec
[cel-go]: https://github.com/cel-expr/cel-go
[langdef]: https://github.com/cel-expr/cel-spec/blob/master/doc/langdef.md
