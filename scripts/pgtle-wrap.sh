#!/usr/bin/env sh
# Wrap release artifacts into a pg_tle registration script, so the
# flagship channel (CREATE EXTENSION via pg_tle) can be validated
# against the exact files a release publishes. Validation-only:
# the output is generated where needed, never published.
#
#   pgtle-wrap.sh <extname> <version> <artifact.sql>... > out.sql
#   pgtle-wrap.sh --update-from <old> <extname> <version> \
#     <artifact.sql>... > out.sql
#
# The first form registers <version> for CREATE EXTENSION; the
# second registers the <old> -> <version> update path for ALTER
# EXTENSION ... UPDATE. The update script is the same bundle: the
# installer is idempotent and resyncs what it ships.
#
# The artifacts run unchanged. Pass the plain ones, never a -tx
# twin: a pg_tle script executes inside CREATE EXTENSION's own
# transaction, where transaction control is not allowed.

set -eu

from=
if [ "$1" = --update-from ]; then
  from=$2
  shift 2
fi

name=$1
version=$2
shift 2

tag='_cel_pgtle_'
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cat -- "$@" >"$tmp"

if grep -q -x -e 'BEGIN;' -e 'COMMIT;' "$tmp"; then
  echo "input controls transactions; pass the plain artifacts," \
    "not the -tx ones" >&2
  exit 1
fi

# The bundle becomes one dollar-quoted literal; the quoting breaks
# if its tag ever appears in the content, so refuse instead of
# emitting a script that fails somewhere deep in pg_tle.
if grep -qF "\$$tag\$" "$tmp"; then
  echo "dollar-quote tag \$$tag\$ appears in the input" >&2
  exit 1
fi

if [ -n "$from" ]; then
  printf "SELECT pgtle.install_update_path(\n"
  printf "  '%s',\n  '%s',\n  '%s',\n" "$name" "$from" "$version"
else
  printf "SELECT pgtle.install_extension(\n"
  printf "  '%s',\n  '%s',\n  'CEL for PostgreSQL',\n" \
    "$name" "$version"
fi
printf '$%s$\n' "$tag"
cat "$tmp"
printf '$%s$\n);\n' "$tag"
