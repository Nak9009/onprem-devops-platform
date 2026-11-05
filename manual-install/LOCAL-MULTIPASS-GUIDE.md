# Local Multipass Manual Installation Guide (`LOCAL-MULTIPASS-GUIDE.md`)

This guide walks through deploying the **3-Layer On-Premises DevOps Platform** locally on a macOS/Linux workstation using **Multipass** and the scripts in [`manual-install/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/README.md) with [`manual-install/local.env`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/local.env).

---

## 1. Local Multipass Topology & IP Plan (`local.env`)

[`manual-install/local.env`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/local.env) automatically discovers the live DHCP IP of every running Multipass VM via `multipass list` and falls back to the table below:

| Layer | Multipass VM Name | vCPU / RAM / Disk | Auto-Detected Local IP | Installed Modules (`manual-install/<module>`) |
| :--- | :--- | :--- | :--- | :--- |
| **Layer 1** | `devops-gitlab` | `2 vCPU / 3.5–4G / 40G` | `192.168.252.30` | `common`, `gitlab` (`17.7.1-ce.0` + `glab` CLI) |
| **Layer 1** | `devops-jenkins` | `2 vCPU / 2–3G / 30G` | `192.168.252.31` | `common`, `jenkins`, `jenkins-agent` (Buildah + Trivy) |
| **Layer 1** | `devops-nexus` | `2 vCPU / 2.5–3G / 40G` | `192.168.252.32` | `common`, `nexus` (`3.75.1-01`), `minio` (Garage S3 `v2.5.0` on `:9443`) |
| **Layer 1** | `pg-db1` *(or `pg-db1..3` + `pg-lb1..2`)* | `2 vCPU / 1.5–2G / 30G` | `192.168.252.33` | `common`, `postgresql-ha` (`PG 16` + Patroni + etcd + `pgBackRest`), `redis` |
| **Layer 1** | `devops-monitor` | `2 vCPU / 1.5–2G / 30G` | `192.168.252.36` | `common`, `monitoring` (Prometheus + Grafana), `logging` (Loki + Promtail), `vault` |
| **Layer 2** | `k8s-mgmt-cp01` | `2 vCPU / 2.5–3G / 30G` | `192.168.252.34` | `common`, `kubernetes-mgmt` (Management K8s + **Argo CD**), `rancher` |
| **Layer 3** | `k8s-cp01` | `2 vCPU / 3G / 30G` | `192.168.252.35` | `common`, `kubernetes-cp` (Application K8s Cluster — Business Apps Only) |

> **Workstation Memory Tip (16–24 GB RAM):** You do **not** need to run all 7 VMs at once. Launch only the VMs for the layer you are testing (`multipass launch ...`), install them, and stop unused VMs (`multipass stop <vm>`) when switching layers.

---

## 2. Step 1: Launch Local Multipass VMs (Ubuntu 24.04 LTS)

### Option A: Launch via `multipass/create-vms.sh` (Recommended)
```bash
# Launch all 7 VMs in the Compact profile (~16.5 GB RAM) or Minimal profile (~20 GB RAM):
./multipass/create-vms.sh --profile compact

# Or launch only specific VMs using --only:
./multipass/create-vms.sh --profile compact --only pg-db1,devops-monitor,k8s-mgmt-cp01,k8s-cp01
```

### Option B: Launch Individual VMs Manually with `multipass launch`
```bash
multipass launch 24.04 --name devops-gitlab  --cpus 2 --memory 4G --disk 40G
multipass launch 24.04 --name devops-jenkins --cpus 2 --memory 3G --disk 30G
multipass launch 24.04 --name devops-nexus   --cpus 2 --memory 3G --disk 40G
multipass launch 24.04 --name pg-db1         --cpus 2 --memory 2G --disk 30G
multipass launch 24.04 --name k8s-mgmt-cp01  --cpus 2 --memory 3G --disk 30G
multipass launch 24.04 --name k8s-cp01       --cpus 2 --memory 3G --disk 30G
multipass launch 24.04 --name devops-monitor --cpus 2 --memory 2G --disk 30G

# List assigned Multipass IP addresses:
multipass list
```

---

## 3. Step 2: Inspect Local Environment (`manual-install/local.env`)

Verify the auto-discovered local target IPs and versions using [`manual-install/devops-cli.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/devops-cli.sh) with `--env local`:
```bash
./manual-install/devops-cli.sh --env local env
./manual-install/devops-cli.sh --env local list
```

---

## 4. Step 3: Install Each Local Multipass Server

### Method 1: Native `multipass-install` from Host (Recommended — Works Without SSH Keys)
`devops-cli.sh --env local multipass-install <module> <vm>` resolves all live Multipass IPs on the host, transfers the module into the VM, and executes the installer via `multipass exec`:

```bash
# 0. Baseline all 7 running Multipass VMs (chrony, sysctl, UFW, auditd, node_exporter):
for vm in devops-gitlab devops-jenkins devops-nexus pg-db1 k8s-mgmt-cp01 k8s-cp01 devops-monitor; do
  ./manual-install/devops-cli.sh --env local multipass-install common "$vm"
done

# 1. Layer 1: DevOps & Artifact Storage (GitLab, Nexus, Garage S3, Jenkins):
./manual-install/devops-cli.sh --env local multipass-install gitlab        devops-gitlab
./manual-install/devops-cli.sh --env local multipass-install nexus         devops-nexus
./manual-install/devops-cli.sh --env local multipass-install minio         devops-nexus
./manual-install/devops-cli.sh --env local multipass-install jenkins       devops-jenkins

# 2. Layer 1: Database (PostgreSQL 16 + Patroni + etcd + pgBackRest) & Redis on pg-db1:
./manual-install/devops-cli.sh --env local multipass-install postgresql-ha pg-db1
./manual-install/devops-cli.sh --env local multipass-install redis         pg-db1

# 3. Layer 1: Monitoring, Logging & HashiCorp Vault on devops-monitor:
./manual-install/devops-cli.sh --env local multipass-install monitoring    devops-monitor
./manual-install/devops-cli.sh --env local multipass-install logging       devops-monitor
./manual-install/devops-cli.sh --env local multipass-install vault         devops-monitor

# 4. Layer 2: Management Kubernetes Cluster (Argo CD + Rancher) on k8s-mgmt-cp01:
./manual-install/devops-cli.sh --env local multipass-install kubernetes-mgmt k8s-mgmt-cp01
./manual-install/devops-cli.sh --env local multipass-install rancher         k8s-mgmt-cp01

# 5. Layer 3: Application Kubernetes Cluster (Business Apps Only) on k8s-cp01:
./manual-install/devops-cli.sh --env local multipass-install kubernetes-cp   k8s-cp01
```

### Method 2: Copy `manual-install/` into a Multipass VM and Run `devops-cli.sh` Inside the VM
```bash
# Copy manual-install/ into any running Multipass VM:
for vm in devops-gitlab devops-jenkins devops-nexus pg-db1 k8s-mgmt-cp01 k8s-cp01 devops-monitor; do
  multipass transfer -r manual-install "${vm}:/home/ubuntu/manual-install"
done

# 1. Install Layer 1 Database & Redis on pg-db1:
multipass exec pg-db1 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install common"
multipass exec pg-db1 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install postgresql-ha"
multipass exec pg-db1 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install redis"

# 2. Install Layer 1 Monitoring, Logging & Vault on devops-monitor:
multipass exec devops-monitor -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install common"
multipass exec devops-monitor -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install monitoring"
multipass exec devops-monitor -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install logging"
multipass exec devops-monitor -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install vault"

# 3. Install Layer 2 Management Kubernetes Cluster (Argo CD + Rancher) on k8s-mgmt-cp01:
multipass exec k8s-mgmt-cp01 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install common"
multipass exec k8s-mgmt-cp01 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install kubernetes-mgmt"
multipass exec k8s-mgmt-cp01 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install rancher"

# 4. Install Layer 3 Application Kubernetes Cluster (Business Apps Only) on k8s-cp01:
multipass exec k8s-cp01 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install common"
multipass exec k8s-cp01 -- bash -c "cd ~/manual-install && ./devops-cli.sh --env local install kubernetes-cp"
```

---

## 5. Step 4: Verify All Local Multipass Services

Run the unified status check from your Mac/Linux workstation against `local.env`:
```bash
./manual-install/devops-cli.sh --env local status
```

| Endpoint Name | URL / Port Checked | Target Multipass VM | Notes |
| :--- | :--- | :--- | :--- |
| `GitLab CE` | `http://<GITLAB_IP>/-/readiness` | `devops-gitlab` | Returns `HTTP 200` after `gitlab/install.sh` completes |
| `Jenkins LTS` | `http://<JENKINS_IP>:8080/login` | `devops-jenkins` | Returns `HTTP 200` after `jenkins/install.sh` completes |
| `Sonatype Nexus` | `http://<NEXUS_IP>:8081/service/rest/v1/status` | `devops-nexus` | Returns `HTTP 200` after `nexus/install.sh` completes |
| `Garage S3 API` | `https://<MINIO_VIP>:9443/health` | `devops-nexus` | Returns `HTTP 200` after `minio/install.sh` (Garage `v2.5.0`) completes |
| `PostgreSQL RW VIP` | `<PG_VIP>:5432` | `pg-db1` | `TCP OPEN` when Patroni PostgreSQL 16 is active |
| `PostgreSQL RO VIP` | `<PG_VIP>:5433` | `pg-lb1` | Checked when `pg-lb1` HAProxy VM is running (`[SKIP]` in 1-DB mode) |
| `Patroni pg-db1` | `http://<PG_DB1_IP>:8008/health` | `pg-db1` | Returns `HTTP 200` when Patroni leader is healthy |
| `Redis Server` | `<REDIS_IP>:6379` | `pg-db1` | `TCP OPEN` when Redis `7.4` is listening |
| `Prometheus` | `http://<MONITOR_IP>:9090/-/healthy` | `devops-monitor` | Returns `HTTP 200` |
| `Grafana` | `http://<MONITOR_IP>:3000/api/health` | `devops-monitor` | Returns `HTTP 200` |
| `Grafana Loki` | `http://<MONITOR_IP>:3100/ready` | `devops-monitor` | Returns `HTTP 200` |
| `HashiCorp Vault` | `https://<VAULT_IP>:8200/v1/sys/health` | `devops-monitor` | Returns `HTTP 200` (unsealed) or `HTTP 501/503` (running, uninitialized/sealed) |
| `Mgmt K8s API` | `<K8S_MGMT_CP01_IP>:6443` | `k8s-mgmt-cp01` | `TCP OPEN` (Layer 2 Management Kubernetes API) |
| `Rancher Server` | `https://<K8S_MGMT_CP01_IP>/ping` | `k8s-mgmt-cp01` | Returns `HTTP 200` (`pong`) after `rancher/install.sh` completes |
| `Argo CD Server` | `https://<K8S_MGMT_CP01_IP>:30443/healthz` | `k8s-mgmt-cp01` | Returns `HTTP 200` (`ok`) |
| `App K8s API` | `<K8S_APP_CP01_IP>:6443` | `k8s-cp01` | `TCP OPEN` (Layer 3 Application Kubernetes API) |

