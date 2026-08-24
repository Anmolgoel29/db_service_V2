#!/usr/bin/env bash
# Runs once, on the first boot of an empty data directory.
#
# Everything in here is idempotent so `./dbctl.sh bootstrap` can replay it
# against an instance that already has data (e.g. one created before this file
# existed). The password is passed as a psql variable and quoted with %L rather
# than pasted into the SQL text, so an awkward character in it cannot break out.
set -euo pipefail

: "${PGBACKWEB_DB_PASSWORD:?PGBACKWEB_DB_PASSWORD not passed to the postgres container}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres \
     -v pbwpass="$PGBACKWEB_DB_PASSWORD" <<-'EOSQL'
	-- PG Back Web's own metadata: schedules, destinations, backup history.
	SELECT format('CREATE ROLE pgbackweb LOGIN PASSWORD %L', :'pbwpass')
	 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbackweb')
	\gexec

	-- keeps the role's password in sync with .env on a replay
	SELECT format('ALTER ROLE pgbackweb LOGIN PASSWORD %L', :'pbwpass')
	\gexec

	SELECT 'CREATE DATABASE pgbackweb OWNER pgbackweb'
	 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'pgbackweb')
	\gexec

	-- Tenants must not be able to open each other's databases. A fresh database
	-- grants CONNECT to PUBLIC by default; take it back.
	REVOKE ALL ON DATABASE pgbackweb FROM PUBLIC;
	REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
	GRANT ALL PRIVILEGES ON DATABASE pgbackweb TO pgbackweb;

	REVOKE CREATE ON SCHEMA public FROM PUBLIC;
EOSQL

# New databases are cloned from template1, so fix its ACL once, here.
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname template1 <<-'EOSQL'
	REVOKE CREATE ON SCHEMA public FROM PUBLIC;
EOSQL

echo "farm bootstrap: pgbackweb role + database ready"
