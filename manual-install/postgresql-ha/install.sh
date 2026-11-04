#!/usr/bin/env bash
# ==============================================================================
# PostgreSQL 16 HA + Patroni + etcd + pgBackRest Installer (Ubuntu 24.04 LTS)
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

PG_VER="${PG_VER:-16}"

echo "[1/3] Installing PostgreSQL ${PG_VER}, Patroni, etcd, HAProxy, Keepalived, and pgBackRest..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "postgresql-${PG_VER}" "postgresql-client-${PG_VER}" "postgresql-contrib-${PG_VER}" \
  patroni etcd-server etcd-client haproxy keepalived \
  pgbackrest prometheus-postgres-exporter python3-psycopg2

echo "[2/3] Creating PostgreSQL WAL, Patroni, and pgBackRest directories..."
mkdir -p /var/lib/postgresql/wal /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest
chown -R postgres:postgres /var/lib/postgresql/wal /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest
chmod 0700 /var/lib/postgresql/wal /var/lib/pgbackrest

cat >/etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=7
process-max=2
start-fast=y

[main]
pg1-path=/var/lib/postgresql/${PG_VER}/main
pg1-port=5432
EOF
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

echo "[3/3] Opening UFW ports and verifying CLIs..."
ufw allow 5432/tcp comment 'PostgreSQL RW'
ufw allow 5433/tcp comment 'PostgreSQL RO'
ufw allow 8008/tcp comment 'Patroni REST API'
ufw allow 2379:2380/tcp comment 'etcd Quorum'
ufw allow 9187/tcp comment 'Prometheus Postgres Exporter'

systemctl enable --now postgresql prometheus-postgres-exporter
psql --version
patronictl version
pgbackrest version
echo "PostgreSQL 16 HA and pgBackRest CLI installation complete."

