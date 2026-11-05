#!/usr/bin/env bash
# ==============================================================================
# Common Baseline Installer for Ubuntu Server 24.04 LTS
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  # shellcheck disable=SC1090
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./install.sh)" >&2
  exit 1
fi

NODE_EXP_VER="${NODE_EXP_VER:-1.8.2}"
ARCH="$(dpkg --print-architecture)"

echo "[1/5] Installing baseline packages & disabling swap..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  software-properties-common jq unzip tar git vim htop iotop \
  net-tools dnsutils iproute2 iputils-ping lsof ufw fail2ban \
  chrony auditd audispd-plugins acl

swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

echo "[2/5] Configuring kernel modules and sysctl..."
cat >/etc/modules-load.d/k8s-devops.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-devops-platform.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.swappiness                       = 10
vm.max_map_count                    = 262144
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
fs.file-max                         = 2097152
EOF
sysctl --system

echo "[3/5] Enabling Chrony, SSH hardening, UFW, and auditd..."
systemctl enable --now chrony

# Refuse to disable password auth unless some account has an authorized key
if ! compgen -G "/home/*/.ssh/authorized_keys" >/dev/null && [[ ! -s /root/.ssh/authorized_keys ]]; then
  echo "ERROR: no SSH authorized_keys found; refusing to disable password auth (lockout risk)." >&2
  exit 1
fi

cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t && systemctl reload ssh

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw --force enable

cat >/etc/audit/rules.d/99-devops-audit.rules <<'EOF'
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
augenrules --load || true
systemctl enable --now auditd

echo "[4/5] Installing Prometheus Node Exporter v${NODE_EXP_VER}..."
groupadd --system node_exporter 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g node_exporter node_exporter 2>/dev/null || true

NE_TMP="$(mktemp -d)"
trap 'rm -rf "${NE_TMP}"' EXIT
NE_BASE="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXP_VER}"
NE_TAR="node_exporter-${NODE_EXP_VER}.linux-${ARCH}.tar.gz"
curl -fsSL "${NE_BASE}/${NE_TAR}" -o "${NE_TMP}/${NE_TAR}"
curl -fsSL "${NE_BASE}/sha256sums.txt" -o "${NE_TMP}/sha256sums.txt"
(cd "${NE_TMP}" && grep " ${NE_TAR}\$" sha256sums.txt | sha256sum -c -)
tar -xzf "${NE_TMP}/${NE_TAR}" -C "${NE_TMP}"
cp "${NE_TMP}/node_exporter-${NODE_EXP_VER}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter
chown node_exporter:node_exporter /usr/local/bin/node_exporter
chmod 0755 /usr/local/bin/node_exporter

cat >/etc/systemd/system/node_exporter.service <<'EOF'
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

if [[ -n "${MONITOR_IP:-}" ]]; then
  ufw allow from "${MONITOR_IP}" to any port 9100 proto tcp comment 'Prometheus Node Exporter'
else
  echo "WARN: MONITOR_IP unset; opening 9100 to all" >&2
  ufw allow 9100/tcp comment 'Prometheus Node Exporter'
fi
systemctl daemon-reload
systemctl enable --now node_exporter

echo "[5/5] Verifying baseline services..."
curl -fsS http://127.0.0.1:9100/metrics | head -n 5
echo "Common baseline installation complete."

