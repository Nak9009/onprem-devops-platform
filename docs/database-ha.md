# PostgreSQL 16 High-Availability Architecture (`pg-db1`, `pg-db2`, `pg-db3`)

## 1. Architectural Overview

All production operational and business databases run **outside Kubernetes** on three dedicated Ubuntu 24.04 virtual machines in **VLAN 50 (`10.20.50.0/24`)**:

| Hostname | Initial Role | Example IP | Replication Mode | Patroni / etcd Role |
| :--- | :--- | :--- | :--- | :--- |
| **`pg-db1`** | **PostgreSQL Leader (Primary)** | `10.20.50.11` | Accepts all Read-Write transactions | Patroni Leader + etcd voting member |
| **`pg-db2`** | **Synchronous Standby** | `10.20.50.12` | Synchronous WAL commit (`synchronous_commit = on`, `RPO = 0`) | Failover Candidate (`priority: 100`) + etcd voting member |
| **`pg-db3`** | **Asynchronous Replica** | `10.20.50.13` | Asynchronous streaming replication | Failover Candidate (`priority: 90`) + etcd voting member |

---

## 2. HA Control Plane, Failover & Split-Brain Prevention

PostgreSQL streaming replication alone does **not** provide automatic failover. The HA control plane combines four components:

1. **etcd (3-Node Distributed Consensus Store on `pg-db1..3`):**
   - Stores the single leader lock (`/service/pg-ha-cluster/leader`) with a 10-second TTL (`ttl: 30`, `loop_wait: 10`).
   - Requires a strict majority quorum (`2 of 3` nodes) to hold or acquire leadership.
2. **Patroni (`3.3.x`) HA Cluster Manager:**
   - Manages the `postgresql` process lifecycle and exposes health check HTTP endpoints on port `:8008`:
     - `GET /primary` (or `/master`) → returns `HTTP 200` **only** on the current Leader (`pg-db1`).
     - `GET /replica` → returns `HTTP 200` on healthy Standbys (`pg-db2`, `pg-db3`).
   - Enforces `synchronous_mode: true` and `synchronous_node_count: 1` so `pg-db1` replicates synchronously to `pg-db2` (and automatically switches synchronous standby to `pg-db3` if `pg-db2` goes offline).
3. **Split-Brain Prevention & Fencing:**
   - If `pg-db1` loses network connectivity to the majority etcd quorum, its leader lock expires and Patroni immediately demotes `pg-db1` to read-only recovery mode (or triggers Linux `/dev/watchdog` hardware reset) before `pg-db2` is promoted.
   - `pg_rewind` is enabled so a former leader automatically rejoins the cluster as a standby without rebuilding from scratch.
4. **Stable Database Endpoint (HAProxy + Keepalived VIP `10.20.50.10`):**
   - **Read-Write Endpoint (`pg-rw.internal.example.com` / `10.20.50.10:5432`):** HAProxy polls Patroni `http://<node>:8008/primary` every 2 seconds and routes write connections exclusively to the active Leader.
   - **Read-Only Endpoint (`pg-ro.internal.example.com` / `10.20.50.10:5433`):** HAProxy polls `http://<node>:8008/replica` and load-balances read queries across `pg-db2` and `pg-db3`.

---

## 3. Storage Layout, Backups (`pgBackRest`) & RTO/RPO

### 3.1 Dedicated Disk Layout on `pg-db1..3`
- **OS Disk (`/dev/sda` — 60 GB):** Ubuntu 24.04 OS and binaries.
- **Data Disk (`/dev/sdb` mounted at `/var/lib/postgresql` — 300 GB XFS, `noatime`):** PostgreSQL table/index data (`PGDATA`).
- **WAL Disk (`/dev/sdc` mounted at `/var/lib/postgresql/wal` — 100 GB XFS, `noatime`):** Dedicated `pg_wal` volume so heavy sequential WAL writes never contend with random data read/write IOPS.

### 3.2 `pgBackRest` Backup & Point-in-Time Recovery (PITR)
- **Repository Location:** Dedicated Backup Server (`prod-backup-01` in `VLAN 80` or S3 bucket `s3://pgbackrest-backups` on MinIO).
- **Schedule:**
  - **Continuous WAL Archiving:** `archive_command = 'pgbackrest --stanza=main archive-push %p'`
  - **Weekly Full Backup:** Sundays at `01:00 UTC` (`--type=full`)
  - **Daily Differential Backup:** Mon–Sat at `01:00 UTC` (`--type=diff`, offloaded to standby `pg-db2` via `backup-standby=y`)
- **Recovery Objectives:**
  - **Failover RTO:** `< 15 seconds` (Patroni leader promotion + HAProxy health check switch)
  - **Failover RPO:** `0 bytes` (`RPO = 0` via synchronous replication to `pg-db2`)
  - **Disaster Recovery PITR RPO:** `< 60 seconds` (`archive_timeout = 60s`)

---

## 4. Secure Application Connectivity from Kubernetes (`Layer 3 → Layer 1`)

Applications inside the **Application Kubernetes Cluster (`VLAN 40`)** connect to PostgreSQL over the private network using TLS (`sslmode=verify-full`) and credentials injected from Vault / Kubernetes Secrets:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-postgres-credentials
  namespace: production
type: Opaque
stringData:
  DATABASE_WRITE_URL: "postgresql://app_user:${DB_PASSWORD}@pg-rw.internal.example.com:5432/app_prod?sslmode=require"
  DATABASE_READ_URL: "postgresql://app_user:${DB_PASSWORD}@pg-rw.internal.example.com:5433/app_prod?sslmode=require"
```

On `pg-db1..3`, `/etc/postgresql/16/main/pg_hba.conf` restricts client connections strictly to the Application Cluster Worker subnet (`10.20.40.0/24`) using `scram-sha-256` authentication.

