#!/usr/bin/env bash
# ==============================================================================
# Kubernetes v1.31.4 Worker Node + containerd + crictl CLI Installer
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

K8S_PKG_VER="${K8S_PKG_VER:-1.31.4-1.1}"

echo "[1/3] Installing and configuring containerd..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|g' /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

echo "[2/3] Installing kubelet and kubeadm (${K8S_PKG_VER})..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | tee /etc/apt/keyrings/kubernetes-apt-keyring.asc >/dev/null
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.asc

cat >/etc/apt/sources.list.d/kubernetes.sources <<'EOF'
Types: deb
URIs: https://pkgs.k8s.io/core:/stable:/v1.31/deb/
Suites: /
Signed-By: /etc/apt/keyrings/kubernetes-apt-keyring.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "kubelet=${K8S_PKG_VER}" "kubeadm=${K8S_PKG_VER}"
apt-mark hold kubelet kubeadm
systemctl enable kubelet

crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock \
              --set image-endpoint=unix:///run/containerd/containerd.sock

echo "[3/3] Opening Worker Node UFW ports..."
ufw allow 10250/tcp comment 'Kubelet API'
ufw allow 179/tcp comment 'Calico BGP'
ufw allow 4789/udp comment 'Calico VXLAN'
ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'

kubeadm version
crictl --version
echo "Kubernetes Worker prerequisites installed. Run 'sudo kubeadm join ...' to join the cluster."

