# Complete Local Deployment Guide (Multipass + Ansible on Ubuntu 24.04)

This step-by-step guide walks through deploying, verifying, and operating the entire On-Premises DevOps Platform on a local workstation using **Multipass** and **Ansible**.

---

## 1. Prerequisites & Workstation Preparation

### 1.1 Verify Installed CLI Tools
Run the following commands from the project root (`/Users/ratanakieng/labs/onprem-devops-platform`):

```bash
multipass version
ansible --version
ansible-galaxy collection install -r requirements.yml
df -h /
```

### 1.2 Select Your Local Multipass Profile
The platform provides three VM sizing profiles in [`multipass/profiles/`](file:///Users/ratanakieng/labs/onprem-devops-platform/multipass/profiles):

| Profile | File | VMs | Total vCPUs | Total RAM | Recommended Host RAM |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`compact`** *(Default)* | [`multipass/profiles/compact.conf`](file:///Users/ratanakieng/labs/onprem-devops-platform/multipass/profiles/compact.conf) | 6 VMs | 12 (shared) | **16.5 GB** | **24 GB** |
| **`minimal`** *(Section 5.2)* | [`multipass/profiles/minimal.conf`](file:///Users/ratanakieng/labs/onprem-devops-platform/multipass/profiles/minimal.conf) | 7 VMs | 16 (shared) | **32.0 GB** | >= 40 GB |
| **`ha`** *(HA Simulation)* | [`multipass/profiles/ha.conf`](file:///Users/ratanakieng/labs/onprem-devops-platform/multipass/profiles/ha.conf) | 11 VMs | 24 (shared) | **48.0 GB** | >= 64 GB |

#### VMs Included in `compact` Profile
| VM Name | CPU | RAM | Disk | Ansible Groups | Services Deployed |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `devops-gitlab` | 2 | 4 GB | 80 GB | `gitlab` | GitLab CE (`17.7.1-ce.0`) |
| `devops-jenkins` | 2 | 2.5 GB | 40 GB | `jenkins` | Jenkins LTS (`2.479.3`), Rootless Buildah/Podman, Trivy (`0.58.1`) |
| `devops-nexus` | 2 | 3 GB | 80 GB | `nexus`, `minio` | Nexus 3 (`3.75.1-01`) + MinIO S3 (`RELEASE.2024-12-18T13-15-44Z`) |
| `devops-rancher` | 2 | 2.5 GB | 30 GB | `rancher` | Rancher Multi-Cluster Server (`v2.10.1`) |
| `k8s-cp01` | 2 | 3 GB | 40 GB | `k8s_control_plane`, `k8s_workers` | Kubernetes (`v1.31.4`), `containerd`, Calico (`v3.29.1`), Argo CD (`v2.13.2`) |
| `devops-monitor` | 2 | 1.5 GB | 40 GB | `monitoring` | Prometheus (`2.53.3`), Grafana (`11.4.0`), Loki (`3.3.2`), Vault (`1.18.3`) |

---

## 2. Step-by-Step Local Deployment Workflow

### Step 1: Initialize Local Vault Credentials
Copy the example vault file to create your local secrets file:

```bash
cp -n inventories/local/group_vars/vault.yml.example inventories/local/group_vars/vault.yml
```

*(Optional)* Encrypt the local vault file with Ansible Vault:
```bash
ansible-vault encrypt inventories/local/group_vars/vault.yml
```

---

### Step 2: Provision Multipass VMs & Generate Dynamic Inventory

#### Option A: Launch All VMs in the `compact` Profile
Requires ~17 GB of free disk space on `/` and 16.5 GB available RAM:
```bash
./multipass/create-vms.sh --profile compact
```

#### Option B: Launch Selective VMs (Modular / Low-Disk Mode)
You can launch one or more VMs at any time using `--vm` and regenerate the inventory for currently running VMs with `--running-only`:
```bash
# Example: Launch Kubernetes + Monitoring VMs only
./multipass/create-vms.sh --profile compact --vm k8s-cp01,devops-monitor

# If you manually start/launch VMs later, refresh inventories/local/hosts.yml:
./multipass/generate-inventory.sh --profile compact --running-only

# Check VM status and assigned DHCP IPv4 addresses:
./multipass/status.sh --profile compact
```

---

### Step 3: Verify Ansible Connectivity
```bash
ansible all -i inventories/local/hosts.yml -m ping
```

Expected output:
```text
k8s-cp01 | SUCCESS => {"changed": false, "ping": "pong"}
devops-monitor | SUCCESS => {"changed": false, "ping": "pong"}
```

---

### Step 4: Execute Ansible Playbooks

You can run the master orchestration playbook ([`playbooks/site.yml`](file:///Users/ratanakieng/labs/onprem-devops-platform/playbooks/site.yml)) when all 6 VMs are running, or execute individual phase playbooks in order:

```bash
# ----------------------------------------------------------------------
# Phase 2: Common OS Baseline (NTP, /etc/hosts, Sysctl, SSH, UFW)
# ----------------------------------------------------------------------
ansible-playbook -i inventories/local/hosts.yml playbooks/common.yml
./scripts/validate-services.sh --env local --phase 2

# ----------------------------------------------------------------------
# Phase 3: DevOps Core Services (GitLab, Nexus, MinIO, Jenkins)
# ----------------------------------------------------------------------
ansible-playbook -i inventories/local/hosts.yml playbooks/gitlab.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/nexus.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/minio.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/jenkins.yml
./scripts/validate-services.sh --env local --phase 3

# ----------------------------------------------------------------------
# Phase 4 & 5: Kubernetes, Calico CNI, Rancher, and Argo CD
# ----------------------------------------------------------------------
ansible-playbook -i inventories/local/hosts.yml playbooks/kubernetes.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/calico.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/rancher.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/argocd.yml
./scripts/validate-services.sh --env local --phase 4

# Apply GitOps Application manifests (dev/staging auto-sync)
multipass exec k8s-cp01 -- sudo kubectl apply -f /etc/kubernetes/addons/argocd/projects.yaml
kubectl --kubeconfig <(multipass exec k8s-cp01 -- sudo cat /etc/kubernetes/admin.conf) apply -f gitops/clusters/local/applications.yaml

# ----------------------------------------------------------------------
# Phase 6: Monitoring (Prometheus + Grafana), Logging (Loki + Promtail), Security (Vault)
# ----------------------------------------------------------------------
ansible-playbook -i inventories/local/hosts.yml playbooks/monitoring.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/logging.yml
ansible-playbook -i inventories/local/hosts.yml playbooks/security.yml
./scripts/validate-services.sh --env local --phase 6
```

---

## 3. Local Service Access Matrix & Default Credentials

Retrieve your live VM IP addresses at any time with `./multipass/status.sh --profile compact`.

| Service | Local URL (by IP or `/etc/hosts` Domain) | Port | Username | Default Password (`vault.yml`) |
| :--- | :--- | :--- | :--- | :--- |
| **GitLab CE** | `https://gitlab.devops.local` | `443` (`2222` SSH) | `root` | `ChangeMe_LocalGitLabRoot!2026` |
| **Jenkins LTS** | `http://jenkins.devops.local:8080` | `8080` | `admin` | `ChangeMe_LocalJenkinsAdmin!2026` |
| **Nexus Repository** | `http://nexus.devops.local:8081` | `8081` (`5000` Docker) | `admin` | `ChangeMe_LocalNexusAdmin!2026` |
| **MinIO Console** | `http://s3-console.devops.local:9001` | `9001` (`9000` S3 API) | `minioadmin` | `ChangeMe_LocalMinIORoot!2026` |
| **Rancher UI** | `https://rancher.devops.local` | `443` | `admin` | `ChangeMe_LocalRancherBootstrap!2026` |
| **Argo CD UI** | `https://<k8s-cp01-ip>:30443` | `30443` | `admin` | `ChangeMe_LocalArgoCDAdmin!2026` |
| **Prometheus UI** | `http://<devops-monitor-ip>:9090` | `9090` | *(None)* | *(Internal UI)* |
| **Grafana UI** | `http://<devops-monitor-ip>:3000` | `3000` | `admin` | `ChangeMe_LocalGrafanaAdmin!2026` |
| **Loki API** | `http://<devops-monitor-ip>:3100/ready` | `3100` | *(None)* | *(Queried via Grafana)* |
| **HashiCorp Vault** | `http://<devops-monitor-ip>:8200/ui` | `8200` | *(Unseal token)* | *(Initialized via `vault operator init`)* |

### Optional: Map Domains in Your macOS `/etc/hosts`
To open the services by domain name in your macOS browser, add the VM IPs from `./multipass/status.sh` to `/etc/hosts` on your Mac:
```bash
sudo tee -a /etc/hosts <<EOF
192.168.252.24 k8s-cp01.devops.local argocd.devops.local
192.168.252.25 devops-monitor.devops.local prometheus.devops.local grafana.devops.local loki.devops.local vault.devops.local
EOF
```

---

## 4. Stopping, Restarting, or Destroying the Local Environment

```bash
# Stop all running platform VMs without losing data
multipass stop k8s-cp01 devops-monitor

# Start VMs again and refresh inventory IPs
./multipass/create-vms.sh --profile compact --vm k8s-cp01,devops-monitor

# Permanently destroy platform VMs (requires typing 'yes' to confirm; never touches non-platform VMs)
./multipass/destroy-vms.sh --profile compact
```
