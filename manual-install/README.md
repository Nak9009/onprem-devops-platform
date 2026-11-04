# Per-Server Manual Installation & CLI Guides (`manual-install/`)

Each directory in `manual-install/` contains a dedicated **step-by-step manual installation guide (`README.md`)**, **CLI tool installation & command reference**, and an **idempotent shell installer (`install.sh`)** for Ubuntu Server 24.04 LTS (`noble`).

---

## Directory Structure & Server Mapping

| Server Folder | Target Server(s) | Installed Services & Versions | Installed CLI Tools |
| :--- | :--- | :--- | :--- |
| [`manual-install/common/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/common/README.md) | **All Servers** (Run First) | Ubuntu 24.04 Baseline, Kernel/sysctl, Swap Off, Chrony, SSH, UFW, `auditd`, Node Exporter (`1.8.2`), Promtail (`3.3.2`) | `ufw`, `chronyc`, `auditctl`, `ausearch`, `sysctl` |
| [`manual-install/gitlab/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/gitlab/README.md) | `devops-gitlab` / `prod-gitlab-01` | GitLab CE (`17.7.1-ce.0`) | `gitlab-ctl`, `gitlab-rake`, `gitlab-backup`, `gitlab-psql`, `glab` (GitLab CLI) |
| [`manual-install/jenkins/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/jenkins/README.md) | `devops-jenkins` / `prod-jenkins-01` | Jenkins LTS (`2.479.3`), OpenJDK 17, Rootless Buildah/Podman/Skopeo, Trivy (`0.58.1`) | `jenkins-cli.jar`, `buildah`, `podman`, `skopeo`, `trivy`, `kubectl`, `helm` |
| [`manual-install/nexus/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/nexus/README.md) | `devops-nexus` / `prod-nexus-01` | Sonatype Nexus Repository OSS (`3.75.1-01`), OpenJDK 17 | `/opt/nexus/bin/nexus`, Nexus REST API CLI (`curl` + `jq`) |
| [`manual-install/minio/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/minio/README.md) | `devops-nexus` / `prod-minio-01` | MinIO Server (`RELEASE.2024-12-18T13-15-44Z`) | `minio`, `mc` (MinIO Client CLI) |
| [`manual-install/rancher/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/rancher/README.md) | `devops-rancher` / `prod-rancher-01` | Docker CE (`27.4.1`), Rancher Server (`v2.10.1`) | `docker`, `rancher` CLI |
| [`manual-install/kubernetes-cp/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-cp/README.md) | `k8s-cp01` / `prod-k8s-cp01..03` | HAProxy + Keepalived, `containerd`, Kubernetes (`1.31.4`), Calico (`v3.29.1`), Argo CD (`v2.13.2`) | `kubeadm`, `kubectl`, `crictl`, `calicoctl`, `argocd` CLI |
| [`manual-install/kubernetes-worker/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-worker/README.md) | `k8s-worker01..02` / `prod-k8s-worker01..03` | `containerd`, `kubelet` + `kubeadm` (`1.31.4`), Calico Node | `kubeadm`, `crictl`, `ctr` |
| [`manual-install/monitoring/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/monitoring/README.md) | `devops-monitor` / `prod-monitor-01` | Prometheus (`2.53.3`), Grafana (`11.4.0`) | `promtool`, `grafana-cli` |
| [`manual-install/logging/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/logging/README.md) | `devops-monitor` / `prod-monitor-01` | Grafana Loki (`3.3.2`), Promtail (`3.3.2`) | `loki`, `logcli`, `promtail` |
| [`manual-install/vault/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/vault/README.md) | `devops-monitor` / `prod-secops-01` | HashiCorp Vault (`1.18.3`) | `vault` CLI |

---

## Recommended Installation Order

1. **All Servers:** [`manual-install/common/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/common/README.md)
2. **GitLab Server:** [`manual-install/gitlab/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/gitlab/README.md)
3. **Nexus Server:** [`manual-install/nexus/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/nexus/README.md)
4. **MinIO Server:** [`manual-install/minio/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/minio/README.md)
5. **Jenkins Server:** [`manual-install/jenkins/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/jenkins/README.md)
6. **Kubernetes Control Plane(s):** [`manual-install/kubernetes-cp/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-cp/README.md)
7. **Kubernetes Worker(s):** [`manual-install/kubernetes-worker/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-worker/README.md)
8. **Rancher Server:** [`manual-install/rancher/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/rancher/README.md)
9. **Monitoring Server:** [`manual-install/monitoring/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/monitoring/README.md)
10. **Logging Server:** [`manual-install/logging/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/logging/README.md)
11. **Vault Server:** [`manual-install/vault/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/vault/README.md)

