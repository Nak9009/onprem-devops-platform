# Local Multipass Manual Installation Guide (`LOCAL-MULTIPASS-GUIDE.md`)

This guide walks through deploying the **3-Layer On-Premises DevOps Platform** locally on a macOS/Linux workstation using **Multipass** and the scripts in [`manual-install/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/README.md) with [`manual-install/local.env`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/local.env).

---

## 1. Local Multipass Topology & IP Plan (`local.env`)

| Layer | Multipass VM Name | vCPU / RAM / Disk | Default Local IP | Installed Modules (`manual-install/<module>`) |
| :--- | :--- | :--- | :--- | :--- |
| **Layer 1** | `devops-gitlab` | `2 vCPU / 4G / 40G` | `192.168.252.10` | `common`, `gitlab` (`17.7.1-ce.0` + `glab` CLI) |
| **Layer 1** | `devops-jenkins` | `2 vCPU / 3G / 30G` | `192.168.252.11` | `common`, `jenkins`, `jenkins-agent` (Buildah + Trivy) |
| **Layer 1** | `devops-nexus` | `2 vCPU / 3G / 40G` | `192.168.252.12` | `common`, `nexus` (`3.75.1-01`), `minio` + `mc` CLI |
| **Layer 1** | `pg-db1` *(or `pg-db1..3` + `pg-lb1..2`)* | `2 vCPU / 2G / 30G` | `192.168.252.17` | `common`, `postgresql-ha` (`PG 16` + `pgBackRest`), `redis` |
| **Layer 1** | `devops-monitor` | `2 vCPU / 2G / 30G` | `192.168.252.25` | `common`, `monitoring` (Prometheus + Grafana), `logging` (Loki + Promtail), `vault` |
| **Layer 2** | `k8s-mgmt-cp01` | `2 vCPU / 3G / 30G` | `192.168.252.23` | `common`, `kubernetes-mgmt` (Management K8s + **Argo CD**), `rancher` |
| **Layer 3** | `k8s-cp01` | `2 vCPU / 3G / 30G` | `192.168.252.24` | `common`, `kubernetes-cp` (Application K8s Cluster — Business Apps Only) |

> **Workstation Memory Tip (16–24 GB RAM):** You do **not** need to run all 7 VMs at once. Launch only the VMs for the layer you are testing (`multipass launch ...`), install them, and stop unused VMs (`multipass stop <vm>`) when switching layers.

---

## 2. Step 1: Launch Local Multipass VMs (Ubuntu 24.04 LTS)

### Option A: Launch via `multipass/create-vms.sh` (Recommended)
```bash
# Launch all Minimal profile VMs, or only specific VMs using --only:
./multipass/create-vms.sh --profile compact --only pg-db1,devops-monitor,k8s-mgmt-cp01,k8s-cp01
```

### Option B: Launch Individual VMs Manually with `multipass launch`
```bash
multipass launch 24.04 --name devops-gitlab  --cpus 2 --memory 4G --disk 40G
multipass launch 24.04 --name devops-jenkins --cpus 2 --memory 3G --disk 30G
multipass launch 24.04 --name devops-nexus   --cpus 2 --memory 3G --disk 40G
multipass launch 24.04 --name pg-db1         --cpus 2 --memory 2G --disk 30G
multipass launch 24.04 --name devops-monitor --cpus 2 --memory 2G --disk 30G
multipass launch 24.04 --name k8s-mgmt-cp01  --cpus 2 --memory 3G --disk 30G
multipass launch 24.04 --name k8s-cp01       --cpus 2 --memory 3G --disk 30G

# List assigned Multipass IP addresses and update manual-install/local.env if needed:
multipass list
```

---

## 3. Step 2: Inspect Local Environment (`manual-install/local.env`)

Verify the local target IPs and versions using [`manual-install/devops-cli.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/devops-cli.sh) with `--env local`:
```bash
./manual-install/devops-cli.sh --env local list
```

---

## 4. Step 3: Install Each Local Multipass Server

You can install any Multipass VM either **via `multipass transfer` + `multipass exec`** or **via SSH (`devops-cli.sh --env local remote-install`)**:

### Method 1: Copy `manual-install/` into a Multipass VM and Run `devops-cli.sh`
```bash
# Copy manual-install/ into any running Multipass VM:
for vm in pg-db1 devops-monitor k8s-mgmt-cp01 k8s-cp01; do
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

### Method 2: Remote SSH Install from Your Workstation (`devops-cli.sh --env local`)
If SSH key access (`ansible@<ip>`) was configured by `multipass/create-vms.sh`:
```bash
./manual-install/devops-cli.sh --env local remote-install common        ansible@192.168.252.17
./manual-install/devops-cli.sh --env local remote-install postgresql-ha ansible@192.168.252.17
./manual-install/devops-cli.sh --env local remote-install redis         ansible@192.168.252.17
```

---

## 5. Step 4: Verify All Local Multipass Services

Run the unified status check from your Mac/Linux workstation against `local.env`:
```bash
./manual-install/devops-cli.sh --env local status
```

