# Infrastructure Requirements & VM Sizing Proposal

> **Sizing Disclaimer:** The VM sizing tables below represent an **initial architectural proposal** and must be validated against actual application workload concurrency, metric/log retention periods, object storage capacity requirements, VMware ESXi physical host resources, and projected annual growth.

---

## 1. Production VMware vSphere Sizing Plan (By Architectural Layer)

### 1.1 Layer 1A: DevOps Services (`VLAN 20` — `10.20.20.0/24` Placeholder)

| Hostname | Purpose | vCPU (Min / Rec) | RAM (Min / Rec) | OS Disk | Data Disk | Example IP | HA Strategy | Backup Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-gitlab-01` | GitLab CE (`17.7.1-ce.0`) | 4 / 8 | 8 / 16 GB | 80 GB | 250 GB (`/var/opt/gitlab`) | `10.20.20.10` | VMware HA + Warm Standby | Daily `gitlab-backup` + `/etc/gitlab` secrets → Backup VM & S3 |
| `prod-jenkins-01` | Jenkins LTS Controller (`2.479.3`) | 2 / 4 | 4 / 8 GB | 60 GB | 100 GB (`/var/lib/jenkins`) | `10.20.20.11` | VMware HA | Daily `$JENKINS_HOME` XML/jobs/credentials backup |
| `prod-jenkins-agent01` | CI Build Agent 1 (Rootless Buildah + Trivy) | 4 / 8 | 8 / 16 GB | 60 GB | 120 GB (`/var/lib/jenkins-agent`) | `10.20.20.12` | Active-Active Agent Pool | Stateless (re-provisioned by Ansible `roles/jenkins-agent`) |
| `prod-jenkins-agent02` | CI Build Agent 2 (Rootless Buildah + Trivy) | 4 / 8 | 8 / 16 GB | 60 GB | 120 GB (`/var/lib/jenkins-agent`) | `10.20.20.13` | Active-Active Agent Pool | Stateless (re-provisioned by Ansible `roles/jenkins-agent`) |
| `prod-nexus-01` | Sonatype Nexus (`3.75.1-01`) | 4 / 8 | 8 / 16 GB | 60 GB | 500 GB (`/var/lib/nexus`) | `10.20.20.14` | VMware HA | Daily blobstore + database backup to `VLAN 80` |

### 1.2 Layer 1B: Database HA & Redis (`VLAN 50` — `10.20.50.0/24` Placeholder)

| Hostname | Purpose | vCPU (Min / Rec) | RAM (Min / Rec) | OS Disk | Data & WAL Disks | Example IP | HA Strategy | Backup Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `pg-db1` | PostgreSQL 16 **Leader** (Patroni + etcd + HAProxy) | 4 / 8 | 16 / 32 GB | 60 GB | 300 GB DATA + 100 GB WAL | `10.20.50.11` (RW VIP `.10`) | Patroni Automatic Failover + DRS Anti-Affinity | Continuous WAL + Daily Full/Diff `pgBackRest` |
| `pg-db2` | PostgreSQL 16 **Synchronous Standby** (Patroni + etcd + HAProxy) | 4 / 8 | 16 / 32 GB | 60 GB | 300 GB DATA + 100 GB WAL | `10.20.50.12` (RO VIP `.15`) | Zero-data-loss Sync Standby (`RPO = 0`) | Standby backup offload via `pgBackRest` |
| `pg-db3` | PostgreSQL 16 **Asynchronous Replica** (Patroni + etcd + HAProxy) | 4 / 8 | 16 / 32 GB | 60 GB | 300 GB DATA + 100 GB WAL | `10.20.50.13` (RO VIP `.15`) | Async Read Replica + 3rd Quorum Voter | PITR verification target |
| `prod-redis-01..03` | Redis 7.4 Cache/Queues + Sentinel (1 VM Min / 3 VMs Rec) | 2 / 4 ea | 4 / 8 GB ea | 50 GB | 50 GB (`/var/lib/redis`) | `10.20.50.21..23` | Redis Sentinel 3-node failover | Daily RDB + AOF snapshot to Backup VM |

### 1.3 Layer 1C: Dedicated S3 / MinIO Storage (`VLAN 60` — `10.20.60.0/24` Placeholder)

| Hostname | Purpose | vCPU (Min / Rec) | RAM (Min / Rec) | OS Disk | Data Disks (XFS) | Example IP | HA Strategy | Backup Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-minio-01..04` | 4-Node Distributed MinIO S3 Cluster | 4 / 8 ea | 8 / 16 GB ea | 60 GB | 2 × 500 GB per VM (`/data/disk1`, `/data/disk2`) | `10.20.60.11..14` (VIP `.10`) | Erasure Coding (`EC:4` across 8 drives; survives 2 VM failures) | Bucket versioning + cross-site `mc mirror` |

### 1.4 Layer 1D: Monitoring, Logging & Independent Backup (`VLAN 70` & `VLAN 80`)

| Hostname | Purpose | vCPU (Min / Rec) | RAM (Min / Rec) | OS Disk | Data Disk | VLAN & Example IP | HA Strategy | Backup Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-monitor-01` | Prometheus (`2.53.3`), Grafana (`11.4.0`), Loki (`3.3.2`) | 4 / 8 | 8 / 16 GB | 60 GB | 300 GB (`/var/lib/prometheus`, `/var/lib/loki`) | `VLAN 70` (`10.20.70.10`) | Independent of App K8s | Daily TSDB snapshot + Grafana DB + Loki chunks in MinIO |
| `prod-backup-01` | Dedicated `pgBackRest` Repo & Platform Backup Server | 2 / 4 | 4 / 8 GB | 60 GB | 1000 GB (`/var/backups/platform`) | `VLAN 80` (`10.20.80.10`) | Isolated failure domain | Offsite replication / immutable storage |
| `prod-secops-01` | HashiCorp Vault (`1.18.3`) | 2 / 4 | 4 / 8 GB | 60 GB | 100 GB (`/var/lib/vault`) | `VLAN 10` (`10.20.10.16`) | VMware HA / Raft storage | Encrypted Vault snapshot to `prod-backup-01` |

### 1.5 Layer 2: Kubernetes Management Cluster (`VLAN 30` — `10.20.30.0/24` Placeholder)

Hosts **Rancher (`v2.10.1`)** and **Argo CD (`v2.13.2`)** only. Never runs business applications.

| Hostname | Purpose | vCPU (Min / Rec) | RAM (Min / Rec) | OS Disk | Data Disk | Example IP | HA Strategy | Backup Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-k8s-mgmt-cp01..03` | 3-Node Management Kubernetes Cluster (Control Plane + Workload) | 2 / 4 ea | 4 / 8 GB ea | 80 GB | 60 GB (`/var/lib/etcd`, `/var/lib/containerd`) | `10.20.30.11..13` (API VIP `.10`) | 3-Node etcd Quorum + Keepalived/HAProxy VIP | Every 6h `etcdctl snapshot save` + Argo CD/Rancher export |

### 1.6 Layer 3: Application Kubernetes Cluster (`VLAN 40` — `10.20.40.0/24` Placeholder)

Hosts **business applications only** (Frontends, APIs, Laravel, Node.js, Microservices, Workers, CronJobs, Ingress).

| Hostname | Purpose | vCPU (Min / Rec) | RAM (Min / Rec) | OS Disk | Data Disk | Example IP | HA Strategy | Backup Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-k8s-app-cp01..03` | 3-Node App Cluster Control Plane | 4 / 4 ea | 8 / 8 GB ea | 80 GB | 60 GB (`/var/lib/etcd`) | `10.20.40.11..13` (API VIP `.10`) | 3-Node etcd Quorum + DRS Anti-Affinity | Every 6h `etcdctl snapshot save` + `/etc/kubernetes/pki` |
| `prod-k8s-app-worker01..03` | 3+ Node App Cluster Workers | 4 / 8 ea | 16 / 32 GB ea | 80 GB | 200 GB (`/var/lib/containerd`) | `10.20.40.21..23` (Ingress VIP `.20`) | N+1 Worker Pool + PDBs + Pod Anti-Affinity | Stateless (all state in GitOps + Layer 1 PG/MinIO/Redis) |

### 1.7 Production Sizing Totals Summary

| Tier | Total VMs | Minimum Total vCPUs | Recommended Total vCPUs | Minimum Total RAM | Recommended Total RAM | Total Provisioned Disk |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Layer 1 (DevOps, DB HA, MinIO, Redis, Monitoring, Backup)** | 15–17 VMs | 54 vCPUs | 108 vCPUs | 124 GB | 248 GB | ~8.1 TB |
| **Layer 2 (Management Kubernetes Cluster)** | 3 VMs | 6 vCPUs | 12 vCPUs | 12 GB | 24 GB | 420 GB |
| **Layer 3 (Application Kubernetes Cluster)** | 6 VMs | 24 vCPUs | 36 vCPUs | 72 GB | 120 GB | 1.26 TB |
| **Grand Total (Full Production HA)** | **24–26 VMs** | **84 vCPUs** | **156 vCPUs** | **208 GB RAM** | **392 GB RAM** | **~9.8 TB** |

---

## 2. Multipass Local Workstation Resource Plan

| Profile | Config File | Purpose & Topology | Total VMs | All-at-Once RAM | Phased/Subset RAM (`--only`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Profile A: Minimal Testing** | [`multipass/profiles/minimal.conf`](file:///Users/ratanakieng/labs/onprem-devops-platform/multipass/profiles/minimal.conf) | Validates all 3 layers (GitLab, Jenkins, Nexus+MinIO, PG+Redis, Monitor, 1-node Mgmt K8s with Argo CD/Rancher, 1-node App K8s) | 8 VMs | ~28 GB RAM | **8–12 GB RAM** (run 2–3 VMs at a time on 16–24 GB laptops) |
| **Profile B: HA Simulation** | [`multipass/profiles/ha.conf`](file:///Users/ratanakieng/labs/onprem-devops-platform/multipass/profiles/ha.conf) | Simulates 3 Mgmt K8s nodes, 3 App CP + 3 App Workers, 3 PostgreSQL HA nodes (`pg-db1..3`), DevOps, Storage & Monitoring VMs | 17 VMs | ~64 GB RAM | **16–24 GB RAM** (test each HA subsystem independently) |

> **Logical HA vs. Physical HA:** Multipass multi-VM simulation validates **logical HA** (Patroni leader election, etcd raft quorum, Keepalived VIP failover, Argo CD cross-cluster deployment), but all VMs share a single physical workstation disk and CPU. True **physical HA** requires separate VMware ESXi physical hosts with DRS anti-affinity rules, dual Top-of-Rack switches, and redundant enterprise SAN/vSAN storage.
