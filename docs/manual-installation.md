# Manual Server-by-Server Installation Guide (Ubuntu Server 24.04 LTS)

This guide provides **complete, copy-pasteable manual installation instructions for every server** in the On-Premises DevOps Platform on **Ubuntu Server 24.04 LTS (`noble`)**, matching the exact versions, systemd units, security controls, and configurations enforced by our Ansible roles.

> **Per-Server Folders & Automated Scripts (`manual-install/`):** Each server also has its own dedicated folder in [`manual-install/`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/README.md) containing a server-specific `README.md` (with full CLI reference) and an executable `install.sh` script.

---

## Server Topology Quick Reference

| # | Server Role | Local Hostname (`192.168.252.x`) | Production Hostname (`10.20.x.x`) | Installed Services & Pinned Versions |
| :--- | :--- | :--- | :--- | :--- |
| **0** | **All Servers (Baseline)** | All VMs | All 14 VMs | Kernel hardening, Swap off, Chrony, SSH hardening, UFW, `auditd`, Node Exporter (`1.8.2`), Promtail (`3.3.2`) |
| **1** | **GitLab Server** | `devops-gitlab` (`.10`) | `prod-gitlab-01` (`10.20.10.10`) | GitLab CE (`17.7.1-ce.0`) |
| **2** | **Nexus Server** | `devops-nexus` (`.12`) | `prod-nexus-01` (`10.20.10.12`) | OpenJDK 17, Sonatype Nexus (`3.75.1-01`) |
| **3** | **MinIO S3 Server** | `devops-nexus` (`.12`) | `prod-minio-01` (`10.20.10.15`) | MinIO Server (`RELEASE.2024-12-18T13-15-44Z`) + `mc` CLI |
| **4** | **Jenkins CI Server** | `devops-jenkins` (`.11`) | `prod-jenkins-01` (`10.20.10.11`) | OpenJDK 17, Jenkins LTS (`2.479.3`), Rootless Buildah/Podman/Skopeo, Trivy (`0.58.1`), `kubectl`, `helm` |
| **5** | **Rancher Server** | `devops-rancher` (`.13`) | `prod-rancher-01` (`10.20.10.13`) | Docker CE (`27.4.1`), Rancher Server (`v2.10.1`) |
| **6** | **K8s Control Plane(s)** | `k8s-cp01` (`.21` / `.24`) | `prod-k8s-cp01..03` (`10.20.20.21..23`, VIP `.20`) | HAProxy + Keepalived (Prod HA), `containerd`, Kubernetes (`1.31.4-1.1`), Calico (`v3.29.1`), Argo CD (`v2.13.2`) |
| **7** | **K8s Worker Nodes** | `k8s-worker01..02` (`.31..32`) | `prod-k8s-worker01..03` (`10.20.20.31..33`) | `containerd`, `kubelet` + `kubeadm` (`1.31.4-1.1`), Calico Node agent |
| **8** | **Monitoring & Logging Server** | `devops-monitor` (`.14` / `.25`) | `prod-monitor-01` (`10.20.10.14`) | Prometheus (`2.53.3`), Grafana (`11.4.0`), Loki (`3.3.2`) |
| **9** | **Security & Vault Server** | `devops-monitor` (`.14` / `.25`) | `prod-secops-01` (`10.20.10.16`) | HashiCorp Vault (`1.18.3`) |

---

## 0. Common Baseline Setup (Run on EVERY Server First)

Execute these steps on **every Ubuntu 24.04 server** before installing its role-specific software.

### 0.1 Install Base Packages & Disable Swap
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  software-properties-common jq unzip tar git vim htop iotop \
  net-tools dnsutils iproute2 iputils-ping lsof ufw fail2ban \
  chrony auditd audispd-plugins acl

# Permanently disable swap (mandatory for Kubernetes & consistent JVM/memory behavior)
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
```

### 0.2 Configure Kernel Modules & `sysctl` Networking Parameters
```bash
sudo tee /etc/modules-load.d/k8s-devops.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-devops-platform.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.swappiness                       = 10
vm.max_map_count                    = 262144
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
fs.file-max                         = 2097152
EOF

sudo sysctl --system
```

### 0.3 Configure `/etc/hosts`, Chrony NTP, and SSH Hardening
```bash
# Append cluster host mappings to /etc/hosts (adjust IPs for local vs. production)
sudo tee -a /etc/hosts >/dev/null <<'EOF'
# --- On-Premises DevOps Platform Hosts ---
10.20.10.10  prod-gitlab-01.internal.example.com prod-gitlab-01
10.20.10.11  prod-jenkins-01.internal.example.com prod-jenkins-01
10.20.10.12  prod-nexus-01.internal.example.com prod-nexus-01
10.20.10.13  prod-rancher-01.internal.example.com prod-rancher-01
10.20.10.14  prod-monitor-01.internal.example.com prod-monitor-01
10.20.10.15  prod-minio-01.internal.example.com prod-minio-01
10.20.10.16  prod-secops-01.internal.example.com prod-secops-01
10.20.20.20  k8s-api.internal.example.com
10.20.20.21  prod-k8s-cp01.internal.example.com prod-k8s-cp01
10.20.20.22  prod-k8s-cp02.internal.example.com prod-k8s-cp02
10.20.20.23  prod-k8s-cp03.internal.example.com prod-k8s-cp03
10.20.20.31  prod-k8s-worker01.internal.example.com prod-k8s-worker01
10.20.20.32  prod-k8s-worker02.internal.example.com prod-k8s-worker02
10.20.20.33  prod-k8s-worker03.internal.example.com prod-k8s-worker03
EOF

# Enable Chrony NTP synchronization
sudo systemctl enable --now chrony
chronyc tracking

# Harden SSH daemon
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sudo sshd -t && sudo systemctl reload ssh
```

### 0.4 Enable Base UFW Firewall & `auditd` Rules
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw --force enable

# Configure Linux auditd rules
sudo tee /etc/audit/rules.d/99-devops-audit.rules >/dev/null <<'EOF'
-D
-b 8192
-f 1
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/kubernetes/ -p wa -k kubernetes_config
EOF
sudo augenrules --load
sudo systemctl enable --now auditd
```

### 0.5 Install Prometheus Node Exporter (`1.8.2`) on Every Server
```bash
NODE_EXP_VER="1.8.2"
ARCH="amd64"   # Change to "arm64" on Apple Silicon / ARM64 hosts

sudo groupadd --system node_exporter || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g node_exporter node_exporter || true

curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXP_VER}/node_exporter-${NODE_EXP_VER}.linux-${ARCH}.tar.gz" \
  -o /tmp/node_exporter.tar.gz
tar -xzf /tmp/node_exporter.tar.gz -C /tmp
sudo cp "/tmp/node_exporter-${NODE_EXP_VER}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter
sudo chmod 0755 /usr/local/bin/node_exporter

sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=0.0.0.0:9100 \
  --collector.systemd \
  --collector.processes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 9100/tcp comment 'Prometheus Node Exporter'
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
curl -fsS http://127.0.0.1:9100/metrics | head -n 5
```

### 0.6 Install Promtail Log Shipper (`3.3.2`) on Every Server
> Set `LOKI_SERVER_IP` to your Monitoring/Logging server IP (`192.168.252.25` locally or `10.20.10.14` in production).

```bash
LOKI_VER="3.3.2"
ARCH="amd64"   # Change to "arm64" on Apple Silicon / ARM64 hosts
LOKI_SERVER_IP="10.20.10.14"

sudo mkdir -p /etc/promtail /var/lib/promtail
curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/promtail-linux-${ARCH}.zip" \
  -o /tmp/promtail.zip
sudo unzip -o /tmp/promtail.zip -d /tmp
sudo mv "/tmp/promtail-linux-${ARCH}" /usr/local/bin/promtail
sudo chmod 0755 /usr/local/bin/promtail

sudo tee /etc/promtail/promtail-config.yml >/dev/null <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://${LOKI_SERVER_IP}:3100/loki/api/v1/push

scrape_configs:
  - job_name: system-logs
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          host: $(hostname -s)
          __path__: /var/log/*.log
  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          host: $(hostname -s)
          __path__: /var/log/syslog
EOF

sudo tee /etc/systemd/system/promtail.service >/dev/null <<'EOF'
[Unit]
Description=Promtail Log Shipping Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now promtail
```

---

## 1. Server 1: GitLab Server (`devops-gitlab` / `prod-gitlab-01`)

- **Target Host:** `devops-gitlab` (`192.168.252.10`) or `prod-gitlab-01` (`10.20.10.10`)
- **Version:** `gitlab-ce=17.7.1-ce.0`

### 1.1 Install Dependencies & Add Official GitLab Repository
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssh-server ca-certificates tzdata perl

curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
```

### 1.2 Install Pinned GitLab CE Package
```bash
GITLAB_URL="http://gitlab.internal.example.com"   # Or http://192.168.252.10 for local
GITLAB_ROOT_PASS="ChangeMe_GitLabRootPass_2026!"

sudo EXTERNAL_URL="${GITLAB_URL}" \
  GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASS}" \
  DEBIAN_FRONTEND=noninteractive \
  apt-get install -y gitlab-ce=17.7.1-ce.0
sudo apt-mark hold gitlab-ce
```

### 1.3 Configure `/etc/gitlab/gitlab.rb` (Memory-Tuned & Prometheus Enabled)
```bash
sudo tee /etc/gitlab/gitlab.rb >/dev/null <<EOF
external_url '${GITLAB_URL}'
gitlab_rails['time_zone'] = 'UTC'
gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASS}'

# Tune Puma & Sidekiq workers
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10

# Built-in Prometheus monitoring disabled in favor of external Prometheus server
prometheus_monitoring['enable'] = false
gitlab_exporter['enable'] = true

# Backup retention (7 days)
gitlab_rails['backup_keep_time'] = 604800
EOF

sudo chmod 0600 /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure
```

### 1.4 Open Firewall Ports & Verify GitLab Health
```bash
sudo ufw allow 80/tcp comment 'GitLab HTTP'
sudo ufw allow 443/tcp comment 'GitLab HTTPS'

# Verify all GitLab services are up
sudo gitlab-ctl status
curl -fsS http://127.0.0.1/-/readiness
```

---

## 2. Server 2: Nexus Repository Server (`devops-nexus` / `prod-nexus-01`)

- **Target Host:** `devops-nexus` (`192.168.252.12`) or `prod-nexus-01` (`10.20.10.12`)
- **Version:** Sonatype Nexus Repository OSS `3.75.1-01` + OpenJDK 17

### 2.1 Install OpenJDK 17 & Create `nexus` System User
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jre-headless

sudo groupadd --system nexus || true
sudo useradd --system --home-dir /var/lib/nexus --create-home --shell /bin/bash -g nexus nexus || true
sudo mkdir -p /opt/nexus /var/lib/nexus
```

### 2.2 Download & Extract Nexus `3.75.1-01`
```bash
NEXUS_VER="3.75.1-01"
curl -fsSL "https://download.sonatype.com/nexus/3/nexus-${NEXUS_VER}-unix.tar.gz" -o /tmp/nexus.tar.gz
sudo tar -xzf /tmp/nexus.tar.gz -C /opt/nexus --strip-components=1
sudo mv /opt/nexus/sonatype-work /var/lib/nexus/ || true
sudo chown -R nexus:nexus /opt/nexus /var/lib/nexus
```

### 2.3 Configure JVM Options (`/opt/nexus/bin/nexus.vmoptions`) & Properties
```bash
# Use 1200m for local Multipass or 4096m for production
JVM_HEAP="1200m"

sudo tee /opt/nexus/bin/nexus.vmoptions >/dev/null <<EOF
-Xms${JVM_HEAP}
-Xmx${JVM_HEAP}
-XX:MaxDirectMemorySize=${JVM_HEAP}
-XX:+UnlockDiagnosticVMOptions
-XX:+LogVMOutput
-XX:LogFile=/var/lib/nexus/nexus3/log/jvm.log
-XX:-OmitStackTraceInFastThrow
-Djava.net.preferIPv4Stack=true
-Dkaraf.home=.
-Dkaraf.base=.
-Dkaraf.etc=etc/karaf
-Djava.util.logging.config.file=etc/karaf/java.util.logging.properties
-Dkaraf.data=/var/lib/nexus/nexus3
-Dkaraf.log=/var/lib/nexus/nexus3/log
-Djava.io.tmpdir=/var/lib/nexus/nexus3/tmp
EOF

sudo tee /opt/nexus/bin/nexus.rc >/dev/null <<'EOF'
run_as_user="nexus"
EOF

sudo mkdir -p /var/lib/nexus/nexus3/etc
sudo tee /var/lib/nexus/nexus3/etc/nexus.properties >/dev/null <<'EOF'
application-port=8081
application-host=0.0.0.0
nexus.scripts.allowCreation=true
nexus.onboarding.enabled=false
EOF
sudo chown -R nexus:nexus /opt/nexus /var/lib/nexus
```

### 2.4 Create Systemd Unit, Open Firewall & Verify Nexus
```bash
sudo tee /etc/systemd/system/nexus.service >/dev/null <<'EOF'
[Unit]
Description=Sonatype Nexus Repository Manager 3
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
LimitNOFILE=65536
User=nexus
Group=nexus
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
Restart=on-abort
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 8081/tcp comment 'Nexus Web UI and REST API'
sudo ufw allow 5000/tcp comment 'Nexus Docker Hosted Registry'
sudo ufw allow 5001/tcp comment 'Nexus Docker Proxy Registry'

sudo systemctl daemon-reload
sudo systemctl enable --now nexus

# Wait ~60-90 seconds for startup, then verify health:
curl -fsS http://127.0.0.1:8081/service/rest/v1/status
```

---

## 3. Server 3: MinIO Object Storage Server (`devops-nexus` / `prod-minio-01`)

- **Target Host:** Co-located on `devops-nexus` (`192.168.252.12`) in local mode, or dedicated `prod-minio-01` (`10.20.10.15`) in production.
- **Version:** `RELEASE.2024-12-18T13-15-44Z`

### 3.1 Create `minio-user` & Install `minio` + `mc` Binaries
```bash
ARCH="amd64"   # Change to "arm64" on Apple Silicon / ARM64 hosts
MINIO_VER="RELEASE.2024-12-18T13-15-44Z"

sudo groupadd --system minio-user || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g minio-user minio-user || true
sudo mkdir -p /var/lib/minio/data /etc/minio
sudo chown -R minio-user:minio-user /var/lib/minio /etc/minio

sudo curl -fsSL "https://dl.min.io/server/minio/release/linux-${ARCH}/archive/minio.${MINIO_VER}" \
  -o /usr/local/bin/minio
sudo curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" \
  -o /usr/local/bin/mc
sudo chmod 0755 /usr/local/bin/minio /usr/local/bin/mc
```

### 3.2 Configure `/etc/default/minio` & Systemd Service
```bash
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASS="ChangeMe_MinioSecretKey_2026!"

sudo tee /etc/default/minio >/dev/null <<EOF
MINIO_VOLUMES="/var/lib/minio/data"
MINIO_OPTS="--address :9000 --console-address :9001"
MINIO_ROOT_USER="${MINIO_ROOT_USER}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASS}"
EOF
sudo chmod 0600 /etc/default/minio
sudo chown minio-user:minio-user /etc/default/minio

sudo tee /etc/systemd/system/minio.service >/dev/null <<'EOF'
[Unit]
Description=MinIO S3-Compatible Object Storage
Wants=network-online.target
After=network-online.target

[Service]
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 9000/tcp comment 'MinIO S3 API'
sudo ufw allow 9001/tcp comment 'MinIO Web Console'

sudo systemctl daemon-reload
sudo systemctl enable --now minio
```

### 3.3 Create Platform S3 Buckets & Verify Health
```bash
curl -fsS http://127.0.0.1:9000/minio/health/live

mc alias set local http://127.0.0.1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASS}"
for bucket in gitlab-backups loki-chunks terraform-state artifacts; do
  mc mb --ignore-existing "local/${bucket}"
done
mc ls local
```

---

## 4. Server 4: Jenkins CI Server (`devops-jenkins` / `prod-jenkins-01`)

- **Target Host:** `devops-jenkins` (`192.168.252.11`) or `prod-jenkins-01` (`10.20.10.11`)
- **Version:** Jenkins LTS `2.479.3` + OpenJDK 17 + Rootless Buildah/Podman + Trivy `0.58.1`
- **Security Rule:** Never install Docker daemon or expose `/var/run/docker.sock` on Jenkins. Never grant Kubernetes `cluster-admin` credentials to Jenkins.

### 4.1 Install OpenJDK 17 & Jenkins LTS (`2.479.3`)
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fontconfig openjdk-17-jre

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /etc/apt/keyrings/jenkins-keyring.asc >/dev/null

sudo tee /etc/apt/sources.list.d/jenkins.sources >/dev/null <<'EOF'
Types: deb
URIs: https://pkg.jenkins.io/debian-stable
Suites: binary/
Signed-By: /etc/apt/keyrings/jenkins-keyring.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jenkins=2.479.3
sudo apt-mark hold jenkins
```

### 4.2 Install Rootless Container Build Tools (`buildah`, `podman`, `skopeo`)
```bash
NEXUS_IP="10.20.10.12"   # Or 192.168.252.12 for local

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  buildah podman skopeo uidmap slirp4netns fuse-overlayfs

# Configure subordinate UID/GID ranges for rootless container builds
grep -q "^jenkins:" /etc/subuid || echo "jenkins:100000:65536" | sudo tee -a /etc/subuid
grep -q "^jenkins:" /etc/subgid || echo "jenkins:100000:65536" | sudo tee -a /etc/subgid

# Allow Buildah/Podman to push to internal Nexus registry on :5000/:5001
sudo mkdir -p /etc/containers/registries.conf.d
sudo tee /etc/containers/registries.conf.d/99-nexus.conf >/dev/null <<EOF
[[registry]]
location = "${NEXUS_IP}:5000"
insecure = true

[[registry]]
location = "${NEXUS_IP}:5001"
insecure = true
EOF
```

### 4.3 Install Trivy Vulnerability Scanner (`0.58.1`), `kubectl`, and `helm`
```bash
ARCH="64bit"      # Use "ARM64" on Apple Silicon / ARM64 hosts
K8S_ARCH="amd64"  # Use "arm64" on Apple Silicon / ARM64 hosts
TRIVY_VER="0.58.1"

curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}/trivy_${TRIVY_VER}_Linux-${ARCH}.tar.gz" \
  -o /tmp/trivy.tar.gz
sudo tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
sudo chmod 0755 /usr/local/bin/trivy

# Install kubectl (for manifest linting/dry-run validation only)
sudo curl -fsSL "https://dl.k8s.io/release/v1.31.4/bin/linux/${K8S_ARCH}/kubectl" -o /usr/local/bin/kubectl
sudo chmod 0755 /usr/local/bin/kubectl

# Install Helm
curl -fsSL "https://get.helm.sh/helm-v3.16.4-linux-${K8S_ARCH}.tar.gz" -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
sudo mv "/tmp/linux-${K8S_ARCH}/helm" /usr/local/bin/helm
sudo chmod 0755 /usr/local/bin/helm
```

### 4.4 Configure Jenkins Systemd Override, Firewall & Verify Health
```bash
sudo mkdir -p /etc/systemd/system/jenkins.service.d
sudo tee /etc/systemd/system/jenkins.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Xms512m -Xmx1024m"
Environment="JENKINS_PORT=8080"
EOF

sudo ufw allow 8080/tcp comment 'Jenkins Web UI'
sudo ufw allow 50000/tcp comment 'Jenkins Inbound JNLP Agents'

sudo systemctl daemon-reload
sudo systemctl enable --now jenkins
curl -fsSI http://127.0.0.1:8080/login | head -n 5
```

---

## 5. Server 5: Rancher Server (`devops-rancher` / `prod-rancher-01`)

- **Target Host:** `devops-rancher` (`192.168.252.13`) or `prod-rancher-01` (`10.20.10.13`)
- **Version:** Docker CE `27.4.1` + Rancher `v2.10.1`

### 5.1 Install Docker CE (`27.4.1`) via Official DEB822 Repository
```bash
ARCH=$(dpkg --print-architecture)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce=5:27.4.1-1~ubuntu.24.04~noble \
  docker-ce-cli=5:27.4.1-1~ubuntu.24.04~noble \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
sudo apt-mark hold docker-ce docker-ce-cli
```

### 5.2 Configure `/etc/docker/daemon.json` & Start Docker
```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now docker
```

### 5.3 Deploy Rancher Server (`v2.10.1`) via Systemd Service
```bash
RANCHER_VER="v2.10.1"
RANCHER_BOOTSTRAP_PASS="ChangeMe_RancherBootstrap_2026!"

sudo mkdir -p /var/lib/rancher /var/log/rancher/auditlog

sudo tee /etc/systemd/system/rancher-container.service >/dev/null <<EOF
[Unit]
Description=Rancher Multi-Cluster Management Server Container
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f rancher-server
ExecStart=/usr/bin/docker run --name rancher-server \\
  --privileged \\
  -p 80:80 -p 443:443 \\
  -v /var/lib/rancher:/var/lib/rancher \\
  -v /var/log/rancher/auditlog:/var/log/auditlog \\
  -e AUDIT_LEVEL=1 \\
  -e CATTLE_BOOTSTRAP_PASSWORD=${RANCHER_BOOTSTRAP_PASS} \\
  rancher/rancher:${RANCHER_VER}
ExecStop=/usr/bin/docker stop rancher-server

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 80/tcp comment 'Rancher HTTP'
sudo ufw allow 443/tcp comment 'Rancher HTTPS'

sudo systemctl daemon-reload
sudo systemctl enable --now rancher-container

# Verify Rancher health endpoint (takes ~60-90s on first start)
curl -sk https://127.0.0.1/ping
```

---

## 6. Server 6: Kubernetes Control Plane Nodes (`k8s-cp01` / `prod-k8s-cp01..03`)

- **Target Host(s):**
  - **Local (Single Control Plane):** `k8s-cp01` (`192.168.252.21` or `.24`)
  - **Production (3-Node HA Control Plane):** `prod-k8s-cp01` (`10.20.20.21`), `prod-k8s-cp02` (`10.20.20.22`), `prod-k8s-cp03` (`10.20.20.23`) fronting VIP `10.20.20.20:8443`
- **Versions:** Kubernetes `1.31.4-1.1`, Calico `v3.29.1`, Argo CD `v2.13.2`

### 6.1 (Production HA Only) Configure Keepalived + HAProxy on `prod-k8s-cp01..03`
Skip to **Section 6.2** if deploying a single-control-plane local cluster.

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy keepalived

# Configure HAProxy on all 3 control plane nodes (/etc/haproxy/haproxy.cfg)
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    retries 3
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend k8s-api-frontend
    bind *:8443
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server prod-k8s-cp01 10.20.20.21:6443 check fall 3 rise 2
    server prod-k8s-cp02 10.20.20.22:6443 check fall 3 rise 2
    server prod-k8s-cp03 10.20.20.23:6443 check fall 3 rise 2
EOF

# Configure Keepalived (/etc/keepalived/keepalived.conf)
# On prod-k8s-cp01: STATE="MASTER", PRIORITY="101"
# On prod-k8s-cp02: STATE="BACKUP", PRIORITY="100"
# On prod-k8s-cp03: STATE="BACKUP", PRIORITY="99"
STATE="MASTER"
PRIORITY="101"
IFACE="ens192"
VIP="10.20.20.20"

sudo tee /etc/keepalived/keepalived.conf >/dev/null <<EOF
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K8sHaVip2026
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_haproxy
    }
}
EOF

sudo ufw allow 8443/tcp comment 'HAProxy K8s API VIP'
sudo systemctl enable --now haproxy keepalived
```

### 6.2 Install & Configure `containerd` (`SystemdCgroup = true`)
Run on **all Control Plane and Worker nodes**:
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|g' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
sudo systemctl restart containerd
```

### 6.3 Install `kubeadm`, `kubelet`, and `kubectl` (`1.31.4-1.1`)
Run on **all Control Plane and Worker nodes**:
```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.asc >/dev/null
sudo chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.asc

sudo tee /etc/apt/sources.list.d/kubernetes.sources >/dev/null <<'EOF'
Types: deb
URIs: https://pkgs.k8s.io/core:/stable:/v1.31/deb/
Suites: /
Signed-By: /etc/apt/keyrings/kubernetes-apt-keyring.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  kubelet=1.31.4-1.1 kubeadm=1.31.4-1.1 kubectl=1.31.4-1.1
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
```

### 6.4 Open Control Plane Firewall Ports
Run on **all Control Plane nodes**:
```bash
sudo ufw allow 6443/tcp comment 'Kubernetes API Server'
sudo ufw allow 2379:2380/tcp comment 'etcd Server Client API'
sudo ufw allow 10250/tcp comment 'Kubelet API'
sudo ufw allow 10257/tcp comment 'kube-controller-manager'
sudo ufw allow 10259/tcp comment 'kube-scheduler'
sudo ufw allow 179/tcp comment 'Calico BGP'
sudo ufw allow 4789/udp comment 'Calico VXLAN'
sudo ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'
```

### 6.5 Initialize Primary Control Plane (`k8s-cp01` or `prod-k8s-cp01`)
```bash
# Set NODE_IP and CONTROL_PLANE_ENDPOINT:
# - Local single-node: NODE_IP="192.168.252.24", CONTROL_PLANE_ENDPOINT="192.168.252.24:6443"
# - Production HA:     NODE_IP="10.20.20.21",    CONTROL_PLANE_ENDPOINT="10.20.20.20:8443"
NODE_IP="192.168.252.24"
CONTROL_PLANE_ENDPOINT="192.168.252.24:6443"

sudo tee /etc/kubernetes/kubeadm-config.yaml >/dev/null <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NODE_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.31.4"
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT}"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
EOF

# Initialize cluster (add --upload-certs for Production HA)
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs

# Configure kubeconfig for your administrative user
mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# If running a single-node local cluster without worker VMs, allow workloads on cp01:
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
```

### 6.6 (Production HA Only) Join `prod-k8s-cp02` and `prod-k8s-cp03`
On `prod-k8s-cp01`, generate the certificate key and control-plane join command:
```bash
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -n 1)
Join_CMD=$(sudo kubeadm token create --print-join-command)
echo "sudo ${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY}"
```
Run that printed `sudo kubeadm join ... --control-plane --certificate-key ...` command on `prod-k8s-cp02` and `prod-k8s-cp03`.

### 6.7 Install Calico CNI (`v3.29.1`) on `k8s-cp01`
```bash
sudo mkdir -p /etc/kubernetes/addons/calico
sudo curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml \
  -o /etc/kubernetes/addons/calico/calico.yaml

kubectl apply -f /etc/kubernetes/addons/calico/calico.yaml

# Wait for Calico pods and verify nodes become Ready
kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s
kubectl get nodes -o wide
```

### 6.8 Install Argo CD (`v2.13.2`) on `k8s-cp01`
```bash
sudo mkdir -p /etc/kubernetes/addons/argocd
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

sudo curl -fsSL https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml \
  -o /etc/kubernetes/addons/argocd/install.yaml
kubectl apply -n argocd -f /etc/kubernetes/addons/argocd/install.yaml

# Expose argocd-server via NodePort (30080 HTTP / 30443 HTTPS)
kubectl patch svc argocd-server -n argocd --type merge -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      {"name": "http", "port": 80, "targetPort": 8080, "nodePort": 30080, "protocol": "TCP"},
      {"name": "https", "port": 443, "targetPort": 8080, "nodePort": 30443, "protocol": "TCP"}
    ]
  }
}'

# Wait for Argo CD deployments to become Available
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
kubectl get pods -n argocd
```

---

## 7. Server 7: Kubernetes Worker Nodes (`k8s-worker01..02` / `prod-k8s-worker01..03`)

- **Target Host(s):** `k8s-worker01..02` (`192.168.252.31..32`) or `prod-k8s-worker01..03` (`10.20.20.31..33`)

### 7.1 Install `containerd` and `kubelet`/`kubeadm` (`1.31.4-1.1`)
Run **Sections 6.2 and 6.3** above on every worker node.

### 7.2 Open Worker Node Firewall Ports
```bash
sudo ufw allow 10250/tcp comment 'Kubelet API'
sudo ufw allow 179/tcp comment 'Calico BGP'
sudo ufw allow 4789/udp comment 'Calico VXLAN'
sudo ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'
```

### 7.3 Join Worker Nodes to the Cluster
1. On `k8s-cp01` (or `prod-k8s-cp01`), print the worker join command:
   ```bash
   sudo kubeadm token create --print-join-command
   ```
2. On each worker node (`k8s-worker01..02` or `prod-k8s-worker01..03`), run the printed `sudo kubeadm join ...` command.
3. On `k8s-cp01`, label the worker nodes and verify `Ready` status:
   ```bash
   kubectl label node <worker-hostname> node-role.kubernetes.io/worker=worker --overwrite
   kubectl get nodes -o wide
   ```

---

## 8. Server 8: Monitoring & Logging Server (`devops-monitor` / `prod-monitor-01`)

- **Target Host:** `devops-monitor` (`192.168.252.14` or `.25`) or `prod-monitor-01` (`10.20.10.14`)
- **Versions:** Prometheus `2.53.3`, Grafana `11.4.0`, Loki `3.3.2`

### 8.1 Install Prometheus Server (`2.53.3`)
```bash
PROM_VER="2.53.3"
ARCH="amd64"   # Change to "arm64" on Apple Silicon / ARM64 hosts

sudo groupadd --system prometheus || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g prometheus prometheus || true
sudo mkdir -p /etc/prometheus/rules /var/lib/prometheus

curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH}.tar.gz" \
  -o /tmp/prometheus.tar.gz
tar -xzf /tmp/prometheus.tar.gz -C /tmp
sudo cp "/tmp/prometheus-${PROM_VER}.linux-${ARCH}/prometheus" /usr/local/bin/
sudo cp "/tmp/prometheus-${PROM_VER}.linux-${ARCH}/promtool" /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
```

#### Create Alert Rules (`/etc/prometheus/rules/alert.rules.yml`) & Config (`/etc/prometheus/prometheus.yml`)
```bash
sudo tee /etc/prometheus/rules/alert.rules.yml >/dev/null <<'EOF'
groups:
  - name: node_and_platform_alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node or target {{ $labels.instance }} is down"
      - alert: HighNodeMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage (>85%) on {{ $labels.instance }}"
EOF

sudo tee /etc/prometheus/prometheus.yml >/dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/alert.rules.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets:
          - '127.0.0.1:9100'
          # Add all cluster node IPs:9100 here (e.g., '192.168.252.24:9100' or '10.20.20.21:9100')
EOF

sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
promtool check config /etc/prometheus/prometheus.yml

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Time-Series Monitoring Server
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 9090/tcp comment 'Prometheus Web UI'
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
curl -fsS http://127.0.0.1:9090/-/healthy
```

### 8.2 Install Loki Log Aggregation Server (`3.3.2`)
```bash
LOKI_VER="3.3.2"
ARCH="amd64"   # Change to "arm64" on Apple Silicon / ARM64 hosts

sudo groupadd --system loki || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g loki loki || true
sudo mkdir -p /etc/loki /var/lib/loki/chunks /var/lib/loki/rules

curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/loki-linux-${ARCH}.zip" \
  -o /tmp/loki.zip
sudo unzip -o /tmp/loki.zip -d /tmp
sudo mv "/tmp/loki-linux-${ARCH}" /usr/local/bin/loki
sudo chmod 0755 /usr/local/bin/loki
sudo chown -R loki:loki /etc/loki /var/lib/loki /usr/local/bin/loki

sudo tee /etc/loki/loki-config.yml >/dev/null <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 168h
  allow_structured_metadata: true
EOF

sudo tee /etc/systemd/system/loki.service >/dev/null <<'EOF'
[Unit]
Description=Grafana Loki Log Aggregation Server
Wants=network-online.target
After=network-online.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 3100/tcp comment 'Loki HTTP API'
sudo systemctl daemon-reload
sudo systemctl enable --now loki
curl -fsS http://127.0.0.1:3100/ready
```

### 8.3 Install Grafana (`11.4.0`) & Provision Datasources
```bash
GRAFANA_PASS="ChangeMe_GrafanaAdmin_2026!"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | sudo tee /etc/apt/keyrings/grafana.asc >/dev/null
sudo chmod 0644 /etc/apt/keyrings/grafana.asc

sudo tee /etc/apt/sources.list.d/grafana.sources >/dev/null <<'EOF'
Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/grafana.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y grafana=11.4.0
sudo apt-mark hold grafana

sudo tee /etc/grafana/grafana.ini >/dev/null <<EOF
[server]
protocol = http
http_addr = 0.0.0.0
http_port = 3000

[security]
admin_user = admin
admin_password = ${GRAFANA_PASS}
cookie_secure = false

[users]
allow_sign_up = false
EOF

sudo tee /etc/grafana/provisioning/datasources/datasources.yml >/dev/null <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://127.0.0.1:3100
    isDefault: false
    editable: false
EOF

sudo ufw allow 3000/tcp comment 'Grafana Web UI'
sudo systemctl daemon-reload
sudo systemctl enable --now grafana-server
curl -fsS http://127.0.0.1:3000/api/health
```

---

## 9. Server 9: Security & Secrets Server (`devops-monitor` / `prod-secops-01`)

- **Target Host:** Co-located on `devops-monitor` (`192.168.252.25`) locally, or dedicated `prod-secops-01` (`10.20.10.16`) in production.
- **Version:** HashiCorp Vault `1.18.3`

### 9.1 Install HashiCorp Vault (`1.18.3`) Binary & User
```bash
VAULT_VER="1.18.3"
ARCH="amd64"   # Change to "arm64" on Apple Silicon / ARM64 hosts

sudo groupadd --system vault || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g vault vault || true
sudo mkdir -p /etc/vault.d /var/lib/vault/data

curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_${ARCH}.zip" \
  -o /tmp/vault.zip
sudo unzip -o /tmp/vault.zip -d /usr/local/bin
sudo chmod 0755 /usr/local/bin/vault
sudo chown -R vault:vault /etc/vault.d /var/lib/vault
```

### 9.2 Configure `/etc/vault.d/vault.hcl` & Systemd Service
```bash
sudo tee /etc/vault.d/vault.hcl >/dev/null <<'EOF'
ui = true
disable_mlock = true

storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8200"
EOF
sudo chmod 0640 /etc/vault.d/vault.hcl
sudo chown vault:vault /etc/vault.d/vault.hcl

sudo tee /etc/systemd/system/vault.service >/dev/null <<'EOF'
[Unit]
Description=HashiCorp Vault Secret Management Server
Wants=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 8200/tcp comment 'HashiCorp Vault API/UI'
sudo systemctl daemon-reload
sudo systemctl enable --now vault
```

### 9.3 Initialize & Verify Vault Status
```bash
export VAULT_ADDR="http://127.0.0.1:8200"

# Check HTTP health (200 = unsealed, 501 = not initialized, 503 = sealed)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8200/v1/sys/health

# First-time initialization (store the output keys securely offline!):
# vault operator init -key-shares=5 -key-threshold=3
```

