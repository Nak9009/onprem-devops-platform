# Distributed MinIO / S3 Storage Architecture

## 1. Architectural Overview

MinIO runs **outside Kubernetes** on dedicated storage infrastructure in **VLAN 60 (`10.20.60.0/24`)**:

- **Local Testing (`minimal.conf`):** Single-node, single-drive mode (`SNSD`) on `devops-nexus` / `devops-minio` for functional S3 API compatibility testing.
- **Production (`inventories/production/`):** **4-Node Distributed Erasure-Coded Cluster** (`prod-minio-01` through `prod-minio-04`) with **2 dedicated XFS data drives per node** (8 drives total), fronted by a Keepalived + HAProxy TLS endpoint (`s3.internal.example.com` / `10.20.60.10:9000`).

> **Why Not Single-Node MinIO in Production?** A single MinIO VM provides zero host-level fault tolerance and cannot perform multi-node erasure coding or online healing. Per official MinIO distributed deployment requirements, production clusters use a minimum of **4 nodes** with locally attached XFS disks (`MINIO_VOLUMES="https://prod-minio-{1...4}.internal.example.com:9000/data/disk{1...2}/minio"`).

---

## 2. Erasure Coding, Parity & Failure Domains

| Metric | Production 4-Node × 2-Drive Configuration |
| :--- | :--- |
| **Total Nodes / Drives** | 4 VMs across 4 separate VMware ESXi physical hosts (DRS Anti-Affinity) / 8 XFS drives (`8 × 500 GB = 4 TB raw`) |
| **Erasure Coding Parity** | `EC:4` (4 data blocks + 4 parity blocks; `EC:3` option for higher usable capacity) |
| **Read Quorum** | Tolerates **up to 2 full VM/ESXi host failures** (4 drives offline) while maintaining full read availability |
| **Write Quorum** | Requires `N/2 + 1` drives (`5 of 8` drives online) for new object writes |
| **Bit-Rot Protection** | HighwayHash checksum verified on every read and background scanner pass |

---

## 3. Bucket Isolation, Versioning, Lifecycle & IAM Policies

Each platform service and business application uses a dedicated bucket and least-privilege IAM policy:

| Bucket Name | Consumer | Versioning | Lifecycle / Retention Policy | Access Policy |
| :--- | :--- | :--- | :--- | :--- |
| `app-uploads-prod` | Layer 3 Business Applications | **Enabled** | Keep non-current versions 30 days | `app-s3-rw` service account only |
| `gitlab-backups` | Layer 1 GitLab Server | **Enabled** | Expire objects after 30 days | `gitlab-backup-sa` only |
| `pgbackrest-backups` | Layer 1 PostgreSQL HA (`pg-db1..3`) | **Enabled** | Managed by `pgBackRest` retention | `pgbackrest-sa` only |
| `loki-chunks` | Layer 1 Grafana Loki (`prod-monitor-01`) | Disabled | Expire after 14 days | `loki-sa` only |
| `k8s-etcd-snapshots` | Layer 2 & Layer 3 Control Planes | **Enabled** | Expire after 14 days | `etcd-backup-sa` only |
| `artifacts` | Layer 1 Jenkins CI | Enabled | Expire after 60 days | `jenkins-sa` only |

---

## 4. Independent S3 Replication & Monitoring

1. **Cross-Site / Backup Bucket Replication:** `mc mirror --watch` (or MinIO Server-Side Bucket Replication) replicates critical buckets (`gitlab-backups`, `pgbackrest-backups`, `k8s-etcd-snapshots`, `app-uploads-prod`) to the independent Backup Server (`prod-backup-01` in `VLAN 80`).
2. **Prometheus Metrics Scraping:** Prometheus (`VLAN 70`) scrapes `/minio/v2/metrics/cluster` and `/minio/v2/metrics/node` on port `:9000` to alert on offline drives (`minio_cluster_drive_offline_total > 0`), node downtime, and disk usage `> 80%`.

