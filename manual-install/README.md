# Per-Server Manual Installation & CLI Guides (`manual-install/`)

Each directory in `manual-install/` contains a dedicated **step-by-step manual installation guide (`README.md`)**, **CLI tool installation & command reference**, and an **idempotent shell installer (`install.sh`)** for Ubuntu Server 24.04 LTS (`noble`), organized by the **3-Layer Architecture**.

---

## Directory Structure & 3-Layer Server Mapping

| Layer | Server Folder | Target Server(s) | Installed Services & Versions | Installed CLI Tools |
| :--- | :--- | :--- | :--- | :--- |
| **All** | [`manual-install/common/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/common/README.md) | **All Servers** (Run First) | Ubuntu 24.04 Baseline, Kernel/sysctl, Swap Off, Chrony, SSH, UFW, `auditd`, Node Exporter (`1.8.2`) | `ufw`, `chronyc`, `auditctl`, `ausearch`, `sysctl` |
| **Layer 1** | [`manual-install/gitlab/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/gitlab/README.md) | `devops-gitlab` / `prod-gitlab-01` | GitLab CE (`17.7.1-ce.0`) | `gitlab-ctl`, `gitlab-rake`, `gitlab-backup`, **`glab`** |
| **Layer 1** | [`manual-install/jenkins/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/jenkins/README.md) | `devops-jenkins` / `prod-jenkins-01` | Jenkins LTS Controller (`2.479.3`), OpenJDK 17 | **`jenkins-cli.jar`**, `buildah`, `podman`, `skopeo`, `trivy`, `kubectl`, `helm` |
| **Layer 1** | [`manual-install/jenkins-agent/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/jenkins-agent/README.md) | `prod-jenkins-agent01..02` | Dedicated CI Build Agent (Rootless Buildah/Podman + Trivy `0.58.1`) | `buildah`, `podman`, `skopeo`, `trivy`, `kubectl`, `helm` |
| **Layer 1** | [`manual-install/nexus/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/nexus/README.md) | `devops-nexus` / `prod-nexus-01` | Sonatype Nexus Repository OSS (`3.75.1-01`), OpenJDK 17 | `/opt/nexus/bin/nexus`, Nexus REST API CLI (`curl` + `jq`) |
| **Layer 1** | [`manual-install/postgresql-ha/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/postgresql-ha/README.md) | `pg-db1` (Leader), `pg-db2` (Sync), `pg-db3` (Async) | PostgreSQL 16 HA + Patroni + etcd + HAProxy VIP + `pgBackRest` | **`psql`**, **`patronictl`**, **`pgbackrest`**, **`etcdctl`** |
| **Layer 1** | [`manual-install/redis/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/redis/README.md) | `prod-redis-01..03` | Redis 7.4 Server + Redis Sentinel + Exporter (`:9121`) | **`redis-cli`** |
| **Layer 1** | [`manual-install/minio/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/minio/README.md) | `prod-minio-01..04` | MinIO S3 Storage (`RELEASE.2024-12-18T13-15-44Z`, Single & 4-Node Distributed) | `minio`, **`mc`** (MinIO Client CLI) |
| **Layer 1** | [`manual-install/monitoring/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/monitoring/README.md) | `devops-monitor` / `prod-monitor-01` | Prometheus (`2.53.3`), Grafana (`11.4.0`) | **`promtool`**, **`grafana-cli`** |
| **Layer 1** | [`manual-install/logging/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/logging/README.md) | `devops-monitor` / `prod-monitor-01` | Grafana Loki (`3.3.2`), Promtail (`3.3.2`) | `loki`, **`logcli`**, `promtail` |
| **Layer 1** | [`manual-install/vault/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/vault/README.md) | `prod-secops-01` | HashiCorp Vault (`1.18.3`) | **`vault`** CLI |
| **Layer 2** | [`manual-install/kubernetes-mgmt/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-mgmt/README.md) | `k8s-mgmt-cp01` / `prod-k8s-mgmt-cp01..03` | Dedicated Management K8s Cluster (Hosts **Rancher** & **Argo CD** only) | `kubeadm`, `kubectl`, `calicoctl`, **`argocd`**, **`rancher`** |
| **Layer 2** | [`manual-install/rancher/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/rancher/README.md) | `devops-rancher` / `prod-k8s-mgmt-cp01` | Rancher Server (`v2.10.1`) | `docker`, **`rancher`** CLI |
| **Layer 3** | [`manual-install/kubernetes-cp/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-cp/README.md) | `k8s-cp01` / `prod-k8s-cp01..03` | Application K8s Cluster Control Plane (`1.31.4`) + Calico (`v3.29.1`) | `kubeadm`, `kubectl`, `crictl`, **`calicoctl`** |
| **Layer 3** | [`manual-install/kubernetes-worker/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-worker/README.md) | `k8s-worker01..02` / `prod-k8s-worker01..03` | Application K8s Cluster Worker Nodes (`1.31.4` — Business Apps Only) | `kubeadm`, `crictl`, `ctr` |
