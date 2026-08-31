# Installing cel4postgres

cel4postgres installs by running SQL against a database you can
already connect to. There is nothing to compile, no server package,
no filesystem access and no restart — which is what lets it install
on managed PostgreSQL (AWS RDS, Aurora) exactly as on a self-hosted
server. It is developed and tested against PostgreSQL 18.

Two install channels exist:

- **Plain SQL** — `psql -f` of a release artifact. Works anywhere,
  needs only a role that may create the `cel` schema.
- **pg_tle** — on platforms that offer [pg_tle][pg_tle] (RDS,
  Aurora), the same artifact registers as a real extension:
  `CREATE EXTENSION cel4postgres`, version visible in `\dx`, clean
  `DROP EXTENSION`.

## Getting the files

Download from the [releases page][releases]:

| File | Contents |
|---|---|
| `cel4postgres--<version>.sql` | everything: core + all extensions |
| `cel4postgres-core--<version>.sql` | core only (`cel.evaluate`, standard library, well-known types) |
| `cel4postgres-ext_<name>--<version>.sql` | one extension library |
| `SHA256SUMS` | checksums for all of the above |

Verify downloads before running them:

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

Extension libraries install into the same schema and are visible
only under their own environment name (`strings`, `math`, `lists`,
`encoders`, `bindings`, `optionals`, `two_var_comprehensions`,
`network`) — installing all of them changes nothing for callers
that use the `standard` environment. Extension files require the
core to be installed first.

From a checkout instead, `./scripts/build-release.sh` produces the
same files under `dist/`.

## Self-hosted PostgreSQL

Run the artifact as a role that may create the `cel` schema —
the database owner is enough; superuser is not needed:

```bash
psql -v ON_ERROR_STOP=1 "$DATABASE_URL" \
  -f cel4postgres--<version>.sql
```

Then verify:

```sql
SELECT cel.version();
SELECT cel.evaluate('1 + 2', '{}', 'standard');
-- {"v": 3, "@t": "int"}
```

To uninstall: `DROP SCHEMA cel CASCADE;`

## AWS RDS and Aurora

### Plain SQL (no prerequisites)

The self-hosted instructions above work unchanged: connect as the
master user (or any role with `CREATE` on the database) and run the
artifact. No parameter group changes, no reboot.

### As an extension, via pg_tle

[pg_tle][pg_tle] (Trusted Language Extensions) is AWS's mechanism
for installing extensions without filesystem access. It gets you
real extension semantics: the version shows in `\dx`, and
`DROP EXTENSION cel4postgres` removes everything cleanly. This
path is validated in CI against pg_tle v1.5.2 for every release.

One-time instance setup (this part needs a reboot; see the
[AWS documentation][aws-tle]):

1. In the instance's DB parameter group, add `pg_tle` to
   `shared_preload_libraries`, and reboot.
2. As the master user:

   ```sql
   CREATE EXTENSION pg_tle;
   GRANT pgtle_admin TO <your_master_user>;
   ```

Then register and install cel4postgres. The artifact is wrapped
into a `pgtle.install_extension` call by a script from this
repository (it strips top-level transaction statements, which are
not allowed inside `CREATE EXTENSION`):

```bash
./scripts/pgtle-wrap.sh cel4postgres <version> \
  cel4postgres--<version>.sql > cel4postgres.pgtle.sql

psql -v ON_ERROR_STOP=1 "$DATABASE_URL" \
  -f cel4postgres.pgtle.sql \
  -c 'CREATE EXTENSION cel4postgres;'
```

To install the core plus a subset of extensions, pass the core
file followed by the chosen extension files to `pgtle-wrap.sh`
instead of the all-in bundle.

To uninstall:

```sql
DROP EXTENSION cel4postgres;
SELECT pgtle.uninstall_extension('cel4postgres');
```

## Access control

The installing role owns everything and is the only one that can
write the registry tables — which is the security boundary: whoever
can write `cel.overload` decides what the evaluator dispatches to.
Application roles get evaluation and read-only registry access.
For each application role:

```sql
GRANT USAGE ON SCHEMA cel TO <app_role>;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cel TO <app_role>;
GRANT SELECT ON cel.type, cel.overload, cel.macro,
                cel.env, cel.env_item, cel.schema_version
  TO <app_role>;
```

All three grants are required: evaluation runs `SECURITY INVOKER`,
so the calling role itself executes the internal functions and
reads the registry tables. The role still cannot register anything
— registry writes stay owner-only.

## Versions and upgrading

`SELECT cel.version()` reports the installed version, recorded in
`cel.schema_version` at install time.

There is no in-place upgrade path yet: moving to a new version
means uninstalling and installing the new artifact. Note that this
also removes anything you registered in the registry tables
yourself — re-register after reinstalling.

[releases]: https://github.com/emfga/cel4postgres/releases
[pg_tle]: https://github.com/aws/pg_tle
[aws-tle]: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL_trusted_language_extension.html
