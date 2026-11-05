#!/bin/sh
set -e

# docker-lab/scripts/init-postgres.sh
# Creates secondary databases and users for external services (SonarQube, GitLab)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Database for SonarQube
    SELECT 'CREATE DATABASE sonar' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'sonar')\gexec
    GRANT ALL PRIVILEGES ON DATABASE sonar TO $POSTGRES_USER;

    -- Database for GitLab (if external database is configured)
    SELECT 'CREATE DATABASE gitlabhq_production' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gitlabhq_production')\gexec
    GRANT ALL PRIVILEGES ON DATABASE gitlabhq_production TO $POSTGRES_USER;

    -- Database for Keycloak / Vault backend
    SELECT 'CREATE DATABASE keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
    GRANT ALL PRIVILEGES ON DATABASE keycloak TO $POSTGRES_USER;
EOSQL

