#!/usr/bin/env bash
# ==============================================================================
# Docker CE 27.4.1 + Rancher v2.10.1 + Rancher CLI Installer (Ubuntu 24.04 LTS)
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
RANCHER_VER="${RANCHER_VER:-v2.10.1}"
RANCHER_CLI_VER="${RANCHER_CLI_VER:-v2.9.0}"
RANCHER_BOOTSTRAP_PASS="${RANCHER_BOOTSTRAP_PASS:-ChangeMe_RancherBootstrap_2026!}"

echo "[1/4] Installing Docker CE 27.4.1..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc >/dev/null
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce=5:27.4.1-1~ubuntu.24.04~noble \
  docker-ce-cli=5:27.4.1-1~ubuntu.24.04~noble \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
apt-mark hold docker-ce docker-ce-cli

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
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
systemctl daemon-reload
systemctl enable --now docker

echo "[2/4] Configuring rancher-container.service (${RANCHER_VER})..."
mkdir -p /var/lib/rancher /var/log/rancher/auditlog
cat >/etc/systemd/system/rancher-container.service <<EOF
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

ufw allow 80/tcp comment 'Rancher HTTP'
ufw allow 443/tcp comment 'Rancher HTTPS'

systemctl daemon-reload
systemctl enable --now rancher-container

echo "[3/4] Installing Rancher CLI (${RANCHER_CLI_VER})..."
curl -fsSL "https://github.com/rancher/cli/releases/download/${RANCHER_CLI_VER}/rancher-linux-${ARCH}-${RANCHER_CLI_VER}.tar.gz" \
  -o /tmp/rancher-cli.tar.gz
tar -xzf /tmp/rancher-cli.tar.gz -C /tmp
mv "/tmp/rancher-${RANCHER_CLI_VER}/rancher" /usr/local/bin/rancher
chmod 0755 /usr/local/bin/rancher

echo "[4/4] Verifying Docker and Rancher CLI..."
docker --version
rancher --version
echo "Rancher Server and CLI installation complete."

