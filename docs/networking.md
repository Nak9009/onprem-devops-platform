# Network, 8-VLAN Segmentation, and Firewall Architecture

> **IP Address Disclaimer:** All IPv4 subnets and addresses in this document (`10.20.10.0/24` through `10.20.80.0/24`) are **RFC 1918 example placeholders**. Actual production subnets are parameterized in [`inventories/production/hosts.yml`](file:///Users/ratanakieng/labs/onprem-devops-platform/inventories/production/hosts.yml) and [`inventories/production/group_vars/all.yml`](file:///Users/ratanakieng/labs/onprem-devops-platform/inventories/production/group_vars/all.yml).

---

## 1. 8-VLAN Segmentation Plan

| VLAN ID | VLAN Name | Example Subnet | Default Gateway | Hosted Systems & Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **VLAN 10** | `Mgmt-Net` | `10.20.10.0/24` | `10.20.10.1` | Ansible Bastion (`10.20.10.5`), HashiCorp Vault (`10.20.10.16`), VMware Management |
| **VLAN 20** | `DevOps-Net` | `10.20.20.0/24` | `10.20.20.1` | GitLab (`.10`), Jenkins Controller (`.11`), Jenkins Agents (`.12-.13`), Nexus (`.14`) |
| **VLAN 30** | `K8s-Mgmt-Net` | `10.20.30.0/24` | `10.20.30.1` | Management K8s Cluster API VIP (`.10`), `prod-k8s-mgmt-cp01..03` (`.11-.13`) running **Rancher** & **Argo CD** |
| **VLAN 40** | `K8s-App-Net` | `10.20.40.0/24` | `10.20.40.1` | Application K8s API VIP (`.10`), `prod-k8s-app-cp01..03` (`.11-.13`), App Ingress VIP (`.20`), `prod-k8s-app-worker01..03` (`.21-.23`) |
| **VLAN 50** | `Database-Net` | `10.20.50.0/24` | `10.20.50.1` | PostgreSQL RW VIP (`.10`), `pg-db1` (`.11`), `pg-db2` (`.12`), `pg-db3` (`.13`), PG RO VIP (`.15`), Redis (`10.20.50.21..23`) |
| **VLAN 60** | `Storage-Net` | `10.20.60.0/24` | `10.20.60.1` | MinIO S3 VIP (`.10`), `prod-minio-01..04` (`10.20.60.11..14`) |
| **VLAN 70** | `Monitor-Net` | `10.20.70.0/24` | `10.20.70.1` | `prod-monitor-01` (`10.20.70.10` — Prometheus, Grafana, Loki) |
| **VLAN 80** | `Backup-Net` | `10.20.80.0/24` | `10.20.80.1` | `prod-backup-01` (`10.20.80.10` — `pgBackRest` repository, platform archives) |

### Kubernetes Internal Overlay CIDRs (Non-Overlapping)
- **Management Cluster (`VLAN 30`):** Pod CIDR `10.243.0.0/16`, Service CIDR `10.95.0.0/12`
- **Application Cluster (`VLAN 40`):** Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/12`

---

## 2. Inter-Layer & Inter-VLAN Firewall Matrix

Default firewall policy across all VLANs and host UFW rules is **Default Deny Ingress (`DROP`)**, permitting only the explicit flows below:

| Source Layer / VLAN | Destination Layer / VLAN | Protocol & Ports | Purpose & Security Enforcement |
| :--- | :--- | :--- | :--- |
| **Ansible Bastion (`VLAN 10`)** | All VLANs (`10`–`80`) | `TCP 22` | Key-only SSH for Ansible configuration management (`PermitRootLogin no`) |
| **Developer Workstations** | GitLab (`VLAN 20`), Rancher/Argo CD (`VLAN 30`), Grafana (`VLAN 70`) | `TCP 443`, `TCP 22` (GitLab SSH) | Authenticated HTTPS access via corporate network / VPN only |
| **GitLab (`VLAN 20`)** | Jenkins Controller (`VLAN 20`) | `TCP 8080 / 443` | Push/Merge Request webhook triggers (`X-Gitlab-Token` validated) |
| **Jenkins Controller (`VLAN 20`)** | Jenkins Agents (`VLAN 20`) | `TCP 22` / Inbound `TCP 50000` | Pipeline build execution on isolated agent VMs |
| **Jenkins Agents (`VLAN 20`)** | GitLab (`VLAN 20`) | `TCP 443 / 80 / 22` | Checkout source code & commit updated image tag to GitOps repo |
| **Jenkins Agents (`VLAN 20`)** | Nexus (`VLAN 20`) | `TCP 8081`, `TCP 5000` | Push OCI container images and build artifacts |
| **Argo CD (`VLAN 30` Mgmt K8s)** | GitLab (`VLAN 20`) | `TCP 443 / 80` | Poll GitOps repository (`devops/gitops.git`) for desired state |
| **Argo CD & Rancher (`VLAN 30`)** | App K8s API VIP (`VLAN 40` `10.20.40.10`) | `TCP 6443 / 8443` | Reconcile application manifests & manage cluster lifecycle via TLS |
| **App K8s Workers (`VLAN 40`)** | Nexus (`VLAN 20` `10.20.20.14`) | `TCP 5000`, `TCP 5001` | `containerd` pulls verified application container images |
| **App K8s Workers (`VLAN 40`)** | PostgreSQL VIPs (`VLAN 50` `.10`, `.15`) | `TCP 5432` (TLS) | Business applications connect to external PostgreSQL HA (`pg_hba.conf` restricted to `10.20.40.0/24`) |
| **App K8s Workers (`VLAN 40`)** | Redis (`VLAN 50` `.21..23`) | `TCP 6379`, `TCP 26379` | Application session, cache, and queue access (ACL password required) |
| **App K8s Workers (`VLAN 40`)** | MinIO VIP (`VLAN 60` `10.20.60.10`) | `TCP 9000` (HTTPS) | Application S3 object storage access via IAM bucket policy |
| **PostgreSQL Nodes (`VLAN 50`)** | PostgreSQL Nodes (`VLAN 50`) | `TCP 5432` (PG), `8008` (Patroni), `2379-2380` (etcd) | Intra-cluster synchronous/asynchronous replication & Patroni consensus |
| **MinIO Nodes (`VLAN 60`)** | MinIO Nodes (`VLAN 60`) | `TCP 9000`, `TCP 9001` | Distributed erasure-coding intra-node traffic |
| **Prometheus (`VLAN 70`)** | All Nodes (`VLAN 10`–`80`) | `TCP 9100` (Node), `9187` (PG), `9121` (Redis), `9000` (MinIO), `10250` (Kubelet) | Pull-based metrics collection (read-only) |
| **All Nodes (`VLAN 10`–`80`)** | Loki (`VLAN 70` `10.20.70.10`) | `TCP 3100` | Promtail agents ship host and container logs to Loki |
| **Backup Server (`VLAN 80`)** | `pg-db1..3` (`VLAN 50`), MinIO (`VLAN 60`), GitLab (`VLAN 20`), K8s CPs (`VLAN 30/40`) | `TCP 22`, `TCP 5432`, `TCP 9000` | `pgBackRest` WAL/backup pulls, etcd snapshot pulls, and S3 sync |

---

## 3. Required Internal DNS Records (`internal.example.com`)

| FQDN | Target IP (Placeholder) | VLAN | Description |
| :--- | :--- | :--- | :--- |
| `vault.internal.example.com` | `10.20.10.16` | VLAN 10 | HashiCorp Vault Secret Server |
| `gitlab.internal.example.com` | `10.20.20.10` | VLAN 20 | GitLab CE Source Control |
| `jenkins.internal.example.com` | `10.20.20.11` | VLAN 20 | Jenkins CI Controller |
| `nexus.internal.example.com` | `10.20.20.14` | VLAN 20 | Sonatype Nexus Artifact UI |
| `registry.internal.example.com` | `10.20.20.14` | VLAN 20 | Nexus Private Docker Registry (`:5000`) |
| `k8s-mgmt-api.internal.example.com` | `10.20.30.10` | VLAN 30 | Management K8s Cluster HA API VIP |
| `rancher.internal.example.com` | `10.20.30.10` | VLAN 30 | Rancher UI (Ingress on Management Cluster) |
| `argocd.internal.example.com` | `10.20.30.10` | VLAN 30 | Argo CD UI/API (Ingress/NodePort on Management Cluster) |
| `k8s-app-api.internal.example.com` | `10.20.40.10` | VLAN 40 | Application K8s Cluster HA API VIP |
| `*.apps.internal.example.com` | `10.20.40.20` | VLAN 40 | Wildcard DNS for Business Application Ingress VIP |
| `pg-rw.internal.example.com` | `10.20.50.10` | VLAN 50 | PostgreSQL HA Primary Read-Write VIP (`:5432`) |
| `pg-ro.internal.example.com` | `10.20.50.15` | VLAN 50 | PostgreSQL HA Standby Read-Only VIP (`:5433` / `:5432`) |
| `redis.internal.example.com` | `10.20.50.21` | VLAN 50 | Redis Cache / Sentinel Endpoint |
| `s3.internal.example.com` | `10.20.60.10` | VLAN 60 | Distributed MinIO S3 API Endpoint (`:9000`) |
| `minio-console.internal.example.com` | `10.20.60.10` | VLAN 60 | MinIO Admin Console (`:9001`) |
| `prometheus.internal.example.com` | `10.20.70.10` | VLAN 70 | Prometheus Server |
| `grafana.internal.example.com` | `10.20.70.10` | VLAN 70 | Grafana Dashboards |
| `loki.internal.example.com` | `10.20.70.10` | VLAN 70 | Grafana Loki Log Ingestion API |
