#!/usr/bin/env bash
# ==============================================================================
# PostgreSQL 16 HA + Patroni + etcd + HAProxy + pgBackRest Installer (Ubuntu 24.04)
# Supports both 5-VM mode (2x pg-lb + 3x pg-db) and 1/3-VM mode (pg-db1..3)
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  # shellcheck disable=SC1090
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

PG_VER="${PG_VER:-16}"
NODE_NAME="$(hostname -s)"
NODE_IP="$(hostname -I | awk '{print $1}')"
PG_ADMIN_PASS="${PG_ADMIN_PASS:-ChangeMe_PostgresAdmin_2026!}"
PG_REPL_PASS="${PG_REPL_PASS:-ChangeMe_ReplPass_2026!}"

echo "[1/5] Installing PostgreSQL ${PG_VER}, Patroni, etcd, HAProxy, Keepalived, and pgBackRest..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "postgresql-${PG_VER}" "postgresql-client-${PG_VER}" "postgresql-contrib-${PG_VER}" \
  patroni etcd-server etcd-client haproxy keepalived \
  pgbackrest prometheus-postgres-exporter python3-psycopg2

echo "[2/5] Preparing PostgreSQL WAL, Patroni, and pgBackRest directories..."
# Stop default Debian/Ubuntu postgresql wrapper so Patroni manages the postgres instance
systemctl stop postgresql || true
systemctl disable postgresql || true
pg_dropcluster --stop "${PG_VER}" main 2>/dev/null || true

mkdir -p /var/lib/postgresql/wal /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest
chown -R postgres:postgres /var/lib/postgresql /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest
chmod 0700 /var/lib/postgresql/wal /var/lib/pgbackrest

echo "[3/5] Configuring etcd and Patroni (/etc/patroni/config.yml)..."
systemctl enable --now etcd

cat >/etc/patroni/config.yml <<EOF
scope: pg-ha-cluster
namespace: /service/
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts:
    - 127.0.0.1:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        archive_mode: "on"
        archive_timeout: 60s
        archive_command: "pgbackrest --stanza=main archive-push %p"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/${PG_VER}/patroni
  bin_dir: /usr/lib/postgresql/${PG_VER}/bin
  pgpass: /var/lib/postgresql/.pgpass_patroni
  authentication:
    replication:
      username: replicator
      password: "${PG_REPL_PASS}"
    superuser:
      username: postgres
      password: "${PG_ADMIN_PASS}"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

chown postgres:postgres /etc/patroni/config.yml
chmod 0600 /etc/patroni/config.yml
ln -sf /etc/patroni/config.yml /etc/patroni/patroni.yml

cat >/etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=7
process-max=2
start-fast=y

[main]
pg1-path=/var/lib/postgresql/${PG_VER}/patroni
pg1-port=5432
EOF
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

echo "[4/5] Configuring HAProxy Read-Only/Pool port (:5433) and starting Patroni..."
cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 1000
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    retries 3
    timeout queue   1m
    timeout connect 5s
    timeout client  30m
    timeout server  30m
    timeout check   2s

listen postgres_ro_pool
    bind *:5433
    mode tcp
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200
    default-server inter 2s fall 3 rise 2
    server ${NODE_NAME} ${NODE_IP}:5432 maxconn 300 check port 8008
EOF

ufw allow 5432/tcp comment 'PostgreSQL RW'
ufw allow 5433/tcp comment 'PostgreSQL RO via HAProxy'
ufw allow 8008/tcp comment 'Patroni REST API'
ufw allow 2379:2380/tcp comment 'etcd Quorum'
ufw allow 9187/tcp comment 'Prometheus Postgres Exporter'

systemctl daemon-reload
systemctl enable --now patroni haproxy prometheus-postgres-exporter
systemctl restart patroni haproxy

echo "[5/5] Waiting for Patroni Leader election and initializing pgBackRest stanza..."
for i in {1..15}; do
  if curl -fsS http://127.0.0.1:8008/health >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

sudo -u postgres pgbackrest --stanza=main stanza-create || true
patronictl -c /etc/patroni/config.yml list
echo "PostgreSQL 16 HA (Patroni :8008, RW :5432, RO :5433) and pgBackRest installation complete."
