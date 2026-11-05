#!/usr/bin/env bash
# ==============================================================================
# PostgreSQL 16 HA Installer (Ubuntu 24.04): Patroni + 3-node etcd + pgBackRest
# on the DB nodes, HAProxy + Keepalived (VIP) on the LB nodes.
#
# Topology (see README.md):
#   pg-lb1 / pg-lb2   -> role "lb": HAProxy (:5432 primary, :5433 replicas) + Keepalived VIP
#   pg-db1..pg-db3    -> role "db": etcd voter + Patroni + PostgreSQL + pgBackRest
#
# The role and node index are detected by matching this host's IP against
# PG_LB1_IP/PG_LB2_IP/PG_DB1_IP/PG_DB2_IP/PG_DB3_IP (platform.env), or forced
# with NODE_ROLE=db|lb and NODE_INDEX=1..3.
#
# Run on ALL three DB nodes at roughly the same time (etcd needs quorum to
# finish bootstrapping), then on both LB nodes.
#
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  # shellcheck disable=SC1090
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./install.sh)" >&2
  exit 1
fi

PG_VER="${PG_VER:-16}"
NODE_NAME="$(hostname -s)"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
PG_ADMIN_PASS="${PG_ADMIN_PASS:-ChangeMe_PostgresAdmin_2026!}"
PG_REPL_PASS="${PG_REPL_PASS:-ChangeMe_ReplPass_2026!}"
PG_VRRP_PASS="${PG_VRRP_PASS:-ChangeMe_Vrrp26}"      # Keepalived auth (max 8 chars used)
PG_VIP_PREFIX="${PG_VIP_PREFIX:-24}"
PGBR_S3="${PGBR_S3:-false}"                           # true => pgBackRest repo on MinIO (S3)
PGBR_S3_BUCKET="${PGBR_S3_BUCKET:-pgbackrest}"

: "${PG_DB1_IP:?PG_DB1_IP not set (source platform.env)}"
: "${PG_DB2_IP:?PG_DB2_IP not set}"
: "${PG_DB3_IP:?PG_DB3_IP not set}"

# ---- Production safety guard -------------------------------------------------
if [[ "${PLATFORM_ENV:-}" == "production" ]]; then
  for v in PG_ADMIN_PASS PG_REPL_PASS PG_VRRP_PASS; do
    if [[ "${!v}" == ChangeMe_* ]]; then
      echo "ERROR: set a real ${v} before a production install" >&2
      exit 1
    fi
  done
  if [[ "${PGBR_S3}" != "true" ]]; then
    echo "ERROR: production needs a shared pgBackRest repo (PGBR_S3=true); a per-node local repo breaks after failover" >&2
    exit 1
  fi
fi

# ---- Role / index detection ---------------------------------------------------
NODE_ROLE="${NODE_ROLE:-}"
NODE_INDEX="${NODE_INDEX:-}"
if [[ -z "${NODE_ROLE}" ]]; then
  case "${NODE_IP}" in
    "${PG_DB1_IP}") NODE_ROLE=db; NODE_INDEX=1 ;;
    "${PG_DB2_IP}") NODE_ROLE=db; NODE_INDEX=2 ;;
    "${PG_DB3_IP}") NODE_ROLE=db; NODE_INDEX=3 ;;
    "${PG_LB1_IP:-}") NODE_ROLE=lb; NODE_INDEX=1 ;;
    "${PG_LB2_IP:-}") NODE_ROLE=lb; NODE_INDEX=2 ;;
    *) echo "ERROR: ${NODE_IP} matches no PG_*_IP; set NODE_ROLE (db|lb) and NODE_INDEX" >&2; exit 1 ;;
  esac
fi
[[ "${NODE_ROLE}" == "db" || "${NODE_ROLE}" == "lb" ]] || { echo "ERROR: NODE_ROLE must be db or lb" >&2; exit 1; }
[[ "${NODE_INDEX}" =~ ^[123]$ ]] || { echo "ERROR: NODE_INDEX must be 1..3" >&2; exit 1; }
echo "Detected role=${NODE_ROLE} index=${NODE_INDEX} ip=${NODE_IP}"

# Client networks allowed to reach PostgreSQL (default: the node's /16)
PG_CLIENT_CIDR="${PG_CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"

# ==============================================================================
# LB node: HAProxy + Keepalived
# ==============================================================================
if [[ "${NODE_ROLE}" == "lb" ]]; then
  : "${PG_VIP:?PG_VIP not set}"
  : "${PG_LB1_IP:?PG_LB1_IP not set}"
  : "${PG_LB2_IP:?PG_LB2_IP not set}"

  echo "[1/3] Installing HAProxy and Keepalived..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy keepalived

  echo "[2/3] Configuring HAProxy (:5432 -> Patroni primary, :5433 -> replicas)..."
  cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 2000
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
    timeout check   3s

# Read/write: only the node Patroni reports as primary answers 200 on /primary
listen postgres_rw
    bind *:5432
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg-db1 ${PG_DB1_IP}:5432 maxconn 300 check port 8008
    server pg-db2 ${PG_DB2_IP}:5432 maxconn 300 check port 8008
    server pg-db3 ${PG_DB3_IP}:5432 maxconn 300 check port 8008

# Read-only: replicas only (/replica returns 200 on healthy standbys)
listen postgres_ro
    bind *:5433
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 2s fall 3 rise 2
    server pg-db1 ${PG_DB1_IP}:5432 maxconn 300 check port 8008
    server pg-db2 ${PG_DB2_IP}:5432 maxconn 300 check port 8008
    server pg-db3 ${PG_DB3_IP}:5432 maxconn 300 check port 8008
EOF
  haproxy -c -f /etc/haproxy/haproxy.cfg

  # Allow HAProxy to bind even while the VIP lives on the other LB
  echo 'net.ipv4.ip_nonlocal_bind = 1' >/etc/sysctl.d/98-haproxy-nonlocal.conf
  sysctl --system >/dev/null

  echo "[3/3] Configuring Keepalived VIP ${PG_VIP}/${PG_VIP_PREFIX}..."
  IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ "${NODE_INDEX}" == "1" ]]; then
    VRRP_STATE=MASTER; VRRP_PRIO=150; PEER_IP="${PG_LB2_IP}"
  else
    VRRP_STATE=BACKUP; VRRP_PRIO=100; PEER_IP="${PG_LB1_IP}"
  fi
  VIP_LINES="        ${PG_VIP}/${PG_VIP_PREFIX} dev ${IFACE}"
  if [[ -n "${PG_RO_VIP:-}" ]]; then
    VIP_LINES="${VIP_LINES}"$'\n'"        ${PG_RO_VIP}/${PG_VIP_PREFIX} dev ${IFACE}"
  fi

  cat >/etc/keepalived/keepalived.conf <<EOF
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/bin/pidof haproxy"
    interval 2
    fall 2
    rise 2
}

vrrp_instance PG_VIP {
    state ${VRRP_STATE}
    interface ${IFACE}
    virtual_router_id 51
    priority ${VRRP_PRIO}
    advert_int 1
    unicast_src_ip ${NODE_IP}
    unicast_peer {
        ${PEER_IP}
    }
    authentication {
        auth_type PASS
        auth_pass ${PG_VRRP_PASS:0:8}
    }
    virtual_ipaddress {
${VIP_LINES}
    }
    track_script {
        chk_haproxy
    }
}
EOF
  chmod 0600 /etc/keepalived/keepalived.conf

  # Firewall: client access to HAProxy, VRRP from the peer LB only
  ufw allow from "${PG_CLIENT_CIDR}" to any port 5432 proto tcp comment 'PostgreSQL RW via HAProxy'
  ufw allow from "${PG_CLIENT_CIDR}" to any port 5433 proto tcp comment 'PostgreSQL RO via HAProxy'
  if ! grep -q "pg-vrrp-${PEER_IP}" /etc/ufw/before.rules; then
    sed -i "0,/^# End required lines/s//# End required lines\n# pg-vrrp-${PEER_IP}\n-A ufw-before-input -p 112 -s ${PEER_IP} -j ACCEPT/" /etc/ufw/before.rules
  fi
  ufw reload

  systemctl enable haproxy keepalived
  systemctl restart haproxy keepalived
  sleep 3
  ip -4 addr show dev "${IFACE}" | grep -E "inet " || true
  echo "PostgreSQL LB node ${NODE_NAME} (${VRRP_STATE}) configured. VIP ${PG_VIP} should live on pg-lb1."
  exit 0
fi

# ==============================================================================
# DB node: etcd (3-node cluster) + Patroni + PostgreSQL + pgBackRest
# ==============================================================================
echo "[1/6] Installing PostgreSQL ${PG_VER}, Patroni, etcd, pgBackRest..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "postgresql-${PG_VER}" "postgresql-client-${PG_VER}" \
  patroni etcd-server etcd-client \
  pgbackrest prometheus-postgres-exporter python3-psycopg2 curl

# Patroni owns PostgreSQL; remove the Debian default cluster and disable its unit
systemctl stop postgresql || true
systemctl disable postgresql || true
pg_dropcluster --stop "${PG_VER}" main 2>/dev/null || true

mkdir -p /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest "/var/lib/postgresql/${PG_VER}"
chown -R postgres:postgres /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest

echo "[2/6] Configuring 3-node etcd cluster..."
systemctl stop etcd || true
# The Debian package starts a throw-away single-node etcd; wipe it once so the node can join the cluster
if [[ ! -f /var/lib/etcd/.cluster-initialized ]]; then
  rm -rf /var/lib/etcd/default.etcd
fi
cat >/etc/default/etcd <<EOF
ETCD_NAME="pg-db${NODE_INDEX}"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${NODE_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${NODE_IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_IP}:2379"
ETCD_INITIAL_CLUSTER="pg-db1=http://${PG_DB1_IP}:2380,pg-db2=http://${PG_DB2_IP}:2380,pg-db3=http://${PG_DB3_IP}:2380"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-etcd-token"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF

# Firewall: etcd, Patroni REST and PostgreSQL are reachable only from the right peers
for peer in "${PG_DB1_IP}" "${PG_DB2_IP}" "${PG_DB3_IP}"; do
  ufw allow from "${peer}" to any port 2379:2380 proto tcp comment 'etcd quorum'
  ufw allow from "${peer}" to any port 5432 proto tcp comment 'PostgreSQL replication/peer'
  ufw allow from "${peer}" to any port 8008 proto tcp comment 'Patroni REST peer'
done
for lb in "${PG_LB1_IP:-}" "${PG_LB2_IP:-}"; do
  [[ -n "${lb}" ]] || continue
  ufw allow from "${lb}" to any port 5432 proto tcp comment 'PostgreSQL from HAProxy'
  ufw allow from "${lb}" to any port 8008 proto tcp comment 'Patroni health checks from HAProxy'
done
if [[ -n "${MONITOR_IP:-}" ]]; then
  ufw allow from "${MONITOR_IP}" to any port 9187 proto tcp comment 'Prometheus Postgres Exporter'
  ufw allow from "${MONITOR_IP}" to any port 8008 proto tcp comment 'Patroni metrics'
fi

systemctl enable etcd
systemctl start --no-block etcd
echo "Waiting for etcd quorum (start install.sh on all 3 DB nodes)..."
etcd_ok=0
for _ in $(seq 1 60); do
  if ETCDCTL_API=3 etcdctl --endpoints="http://127.0.0.1:2379" endpoint health >/dev/null 2>&1 &&
     [[ "$(ETCDCTL_API=3 etcdctl --endpoints="http://127.0.0.1:2379" member list 2>/dev/null | wc -l)" -ge 3 ]]; then
    etcd_ok=1; break
  fi
  sleep 5
done
if [[ ${etcd_ok} -ne 1 ]]; then
  echo "ERROR: etcd cluster did not reach 3 members in 300s; run the script on the other DB nodes and retry" >&2
  exit 1
fi
touch /var/lib/etcd/.cluster-initialized
ETCDCTL_API=3 etcdctl --endpoints="http://${PG_DB1_IP}:2379,http://${PG_DB2_IP}:2379,http://${PG_DB3_IP}:2379" endpoint health || true

echo "[3/6] Writing pgBackRest configuration..."
if [[ "${PGBR_S3}" == "true" ]]; then
  : "${MINIO_VIP:?MINIO_VIP not set}"
  : "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set}"
  : "${MINIO_ROOT_PASS:?MINIO_ROOT_PASS not set}"
  PGBR_REPO="repo1-type=s3
repo1-s3-endpoint=${MINIO_VIP}:9000
repo1-s3-bucket=${PGBR_S3_BUCKET}
repo1-s3-region=us-east-1
repo1-s3-key=${MINIO_ROOT_USER}
repo1-s3-key-secret=${MINIO_ROOT_PASS}
repo1-s3-uri-style=path
repo1-storage-verify-tls=n
repo1-path=/pgbackrest"
else
  echo "WARN: PGBR_S3!=true; using a node-local repo (lab only: not valid after failover)" >&2
  PGBR_REPO="repo1-path=/var/lib/pgbackrest"
fi
cat >/etc/pgbackrest/pgbackrest.conf <<EOF
[global]
${PGBR_REPO}
repo1-retention-full=2
repo1-retention-diff=7
process-max=2
start-fast=y
log-level-file=info

[main]
pg1-path=/var/lib/postgresql/${PG_VER}/patroni
pg1-port=5432
pg1-socket-path=/var/run/postgresql
EOF
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
chmod 0600 /etc/pgbackrest/pgbackrest.conf

# pg-db3 is the asynchronous replica (never a synchronous standby), per README
NOSYNC="false"
[[ "${NODE_INDEX}" == "3" ]] && NOSYNC="true"

echo "[4/6] Writing Patroni configuration (/etc/patroni/config.yml)..."
cat >/etc/patroni/config.yml <<EOF
scope: pg-ha-cluster
namespace: /service/
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts:
    - ${PG_DB1_IP}:2379
    - ${PG_DB2_IP}:2379
    - ${PG_DB3_IP}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_mode_strict: false
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        wal_level: replica
        hot_standby: "on"
        wal_log_hints: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        password_encryption: scram-sha-256
        archive_mode: "on"
        archive_timeout: 60s
        archive_command: "pgbackrest --stanza=main archive-push %p"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all postgres peer
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host replication replicator ${PG_DB1_IP}/32 scram-sha-256
    - host replication replicator ${PG_DB2_IP}/32 scram-sha-256
    - host replication replicator ${PG_DB3_IP}/32 scram-sha-256
    - host all postgres 127.0.0.1/32 scram-sha-256
    - host all postgres ${PG_DB1_IP}/32 scram-sha-256
    - host all postgres ${PG_DB2_IP}/32 scram-sha-256
    - host all postgres ${PG_DB3_IP}/32 scram-sha-256
    - host all all ${PG_CLIENT_CIDR} scram-sha-256

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
  nosync: ${NOSYNC}
EOF
chown postgres:postgres /etc/patroni/config.yml
chmod 0600 /etc/patroni/config.yml
ln -sf /etc/patroni/config.yml /etc/patroni/patroni.yml

echo "[5/6] Configuring postgres exporter and starting Patroni..."
cat >/etc/default/prometheus-postgres-exporter <<EOF
DATA_SOURCE_NAME='postgresql://postgres:${PG_ADMIN_PASS}@127.0.0.1:5432/postgres?sslmode=disable'
EOF
chmod 0600 /etc/default/prometheus-postgres-exporter

systemctl daemon-reload
systemctl enable patroni prometheus-postgres-exporter
systemctl restart patroni

echo "[6/6] Waiting for a Patroni leader, then creating the pgBackRest stanza on it..."
leader_ok=0
for _ in $(seq 1 60); do
  if patronictl -c /etc/patroni/config.yml list 2>/dev/null | grep -q "Leader"; then
    leader_ok=1; break
  fi
  sleep 5
done
if [[ ${leader_ok} -ne 1 ]]; then
  echo "ERROR: no Patroni leader after 300s; check 'journalctl -u patroni'" >&2
  exit 1
fi

# Only the current primary can create the stanza; replicas skip and rely on it existing
if curl -fsS "http://127.0.0.1:8008/primary" >/dev/null 2>&1; then
  sudo -u postgres pgbackrest --stanza=main stanza-create
  sudo -u postgres pgbackrest --stanza=main check
else
  echo "This node is not the primary; skipping stanza-create."
fi

systemctl restart prometheus-postgres-exporter || true
patronictl -c /etc/patroni/config.yml list
echo "PostgreSQL ${PG_VER} HA node ${NODE_NAME} installed. After all 3 DB nodes finish, run this script on both LB nodes."
