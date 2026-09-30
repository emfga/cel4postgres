#!/usr/bin/env sh
# Build the release artifacts into dist/.
#
# The version has one home: the row 000_install.sql seeds into
# cel.schema_version. This script reads it from there rather than
# keeping a copy that could drift.
#
# Three granularities, per the distribution decision: an all-in
# bundle, a core-only file (000-070), and one file per extension
# library (100-170).
#
# Each comes in two shapes. The plain file carries no transaction
# control, so it runs inside whatever transaction the caller already
# holds -- a migration tool's, pg_tle's CREATE EXTENSION, or psql's
# --single-transaction:
#
#   psql -v ON_ERROR_STOP=1 -1 -f cel4postgres--<version>.sql
#
# The -tx file is the same bundle between exactly one BEGIN; and one
# COMMIT;, for a plain `psql -f` that should still be all or nothing.

set -eu

cd "$(dirname "$0")/.."

version=$(sed -n "s/^VALUES ('\([0-9][0-9.]*\)')$/\1/p" \
  sql/000_install.sql)
case $version in
  *.*.*) ;;
  *)
    echo "could not read the version from sql/000_install.sql" >&2
    exit 1
    ;;
esac

# The sources carry no transaction control; that is what lets the
# plain artifacts run inside a caller's transaction. A BEGIN; or
# COMMIT; line reappearing in sql/ would silently commit that
# transaction halfway, so refuse to build rather than ship it.
if grep -n -x -e 'BEGIN;' -e 'COMMIT;' sql/*.sql; then
  echo "sql/ must not open or close transactions" >&2
  exit 1
fi

rm -rf dist
mkdir -p dist

# Concatenate the named files, each behind a banner naming its
# source, so an error line in a bundle is traceable to a script.
# Writes <name>--<version>.sql and its <name>-tx--<version>.sql
# twin.
bundle() {
  name=$1
  shift
  for f in "$@"; do
    printf -- '-- ---- %s ----\n\n' "$f"
    cat "$f"
    printf '\n'
  done >"dist/$name--$version.sql"
  {
    printf 'BEGIN;\n\n'
    cat "dist/$name--$version.sql"
    printf 'COMMIT;\n'
  } >"dist/$name-tx--$version.sql"
}

core=$(ls sql/0[0-9][0-9]_*.sql)
exts=$(ls sql/1[0-9][0-9]_*.sql)

# shellcheck disable=SC2086
bundle cel4postgres $core $exts
# shellcheck disable=SC2086
bundle cel4postgres-core $core
for f in $exts; do
  name=$(basename "$f" .sql | sed 's/^[0-9]*_//')
  bundle "cel4postgres-$name" "$f"
done

(cd dist && sha256sum -- *.sql >SHA256SUMS)

echo "version $version"
ls -l dist
