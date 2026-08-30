#!/usr/bin/env sh
# Build the release artifacts into dist/.
#
# The version has one home: the row 000_install.sql seeds into
# cel.schema_version. This script reads it from there rather than
# keeping a copy that could drift.
#
# Three granularities, per the distribution decision: an all-in
# bundle, a core-only file (000-070), and one file per extension
# library (100-170). Plain concatenation is safe because every
# sql/ script opens and closes its own transactions. Install with
# ON_ERROR_STOP so a failure stops between them:
#
#   psql -v ON_ERROR_STOP=1 -f cel4postgres--<version>.sql

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

rm -rf dist
mkdir -p dist

# Concatenate the named files, each behind a banner naming its
# source, so an error line in a bundle is traceable to a script.
bundle() {
  out=$1
  shift
  for f in "$@"; do
    printf -- '-- ---- %s ----\n\n' "$f"
    cat "$f"
    printf '\n'
  done >"dist/$out"
}

core=$(ls sql/0[0-9][0-9]_*.sql)
exts=$(ls sql/1[0-9][0-9]_*.sql)

# shellcheck disable=SC2086
bundle "cel4postgres--$version.sql" $core $exts
# shellcheck disable=SC2086
bundle "cel4postgres-core--$version.sql" $core
for f in $exts; do
  name=$(basename "$f" .sql | sed 's/^[0-9]*_//')
  bundle "cel4postgres-$name--$version.sql" "$f"
done

(cd dist && sha256sum -- *.sql >SHA256SUMS)

echo "version $version"
ls -l dist
