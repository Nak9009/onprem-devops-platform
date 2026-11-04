# Complete Production Deployment Guide (VMware vSphere + Manual & Ansible)

This production deployment manual covers **Section 6** and **Section 15** for deploying the On-Premises DevOps Platform onto manually provisioned **Ubuntu Server 24.04 LTS** virtual machines on **VMware vSphere / ESXi** without Multipass.

---

## 1. Production Architecture & VMware VM Inventory

### 1.1 Production VM Allocation Table (14 VMs)

| Hostname | Static IP | VLAN / Subnet | vCPU | RAM | OS Disk | Data Disk | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-gitlab-01` | `10.20.10.10` | DevOps (`10.20.10.0/24`) | 8 | 16 GB | 80 GB | 250 GB (`/var/opt/gitlab`) | GitLab CE (`17.7.1-ce.0`) |
| `prod-jenkins-01` | `10.20.10.11` | DevOps (`10.20.10.0/24`) | 4 | 8 GB | 60 GB | 100 GB (`/var/lib/jenkins`) | Jenkins LTS (`2.479.3`) + Buildah + Trivy |
| `prod-nexus-01` | `10.20.10.12` | DevOps (`10.20.10.0/24`) | 4 | 12 GB | 60 GB | 500 GB (`/var/lib/nexus`) | Sonatype Nexus (`3.75.1-01`) |
| `prod-rancher-01` | `10.20.10.13` | DevOps (`10.20.10.0/24`) | 4 | 8 GB | 60 GB | 80 GB (`/var/lib/rancher`) | Rancher Server (`v2.10.1`) |
| `prod-monitor-01` | `10.20.10.14` | DevOps (`10.20.10.0/24`) | 4 | 16 GB | 60 GB | 300 GB (`/var/lib/prometheus`, `/var/lib/loki`) | Prometheus, Grafana, Loki |
| `prod-minio-01` | `10.20.10.15` | DevOps (`10.20.10.0/24`) | 4 | 8 GB | 60 GB | 500 GB (`/var/lib/minio`) | Dedicated MinIO S3 Storage |
| `prod-secops-01` | `10.20.10.16` | DevOps (`10.20.10.0/24`) | 4 | 8 GB | 60 GB | 100 GB (`/var/lib/vault`) | HashiCorp Vault (`1.18.3`) & SonarQube |
| `prod-postgres-01` | `10.20.10.17` | DevOps (`10.20.10.0/24`) | 4 | 16 GB | 60 GB | 300 GB (`/var/lib/postgresql`) | Dedicated External PostgreSQL |
| `prod-k8s-cp01` | `10.20.20.21` | K8s (`10.20.20.0/24`) | 4 | 8 GB | 100 GB | - | K8s HA Control Plane 1 (`MASTER` VIP `10.20.20.20`) |
| `prod-k8s-cp02` | `10.20.20.22` | K8s (`10.20.20.0/24`) | 4 | 8 GB | 100 GB | - | K8s HA Control Plane 2 (`BACKUP` VIP `10.20.20.20`) |
| `prod-k8s-cp03` | `10.20.20.23` | K8s (`10.20.20.0/24`) | 4 | 8 GB | 100 GB | - | K8s HA Control Plane 3 (`BACKUP` VIP `10.20.20.20`) |
| `prod-k8s-worker01` | `10.20.20.31` | K8s (`10.20.20.0/24`) | 8 | 16 GB | 100 GB | 200 GB | K8s Worker Node 1 |
| `prod-k8s-worker02` | `10.20.20.32` | K8s (`10.20.20.0/24`) | 8 | 16 GB | 100 GB | 200 GB | K8s Worker Node 2 |
| `prod-k8s-worker03` | `10.20.20.33` | K8s (`10.20.20.0/24`) | 8 | 16 GB | 100 GB | 200 GB | K8s Worker Node 3 |

---

## 2. Phase-by-Phase Production Preparation on VMware vSphere

### 2.1 VMware Guest Configuration Checklist
1. **Guest OS:** Ubuntu Server 24.04 LTS (`noble`) 64-bit.
2. **SCSI Controller:** VMware Paravirtual (`PVSCSI`).
3. **Network Adapter:** `VMXNET3`.
4. **Anti-Affinity Rules:** Configure VMware DRS Host Anti-Affinity rules across `prod-k8s-cp01`, `prod-k8s-cp02`, and `prod-k8s-cp03` so the three Kubernetes control-plane VMs run on separate physical ESXi hosts.
5. **Swap & Memory Reservation:** Reserve 100% guest RAM for `prod-k8s-cp01..03` and `prod-postgres-01`.

### 2.2 Configure Static IP, DNS, Hostname, and SSH on Each Ubuntu 24.04 VM
On each newly provisioned VMware VM:

```bash
# 1. Set system hostname
sudo hostnamectl set-hostname <hostname>.internal.example.com

# 2. Configure static IP via Netplan (/etc/netplan/01-netcfg.yaml)
sudo tee /etc/netplan/01-netcfg.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens192:
      dhcp4: false
      addresses:
        - 10.20.10.10/24
      routes:
        - to: default
          via: 10.20.10.1
      nameservers:
        search: [internal.example.com]
        addresses: [10.20.1.53, 10.20.1.54]
EOF
sudo chmod 600 /etc/netplan/01-netcfg.yaml
sudo netplan apply

# 3. Create 'ansible' automation account with passwordless sudo
sudo useradd -m -s /bin/bash -G sudo ansible
echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-ansible
sudo chmod 0440 /etc/sudoers.d/90-ansible
```

From your Ansible Controller / Bastion host, distribute the SSH public key to every production VM:
```bash
ssh-keygen -t ed25519 -C "ansible@prod-bastion" -f ~/.ssh/id_ed25519
for ip in 10.20.10.{10..17} 10.20.20.{21..23} 10.20.20.{31..33}; do
  ssh-copy-id -i ~/.ssh/id_ed25519.pub "ansible@${ip}"
done
```

### 2.3 Required Corporate DNS Records (`internal.example.com`)
Create the following `A` records in your internal DNS server:
- `gitlab.internal.example.com` → `10.20.10.10`
- `jenkins.internal.example.com` → `10.20.10.11`
- `nexus.internal.example.com` → `10.20.10.12`
- `registry.internal.example.com` → `10.20.10.12`
- `rancher.internal.example.com` → `10.20.10.13`
- `prometheus.internal.example.com` → `10.20.10.14`
- `grafana.internal.example.com` → `10.20.10.14`
- `loki.internal.example.com` → `10.20.10.14`
- `minio.internal.example.com` → `10.20.10.15`
- `s3-console.internal.example.com` → `10.20.10.15`
- `vault.internal.example.com` → `10.20.10.16`
- `sonar.internal.example.com` → `10.20.10.16`
- `k8s-api.internal.example.com` → `10.20.20.20` (Keepalived + HAProxy Control Plane VIP)
- `argocd.internal.example.com` → `10.20.20.31` (or external LoadBalancer VIP fronting K8s Workers)

---

## 3. Production Ansible Configuration & Vault Encryption

### 3.1 Configure `inventories/production/hosts.yml` and `group_vars/all.yml`
1. Verify IP addresses in [`inventories/production/hosts.yml`](file:///Users/ratanakieng/labs/onprem-devops-platform/inventories/production/hosts.yml).
2. Confirm that `pod_cidr: "10.244.0.0/16"` and `service_cidr: "10.96.0.0/12"` in [`inventories/production/group_vars/all.yml`](file:///Users/ratanakieng/labs/onprem-devops-platform/inventories/production/group_vars/all.yml) do not overlap with any corporate VLAN or VPN subnet.

### 3.2 Create and Encrypt Production Secrets (`vault.yml`)
Never store plaintext production passwords in Git:
```bash
cp inventories/production/group_vars/vault.yml.example inventories/production/group_vars/vault.yml
vim inventories/production/group_vars/vault.yml   # Set strong unique passwords for every service
ansible-vault encrypt inventories/production/group_vars/vault.yml
```

---

## 4. Phased Production Deployment Execution

Execute each phase against `inventories/production/hosts.yml` using `--ask-vault-pass` (or `--vault-password-file ~/.vault_pass`) and run the validation script after every phase before continuing.

### Phase 1 & 2: OS Baseline, Kernel Hardening, NTP, SSH & UFW
```bash
# 1. Test SSH connectivity across all 14 production VMs
ansible all -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 -m ping

# 2. Apply Ubuntu 24.04 baseline role
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/common.yml --ask-vault-pass

# 3. Validate network, DNS, Chrony NTP, sysctl, and UFW
./scripts/validate-services.sh --env production --phase 2
```

### Phase 3: DevOps Core Services (GitLab, Nexus, MinIO, Jenkins)
```bash
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/gitlab.yml --ask-vault-pass
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/nexus.yml --ask-vault-pass
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/minio.yml --ask-vault-pass
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/jenkins.yml --ask-vault-pass

# Validate GitLab, Nexus, MinIO, and Jenkins endpoints
./scripts/validate-services.sh --env production --phase 3
```

### Phase 4 & 5: 3-Node HA Kubernetes, Calico CNI, Rancher & Argo CD
```bash
# 1. Deploy containerd, Keepalived + HAProxy API VIP (10.20.20.20:8443), and 3-cp + 3-worker Kubernetes v1.31.4
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/kubernetes.yml --ask-vault-pass

# 2. Deploy Calico CNI (v3.29.1) and verify all 6 nodes reach Ready
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/calico.yml --ask-vault-pass

# 3. Deploy Rancher Server (v2.10.1) and Argo CD (v2.13.2)
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/rancher.yml --ask-vault-pass
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/argocd.yml --ask-vault-pass

# 4. Validate Kubernetes HA cluster, Calico, Rancher, and Argo CD
./scripts/validate-services.sh --env production --phase 4

# 5. Register Production GitOps Applications (with manual sync approval gate)
ssh ansible@10.20.20.21 "sudo kubectl apply -f /etc/kubernetes/addons/argocd/projects.yaml"
```

### Phase 6: Monitoring (Prometheus + Grafana), Logging (Loki + Promtail) & Security (Vault)
```bash
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/monitoring.yml --ask-vault-pass
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/logging.yml --ask-vault-pass
ansible-playbook -i inventories/production/hosts.yml --private-key ~/.ssh/id_ed25519 playbooks/security.yml --ask-vault-pass

# Validate Prometheus, Grafana, and Loki health endpoints
./scripts/validate-services.sh --env production --phase 6
```

---

## 5. Manual Service Installation Reference (Step-by-Step Commands)

If an operator needs to install or inspect any service manually on a VMware Ubuntu 24.04 VM:

### 5.1 Manual HA Control Plane Load Balancer (`prod-k8s-cp01..03`)
- **Packages:** `sudo apt install -y haproxy keepalived`
- **Config files:**
  - `/etc/haproxy/haproxy.cfg` (Template: [`roles/kubernetes/templates/haproxy.cfg.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/kubernetes/templates/haproxy.cfg.j2))
  - `/etc/keepalived/keepalived.conf` (Template: [`roles/kubernetes/templates/keepalived.conf.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/kubernetes/templates/keepalived.conf.j2))
- **Verify VIP Failover:**
  ```bash
  ip addr show ens192 | grep 10.20.20.20
  nc -zv 10.20.20.20 8443
  ```

### 5.2 Manual `containerd` & `kubeadm` HA Initialization
1. Configure `/etc/containerd/config.toml` (`SystemdCgroup = true`) from [`roles/containerd/templates/config.toml.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/containerd/templates/config.toml.j2) and run `sudo systemctl restart containerd`.
2. Add Kubernetes `v1.31` repository (`/etc/apt/keyrings/kubernetes-apt-keyring.asc`) and install `kubelet=1.31.4-1.1 kubeadm=1.31.4-1.1 kubectl=1.31.4-1.1`.
3. Initialize `prod-k8s-cp01`:
   ```bash
   sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
   ```
4. Join `prod-k8s-cp02` and `prod-k8s-cp03` using `--control-plane --certificate-key <key>`.
5. Join `prod-k8s-worker01..03` and apply Calico `v3.29.1`:
   ```bash
   sudo kubectl apply -f /etc/kubernetes/addons/calico/calico.yaml
   ```

### 5.3 Manual GitLab CE, Jenkins, Nexus, MinIO, Rancher, Prometheus, Grafana & Loki
- **GitLab CE (`17.7.1-ce.0`):** Config at `/etc/gitlab/gitlab.rb` ([`roles/gitlab/templates/gitlab.rb.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/gitlab/templates/gitlab.rb.j2)); apply with `sudo gitlab-ctl reconfigure`.
- **Jenkins LTS (`2.479.3`):** Systemd override at `/etc/systemd/system/jenkins.service.d/override.conf` ([`roles/jenkins/templates/jenkins-override.conf.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/jenkins/templates/jenkins-override.conf.j2)); rootless Buildah registry config at `/etc/containers/registries.conf.d/99-nexus.conf`.
- **Nexus 3 (`3.75.1-01`):** Systemd unit at `/etc/systemd/system/nexus.service` ([`roles/nexus/templates/nexus.service.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/nexus/templates/nexus.service.j2)); data volume at `/var/lib/nexus/nexus-data`.
- **MinIO (`RELEASE.2024-12-18T13-15-44Z`):** Env file at `/etc/default/minio` ([`roles/minio/templates/minio.env.j2`](file:///Users/ratanakieng/labs/onprem-devops-platform/roles/minio/templates/minio.env.j2)); systemd unit at `/etc/systemd/system/minio.service`.
- **Prometheus (`2.53.3`), Grafana (`11.4.0`), Loki (`3.3.2`):** Configs at `/etc/prometheus/prometheus.yml`, `/etc/grafana/grafana.ini`, and `/etc/loki/loki-config.yml`.

---

## 6. Post-Deployment Production Verification & Backup

```bash
# 1. Run full end-to-end service validation across all phases
./scripts/validate-services.sh --env production --phase all

# 2. Take initial baseline backup of the production platform
./scripts/backup-platform.sh --env production --output-dir /var/backups/devops-platform
```
