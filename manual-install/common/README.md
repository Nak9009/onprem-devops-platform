# Common Baseline Manual Installation & CLI Guide (`common`)

Run this baseline setup on **every Ubuntu Server 24.04 LTS (`noble`) node** before installing role-specific services.

- **Automated Script:** [`manual-install/common/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/common/install.sh)

---

## 1. Install Base Packages & Disable Swap

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  software-properties-common jq unzip tar git vim htop iotop \
  net-tools dnsutils iproute2 iputils-ping lsof ufw fail2ban \
  chrony auditd audispd-plugins acl

# Permanently disable swap
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
```

---

## 2. Configure Kernel Modules & `sysctl` Parameters

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

---

## 3. Configure Chrony NTP, SSH Hardening, UFW & `auditd`

```bash
# Enable Chrony
sudo systemctl enable --now chrony

# Harden SSHD
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

# Enable UFW Firewall
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw --force enable

# Configure auditd rules
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

---

## 4. Install Prometheus Node Exporter (`1.8.2`)

```bash
NODE_EXP_VER="1.8.2"
ARCH=$(dpkg --print-architecture) # amd64 or arm64

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
```

---

## 5. Common Baseline CLI Reference

```bash
# Check UFW firewall rules with rule numbers
sudo ufw status numbered

# Verify NTP synchronization & time offset
chronyc tracking
chronyc sources -v

# Check active kernel modules and sysctl settings
lsmod | grep -E 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables vm.max_map_count

# Query auditd security events
sudo auditctl -l
sudo ausearch -k identity -i
sudo ausearch -k sudoers -i

# Test Node Exporter metrics locally
curl -fsS http://127.0.0.1:9100/metrics | grep -E '^node_(cpu|memory|filesystem)' | head -n 15
```

