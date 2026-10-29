#!/usr/bin/env sh
# Upgrade a database from the previous release to this checkout's
# build, and leave it running for the conformance suite.
#
#   upgrade-check.sh <plain|pgtle> <image> <prev-dir> <port>
#
# <prev-dir> holds the previous release's published artifacts
# (cel4postgres--<prev>.sql and SHA256SUMS, verified here); dist/
# holds this checkout's, from scripts/build-release.sh. <image> is
# the pinned postgres image for plain, the pg_tle image for pgtle.
#
# Each channel installs N-1 the way a consumer did, registers a
# consumer overload of its own, runs the upgrade, and asserts that
# the schema reports the new version and the consumer row both
# survived and still evaluates. The caller then runs the suite
# against 127.0.0.1:<port> -- an upgraded database has to be as
# conformant as a fresh one -- and removes the container, named
# cel-upgrade-<channel>.
#
# The upgrade itself is the new installer run over the old schema:
# the installer is idempotent and resyncs every row it ships. A
# release that needs drops or signature changes ships a delta script
# that runs first; none exists yet.

set -eu

cd "$(dirname "$0")/.."

channel=$1
image=$2
prev_dir=$3
port=$4

version() {
  sed -n "s/^VALUES ('\([0-9][0-9.]*\)')$/\1/p" "$1"
}

head=$(version sql/000_install.sql)
prev_file=$(ls "$prev_dir"/cel4postgres--*.sql)
prev=$(basename "$prev_file" .sql | sed 's/^cel4postgres--//')
head_file="dist/cel4postgres--$head.sql"

(cd "$prev_dir" && sha256sum --check --ignore-missing SHA256SUMS)
[ -f "$head_file" ] || {
  echo "$head_file is missing; run scripts/build-release.sh" >&2
  exit 1
}

echo "upgrade $prev -> $head through the $channel channel"

if [ "$prev" = "$head" ] && [ "$channel" = pgtle ]; then
  # pg_tle has no update path from a version to itself. Say so in
  # the log instead of passing quietly: this happens only between a
  # release and the commit that numbers the next one.
  echo "::warning::$head is already released; nothing to upgrade" \
    "through pg_tle until sql/000_install.sql is renumbered"
fi

name="cel-upgrade-$channel"
docker rm -f "$name" >/dev/null 2>&1 || true

args=
[ "$channel" = pgtle ] && args='-c shared_preload_libraries=pg_tle'
# shellcheck disable=SC2086
docker run -d --name "$name" \
  -e POSTGRES_DB=cel -e POSTGRES_USER=cel -e POSTGRES_PASSWORD=pw \
  -p "127.0.0.1:$port:5432" "$image" $args >/dev/null

# -h 127.0.0.1: over the socket, pg_isready can reach initdb's
# temporary server; only the final one listens on TCP.
for _ in $(seq 60); do
  docker exec "$name" pg_isready -h 127.0.0.1 -U cel -d cel -q \
    2>/dev/null && break
  sleep 2
done

sql() {
  docker exec -i -e PGOPTIONS='-c client_min_messages=warning' \
    "$name" psql -h 127.0.0.1 -U cel -d cel -v ON_ERROR_STOP=1 \
    -q "$@"
}

expect() {
  got=$(sql -tAc "$1")
  if [ "$got" != "$2" ]; then
    echo "$1" >&2
    echo "  returned: $got" >&2
    echo "  expected: $2" >&2
    exit 1
  fi
}

# -- install N-1 -----------------------------------------------------

case $channel in
  plain)
    sql -1 -f - <"$prev_file"
    ;;
  pgtle)
    sql -c 'CREATE EXTENSION pg_tle'
    ./scripts/pgtle-wrap.sh cel4postgres "$prev" "$prev_file" | sql -f -
    sql -c "CREATE EXTENSION cel4postgres VERSION '$prev'"
    ;;
  *)
    echo "unknown channel $channel" >&2
    exit 1
    ;;
esac
expect 'SELECT cel.version()' "$prev"

# -- a consumer registration the upgrade must not touch -------------
#
# Its own schema, its own env, an overload id the installer never
# ships: everything an upgrade has to leave alone.

sql <<'SQL'
CREATE SCHEMA consumer;

CREATE FUNCTION consumer.shout(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', upper(args[1] ->> 'v'));
$$;

INSERT INTO cel.env (name) VALUES ('consumer');

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('consumer_shout_string', 'shout', false, '[{"kind": "string"}]',
   '{"kind": "string"}', 'consumer.shout(jsonb[])', 10);

INSERT INTO cel.env_item (env, kind, ref)
VALUES ('consumer', 'overload', 'consumer_shout_string');
SQL

probe="SELECT cel.evaluate('shout(\"cel\")', '{}', 'standard,consumer')"
want='{"v": "CEL", "@t": "string"}'
expect "$probe" "$want"

# -- upgrade --------------------------------------------------------

case $channel in
  plain)
    sql -1 -f - <"$head_file"
    ;;
  pgtle)
    if [ "$prev" != "$head" ]; then
      ./scripts/pgtle-wrap.sh --update-from "$prev" \
        cel4postgres "$head" "$head_file" | sql -f -
      sql -c "ALTER EXTENSION cel4postgres UPDATE TO '$head'"
    fi
    expect "SELECT extversion FROM pg_extension
            WHERE extname = 'cel4postgres'" "$head"
    ;;
esac

expect 'SELECT cel.version()' "$head"
expect "SELECT count(*) FROM cel.overload
        WHERE id = 'consumer_shout_string'" 1
expect "$probe" "$want"

echo "upgraded $prev -> $head; consumer registration intact"
