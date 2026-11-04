# Production Manual & Ansible Installation Guide (VMware vSphere + Ubuntu 24.04)

This comprehensive production runbook covers **Section 6** and **Section 15 (Topics 3, 5, 6, 8–19)**:
- VMware vSphere VM preparation & static networking
- Ansible controller setup & inventory configuration
- Manual and Ansible-automated production installation for **Kubernetes HA**, **Calico**, **Rancher**, **GitLab**, **Nexus**, **MinIO**, **Jenkins**, **Argo CD**, **Prometheus/Grafana**, and **Loki/Promtail**.

---

## 1. VMware vSphere VM Preparation (Ubuntu Server 24.04 LTS)

### 1.1 Production VM Inventory & Sizing

| Hostname | IP Address | vCPU | RAM | OS Disk | Data Disk | Role |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `prod-gitlab-01` | `10.20.10.10` | 8 | 16 GB | 80 GB | 250 GB (`/var/opt/gitlab`) | GitLab CE |
| `prod-jenkins-01` | `10.20.10.11` | 4 | 8 GB | 60 GB | 100 GB (`/var/lib/jenkins`) | Jenkins LTS + Buildah + Trivy |
| `prod-nexus-01` | `10.20.10.12` | 4 | 12 GB | 60 GB | 500 GB (`/var/lib/nexus`) | Nexus 3 Artifact & Docker Registry |
| `prod-rancher-01` | `10.20.10.13` | 4 | 8 GB | 60 GB | 80 GB (`/var/lib/rancher`) | Rancher Server |
| `prod-monitor-01` | `10.20.10.14` | 4 | 16 GB | 60 GB | 300 GB (`/var/lib/prometheus`, `/var/lib/loki`) | Prometheus, Grafana, Loki |
| `prod-minio-01` | `10.20.10.15` | 4 | 8 GB | 60 GB | 500 GB (`/var/lib/minio`) | MinIO S3 Object Storage |
| `prod-secops-01` | `10.20.10.16` | 4 | 8 GB | 60 GB | 100 GB (`/var/lib/vault`) | HashiCorp Vault & SonarQube |
| `prod-postgres-01` | `10.20.10.17` | 4 | 16 GB | 60 GB | 300 GB (`/var/lib/postgresql`) | External Production PostgreSQL |
| `prod-k8s-cp01..03` | `10.20.20.21..23` | 4 ea | 8 GB ea | 100 GB ea | - | 3x HA K8s Control Plane (VIP: `10.20.20.20`) |
| `prod-k8s-worker01..03` | `10.20.20.31..33` | 8 ea | 16 GB ea | 100 GB ea | 200 GB ea | 3x K8s Worker Nodes |

### 1.2 Step-by-Step Ubuntu 24.04 Guest Preparation on VMware
1. **Provision VM from Ubuntu 24.04 LTS Template:**
   - Enable VMware Paravirtual SCSI (`PVSCSI`) controller and `VMXNET3` network adapter.
   - Disable VM memory ballooning on `prod-k8s-cp01..03` and `prod-postgres-01`.
2. **Configure Static IP via Netplan (`/etc/netplan/01-netcfg.yaml`):**
   ```yaml
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
   ```
   Apply with:
   ```bash
   sudo chmod 600 /etc/netplan/01-netcfg.yaml
   sudo netplan apply
   ```
3. **Configure Hostname, NTP, and `ansible` Automation User:**
   ```bash
   sudo hostnamectl set-hostname prod-gitlab-01.internal.example.com
   sudo useradd -m -s /bin/bash -G sudo ansible
   echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-ansible
   sudo chmod 0440 /etc/sudoers.d/90-ansible
   ```
4. **Copy SSH Public Key from Admin Bastion:**
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub ansible@10.20.10.10
   ```

---

## 2. Ansible Installation & Production Inventory Setup

### 2.1 Install Ansible on Bastion / Management Host
```bash
sudo apt update && sudo apt install -y python3-pip python3-venv git sshpass
python3 -m venv ~/ansible-venv
source ~/ansible-venv/bin/activate
pip install --upgrade pip "ansible-core>=2.16,<2.22"
ansible-galaxy collection install -r requirements.yml
```

### 2.2 Configure Encrypted Ansible Vault for Production
```bash
cp inventories/production/group_vars/vault.yml.example inventories/production/group_vars/vault.yml
vim inventories/production/group_vars/vault.yml   # Replace all <REPLACE_WITH_STRONG_SECRET> values
ansible-vault encrypt inventories/production/group_vars/vault.yml
```

### 2.3 Verify Production Network & Baseline OS Configuration
```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/common.yml --ask-vault-pass
./scripts/validate-network.sh --env production
./scripts/health-check.sh --env production
```

---

## 3. Service Installation Runbooks (Manual & Ansible)

### 3.1 GitLab CE (`17.7.1-ce.0`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/gitlab.yml --ask-vault-pass
  ```
- **Manual Installation Commands (Reference):**
  ```bash
  sudo apt-get update && sudo apt-get install -y curl openssh-server ca-certificates tzdata perl openssl
  sudo mkdir -p /etc/gitlab/ssl && sudo chmod 700 /etc/gitlab/ssl
  # Place TLS cert at /etc/gitlab/ssl/gitlab.internal.example.com.{crt,key}
  curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
  sudo EXTERNAL_URL="https://gitlab.internal.example.com" apt-get install -y gitlab-ce=17.7.1-ce.0
  sudo gitlab-ctl reconfigure
  ```
- **Verification:**
  ```bash
  curl -ksf https://gitlab.internal.example.com/-/readiness
  sudo gitlab-ctl status
  ```

### 3.2 Sonatype Nexus Repository OSS (`3.75.1-01`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/nexus.yml --ask-vault-pass
  ```
- **Manual Installation Commands (Reference):**
  ```bash
  sudo mkdir -p /var/lib/nexus/nexus-data && sudo chown -R 200:200 /var/lib/nexus/nexus-data
  sudo docker pull sonatype/nexus3:3.75.1
  sudo systemctl enable --now nexus.service
  ```
- **Verification:**
  ```bash
  curl -sf http://127.0.0.1:8081/service/rest/v1/status
  ```

### 3.3 MinIO S3 Object Storage (`RELEASE.2024-12-18T13-15-44Z`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/minio.yml --ask-vault-pass
  ```
- **Manual Installation Commands (Reference):**
  ```bash
  sudo useradd -r -s /usr/sbin/nologin minio-user
  sudo mkdir -p /var/lib/minio/data /etc/minio && sudo chown -R minio-user:minio-user /var/lib/minio
  sudo curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2024-12-18T13-15-44Z -o /usr/local/bin/minio
  sudo chmod +x /usr/local/bin/minio
  sudo systemctl enable --now minio.service
  ```
- **Verification:**
  ```bash
  curl -sf http://127.0.0.1:9000/minio/health/live
  mc ls local/
  ```

### 3.4 Jenkins LTS (`2.479.3`) + Rootless Buildah + Trivy (`0.58.1`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/jenkins.yml --ask-vault-pass
  ```
- **Manual Installation Commands (Reference):**
  ```bash
  sudo apt-get update && sudo apt-get install -y fontconfig openjdk-21-jre-headless podman buildah skopeo uidmap fuse-overlayfs
  sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key -o /etc/apt/keyrings/jenkins-keyring.asc
  sudo apt-get update && sudo apt-get install -y jenkins=2.479.3
  sudo systemctl enable --now jenkins
  ```
- **Verification:**
  ```bash
  curl -sfI http://127.0.0.1:8080/login
  trivy --version
  sudo -u jenkins buildah version
  ```

### 3.5 Kubernetes HA Cluster (`v1.31.4`) + containerd (`1.7.24`) + Calico (`v3.29.1`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/kubernetes.yml --ask-vault-pass
  ansible-playbook -i inventories/production/hosts.yml playbooks/calico.yml --ask-vault-pass
  ```
- **Manual HA Control Plane Installation Steps (Reference):**
  1. On all 3 control-plane nodes (`prod-k8s-cp01..03`), install and start `haproxy` (`*:8443` → `10.20.20.21..23:6443`) and `keepalived` (VIP `10.20.20.20`).
  2. Configure `containerd` (`/etc/containerd/config.toml` with `SystemdCgroup = true`) and restart `containerd`.
  3. Install `kubelet=1.31.4-1.1`, `kubeadm=1.31.4-1.1`, `kubectl=1.31.4-1.1` and run `apt-mark hold kubelet kubeadm kubectl`.
  4. On `prod-k8s-cp01`:
     ```bash
     sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
     ```
  5. On `prod-k8s-cp02` and `prod-k8s-cp03`:
     ```bash
     sudo kubeadm join 10.20.20.20:8443 --token <token> --discovery-token-ca-cert-hash sha256:<hash> --control-plane --certificate-key <cert-key>
     ```
  6. On `prod-k8s-worker01..03`:
     ```bash
     sudo kubeadm join 10.20.20.20:8443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
     ```
  7. Install Calico CNI (`v3.29.1`):
     ```bash
     kubectl apply -f /etc/kubernetes/addons/calico/calico.yaml
     kubectl -n kube-system rollout status daemonset/calico-node
     ```
- **Verification:**
  ```bash
  kubectl get nodes -o wide
  kubectl get pods -n kube-system
  ```

### 3.6 Rancher (`v2.10.1`) & Argo CD (`v2.13.2`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/rancher.yml --ask-vault-pass
  ansible-playbook -i inventories/production/hosts.yml playbooks/argocd.yml --ask-vault-pass
  ```
- **Verification:**
  ```bash
  curl -ksf https://rancher.internal.example.com/ping
  kubectl get pods -n argocd
  argocd version --client
  ```

### 3.7 Monitoring (Prometheus `2.53.3` & Grafana `11.4.0`) & Logging (Loki `3.3.2`)
- **Automated Deployment:**
  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/monitoring.yml --ask-vault-pass
  ansible-playbook -i inventories/production/hosts.yml playbooks/logging.yml --ask-vault-pass
  ansible-playbook -i inventories/production/hosts.yml playbooks/security.yml --ask-vault-pass
  ```
- **Verification:**
  ```bash
  ./scripts/validate-services.sh --env production --phase all
  ```

