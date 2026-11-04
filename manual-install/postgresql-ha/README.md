# PostgreSQL 16 HA (`pg-db1`, `pg-db2`, `pg-db3`) Manual Installation & CLI Guide (`postgresql-ha`)

- **Target Hosts:**
  - `pg-db1` (`10.20.50.11`) — **PostgreSQL Leader**
  - `pg-db2` (`10.20.50.12`) — **Synchronous Standby** (`RPO = 0`)
  - `pg-db3` (`10.20.50.13`) — **Asynchronous Replica**
- **Versions:** PostgreSQL `16`, Patroni `3.3.x`, `etcd`, `haproxy`, `keepalived`, `pgBackRest` `2.52.x`
- **Installed CLIs:** `psql`, `patronictl`, `pgbackrest`, `etcdctl`
- **Automated Script:** [`manual-install/postgresql-ha/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/postgresql-ha/install.sh)

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

