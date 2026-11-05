# PostgreSQL 16 HA (5 VMs: `2x pg-lb` + `3x pg-db`) Manual Installation & CLI Guide (`postgresql-ha`)

- **Target Hosts (5 VMs Total in `VLAN 50`):**
  - **2 × HA Load Balancer VMs (`postgresql_lb`):**
    - `pg-lb1` (`10.20.50.8`) — **HAProxy + Keepalived `MASTER`** (owns VIP `10.20.50.10`)
    - `pg-lb2` (`10.20.50.9`) — **HAProxy + Keepalived `BACKUP`** (automatic VIP failover)
  - **3 × PostgreSQL HA Database VMs (`postgresql_ha`):**
    - `pg-db1` (`10.20.50.11`) — **PostgreSQL Leader** (Patroni + etcd voter)
    - `pg-db2` (`10.20.50.12`) — **Synchronous Standby** (`RPO = 0`, Patroni + etcd voter)
    - `pg-db3` (`10.20.50.13`) — **Asynchronous Replica** (Patroni + etcd 3rd voter)
- **Versions:** PostgreSQL `16`, Patroni `3.3.x`, `etcd`, `haproxy`, `keepalived`, `pgBackRest` `2.52.x`
- **Installed CLIs:** `psql`, `patronictl`, `pgbackrest`, `etcdctl`
- **Automated Script:** [`manual-install/postgresql-ha/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/postgresql-ha/install.sh)

---

## 0. Automated Install (`install.sh`) — Read This First

The script detects its role from the host IP (matching `PG_DB1..3_IP` / `PG_LB1..2_IP` in `platform.env`) or from `NODE_ROLE=db|lb` and `NODE_INDEX=1..3`.

```bash
# 1. On pg-db1, pg-db2 and pg-db3, at about the same time (etcd needs quorum to finish):
sudo PLATFORM_ENV=production PGBR_S3=true \
     PG_ADMIN_PASS='...' PG_REPL_PASS='...' ./install.sh
# 2. Then on pg-lb1 and pg-lb2:
sudo PLATFORM_ENV=production PG_VRRP_PASS='...' ./install.sh
```

| Variable | Purpose | Default |
|---|---|---|
| `PGBR_S3=true` | pgBackRest repo on MinIO (`MINIO_VIP`, bucket `PGBR_S3_BUCKET`, default `pgbackrest`; create the bucket first). **Required in production**: a node-local repo breaks after failover. | `false` |
| `PG_CLIENT_CIDR` | Networks allowed to connect to PostgreSQL / HAProxy | node's `/16` |
| `PG_VRRP_PASS` | Keepalived VRRP password (first 8 chars used) | `ChangeMe_Vrrp26` |
| `PG_VIP_PREFIX` | VIP prefix length | `24` |

With `PLATFORM_ENV=production` the script refuses `ChangeMe_*` passwords and a local-only backup repo.

**Verify after install:**
```bash
sudo patronictl -c /etc/patroni/config.yml list     # exactly one Leader, one Sync Standby, one Replica
psql -h <PG_VIP> -p 5432 -U postgres -c "select pg_is_in_recovery()"   # f (primary)
sudo -u postgres pgbackrest --stanza=main check
```
**Rehearse before go-live:** switchover (`patronictl switchover`), a hard stop of the leader's `patroni` service, and a full restore from the S3 repo.

> The manual steps below are the reference for what the script automates. Where they differ from `install.sh` (for example the restricted `pg_hba`, per-peer firewall rules and `pg-db3` as the async node via `nosync: true`), the script is authoritative.

---

## 1. Install PostgreSQL 16, Patroni, etcd, HAProxy, Keepalived & `pgBackRest`

Run on **`pg-db1`, `pg-db2`, and `pg-db3`**:
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postgresql-16 postgresql-client-16 postgresql-contrib-16 \
  patroni etcd-server etcd-client haproxy keepalived \
  pgbackrest prometheus-postgres-exporter python3-psycopg2

# Stop default systemd postgresql unit so Patroni manages PostgreSQL lifecycle
sudo systemctl stop postgresql
sudo systemctl disable postgresql
```

---

## 2. Configure 3-Node `etcd` Consensus Cluster (`pg-db1..3`)

```bash
NODE_NAME=$(hostname -s)
NODE_IP=$(hostname -I | awk '{print $1}')
PG1_IP="10.20.50.11"
PG2_IP="10.20.50.12"
PG3_IP="10.20.50.13"

sudo tee /etc/default/etcd >/dev/null <<EOF
ETCD_NAME="${NODE_NAME}"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${NODE_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${NODE_IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_IP}:2379"
ETCD_INITIAL_CLUSTER="pg-db1=http://${PG1_IP}:2380,pg-db2=http://${PG2_IP}:2380,pg-db3=http://${PG3_IP}:2380"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-etcd-token"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF

sudo ufw allow 2379:2380/tcp comment 'etcd Quorum'
sudo systemctl enable --now etcd
```

---

## 3. Configure Patroni (`/etc/patroni/patroni.yml`) & `pgBackRest`

```bash
# Set NOSYNC="false" on pg-db1 and pg-db2; set NOSYNC="true" on pg-db3 (Async Replica)
NOSYNC="false"

sudo mkdir -p /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest
sudo chown -R postgres:postgres /etc/patroni /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest

sudo tee /etc/patroni/patroni.yml >/dev/null <<EOF
scope: pg-ha-cluster
namespace: /service/
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts:
    - ${PG1_IP}:2379
    - ${PG2_IP}:2379
    - ${PG3_IP}:2379

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
        max_wal_senders: 10
        max_replication_slots: 10
        archive_mode: "on"
        archive_timeout: 60s
        archive_command: "pgbackrest --stanza=main archive-push %p"

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/16/patroni
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    replication:
      username: replicator
      password: "ChangeMe_ReplPass_2026!"
    superuser:
      username: postgres
      password: "ChangeMe_PostgresAdmin_2026!"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: ${NOSYNC}
EOF

sudo chown postgres:postgres /etc/patroni/patroni.yml
sudo chmod 0600 /etc/patroni/patroni.yml

sudo ufw allow 5432/tcp comment 'PostgreSQL RW'
sudo ufw allow 5433/tcp comment 'PostgreSQL RO via HAProxy'
sudo ufw allow 8008/tcp comment 'Patroni REST API'
sudo ufw allow 9187/tcp comment 'Prometheus Postgres Exporter'

sudo systemctl enable --now patroni
```

---

## 3.1 Configure HAProxy + Keepalived VIP (`10.20.50.10`) for Automatic Routing

HAProxy polls Patroni's HTTP health endpoints (`:8008/primary` and `:8008/replica`) so clients always connect to a single VIP (`10.20.50.10` / `pg-rw.internal.example.com`):
- **Port `5432` (Read-Write):** Routes **only** to the current Leader (`pg-db1`, or `pg-db2` after failover).
- **Port `5433` (Read-Only):** Load-balances read queries across healthy Standbys (`pg-db2` and `pg-db3`).

```bash
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
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

# Read-Write Endpoint (:5432 -> Active Patroni Leader ONLY)
listen postgres_rw
    bind *:5432
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg-db1 10.20.50.11:5432 maxconn 300 check port 8008
    server pg-db2 10.20.50.12:5432 maxconn 300 check port 8008
    server pg-db3 10.20.50.13:5432 maxconn 300 check port 8008

# Read-Only Endpoint (:5433 -> Load-Balanced across Standbys)
listen postgres_ro
    bind *:5433
    mode tcp
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 2s fall 3 rise 2
    server pg-db1 10.20.50.11:5432 maxconn 300 check port 8008
    server pg-db2 10.20.50.12:5432 maxconn 300 check port 8008
    server pg-db3 10.20.50.13:5432 maxconn 300 check port 8008
EOF

sudo systemctl restart haproxy
```

### Create Application Database & Least-Privilege User (Run on Leader `pg-db1`)
```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE app_user WITH LOGIN PASSWORD 'ChangeMe_AppDbPass_2026!';
CREATE DATABASE app_prod OWNER app_user;
GRANT ALL PRIVILEGES ON DATABASE app_prod TO app_user;
SQL
```

---

## 3.2 How to Connect to the PostgreSQL HA Cluster

There are **two supported ways** for applications and administrators to connect to the HA cluster with automatic failover:

### Method A: Connect via the HAProxy + Keepalived VIP (Recommended)
Connect to the single Virtual IP (`10.20.50.10` / `pg-rw.internal.example.com`):
- **Read-Write (Primary Leader):** `10.20.50.10:5432`
- **Read-Only (Standby Replicas):** `10.20.50.10:5433`

```bash
# 1. Connect to the Read-Write Leader (:5432) via psql CLI
PGPASSWORD='ChangeMe_AppDbPass_2026!' psql -h 10.20.50.10 -p 5432 -U app_user -d app_prod \
  -c "SELECT inet_server_addr() AS connected_node, pg_is_in_recovery() AS is_replica;"
# Output: connected_node = 10.20.50.11 (pg-db1) | is_replica = f (Leader)

# 2. Connect to the Read-Only Standby Pool (:5433) via psql CLI
PGPASSWORD='ChangeMe_AppDbPass_2026!' psql -h 10.20.50.10 -p 5433 -U app_user -d app_prod \
  -c "SELECT inet_server_addr() AS connected_node, pg_is_in_recovery() AS is_replica;"
# Output: connected_node = 10.20.50.12 (pg-db2) or 10.20.50.13 (pg-db3) | is_replica = t (Standby)
```

### Method B: Connect via Native Multi-Host `libpq` Connection String (No VIP Required)
All modern PostgreSQL drivers (`psql`, `psycopg2`/`psycopg3`, `pgx`, JDBC, `node-postgres`) support listing all 3 nodes (`pg-db1,pg-db2,pg-db3`) with `target_session_attrs`:
- `target_session_attrs=read-write` → Automatically discovers and connects **only** to the current Leader (`pg-db1`, or `pg-db2` after failover).
- `target_session_attrs=prefer-standby` → Automatically connects to a Read-Only Standby replica (`pg-db2` or `pg-db3`).

```bash
# Automatically find and connect to the current Read-Write Leader across pg-db1..3:
psql "postgresql://app_user:ChangeMe_AppDbPass_2026!@10.20.50.11:5432,10.20.50.12:5432,10.20.50.13:5432/app_prod?target_session_attrs=read-write"

# Automatically connect to a Read-Only Replica across pg-db1..3:
psql "postgresql://app_user:ChangeMe_AppDbPass_2026!@10.20.50.11:5432,10.20.50.12:5432,10.20.50.13:5432/app_prod?target_session_attrs=prefer-standby"
```

### Method C: Connecting from Applications in the Layer 3 Kubernetes Cluster

Create a Kubernetes `Secret` in the application namespace (`dev`, `staging`, or `production`) on the **Application Kubernetes Cluster**:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-ha-credentials
  namespace: production
type: Opaque
stringData:
  # Option 1: Via HAProxy VIP (Read-Write :5432 / Read-Only :5433)
  DATABASE_URL: "postgresql://app_user:ChangeMe_AppDbPass_2026!@10.20.50.10:5432/app_prod?sslmode=prefer"
  DATABASE_READ_URL: "postgresql://app_user:ChangeMe_AppDbPass_2026!@10.20.50.10:5433/app_prod?sslmode=prefer"

  # Option 2: Multi-Host Client Failover (works even without a VIP)
  DATABASE_MULTIHOST_RW_URL: "postgresql://app_user:ChangeMe_AppDbPass_2026!@10.20.50.11:5432,10.20.50.12:5432,10.20.50.13:5432/app_prod?target_session_attrs=read-write"

  # Framework-specific variables (e.g., Laravel .env)
  DB_CONNECTION: "pgsql"
  DB_WRITE_HOST: "10.20.50.10"
  DB_WRITE_PORT: "5432"
  DB_READ_HOST: "10.20.50.10"
  DB_READ_PORT: "5433"
  DB_DATABASE: "app_prod"
  DB_USERNAME: "app_user"
  DB_PASSWORD: "ChangeMe_AppDbPass_2026!"
```

---

## 4. PostgreSQL HA CLI Reference (`patronictl`, `psql`, `pgbackrest`, `etcdctl`)

### 4.1 `patronictl` CLI (HA Cluster & Failover Management)
```bash
# View cluster topology, Leader, Sync Standby (pg-db2), Async Replica (pg-db3), and replication lag
sudo patronictl -c /etc/patroni/patroni.yml list

# Perform a controlled zero-downtime switchover from pg-db1 to pg-db2
sudo patronictl -c /etc/patroni/patroni.yml switchover --master pg-db1 --candidate pg-db2

# Reinitialize a failed/lagging replica node
sudo patronictl -c /etc/patroni/patroni.yml reinit pg-ha-cluster pg-db3

# View cluster configuration stored in etcd DCS
sudo patronictl -c /etc/patroni/patroni.yml show-config
```

### 4.2 `psql` CLI (Replication Verification & Administration)
```bash
# Check synchronous vs. asynchronous replication state from the Leader
sudo -u postgres psql -c "SELECT client_addr, application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# Verify whether current node is Leader (f) or Standby in recovery (t)
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

### 4.3 `pgbackrest` CLI (Backups & Point-in-Time Recovery)
```bash
# Initialize pgBackRest stanza and verify WAL archiving pipeline
sudo -u postgres pgbackrest --stanza=main stanza-create
sudo -u postgres pgbackrest --stanza=main check

# Run a Full or Differential backup via CLI
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main --type=diff backup

# Inspect available backups and WAL archive ranges
sudo -u postgres pgbackrest --stanza=main info

# Perform Point-in-Time Recovery (PITR) to a specific timestamp
# sudo systemctl stop patroni
# sudo -u postgres pgbackrest --stanza=main --delta --type=time "--target=2026-11-04 14:30:00+07" --target-action=promote restore
```

### 4.4 `etcdctl` CLI (Consensus Health)
```bash
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list -w table
```

