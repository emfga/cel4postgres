-- cel4postgres -- install script.
--
-- Idempotent, and installable by any role that owns (or may create)
-- the cel schema. Nothing here requires superuser, a filesystem, or
-- a server restart: see CLAUDE.md, "Installation and privileges".
--
-- Run with:  psql -v ON_ERROR_STOP=1 -f sql/install.sql

BEGIN;

CREATE SCHEMA IF NOT EXISTS cel;

-- We have no pg_extension row to carry a version, so the schema
-- carries its own. Upgrade scripts append a row; nothing rewrites
-- history.
CREATE TABLE IF NOT EXISTS cel.schema_version (
  version     text        NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (version)
);

INSERT INTO cel.schema_version (version)
VALUES ('0.0.0')
ON CONFLICT (version) DO NOTHING;

-- The installed schema version. IMMUTABLE is deliberately wrong for
-- this one -- it reads a table -- so it is STABLE, and it is the only
-- function in cel that will ever read one.
CREATE OR REPLACE FUNCTION cel.version()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = cel, pg_temp
AS $$
  SELECT version
  FROM cel.schema_version
  ORDER BY applied_at DESC, version DESC
  LIMIT 1;
$$;

COMMIT;
