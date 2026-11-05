#!/usr/bin/env bash
# ==============================================================================
# Kubernetes v1.31.4 Worker Node + containerd + crictl CLI Installer
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
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  echo "ERROR: swap is enabled; run common/install.sh first to disable swap" >&2
  exit 1
fi

K8S_PKG_VER="${K8S_PKG_VER:-1.31.4-1.1}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
K8S_CLUSTER_CIDR="${K8S_CLUSTER_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"
POD_CIDR="${POD_CIDR:-${APP_POD_CIDR:-10.244.0.0/16}}"
SVC_CIDR="${SVC_CIDR:-${APP_SVC_CIDR:-10.96.0.0/12}}"

echo "[1/3] Installing and configuring containerd..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd curl gpg

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

echo "[3/3] Opening Worker Node UFW ports (scoped to ${K8S_CLUSTER_CIDR})..."
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 10250 proto tcp comment 'Kubelet API'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 179 proto tcp comment 'Calico BGP'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 4789 proto udp comment 'Calico VXLAN'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 30000:32767 proto tcp comment 'Kubernetes NodePort Services'
ufw allow from "${POD_CIDR}" to any comment 'Kubernetes Pod Subnet'
ufw allow from "${SVC_CIDR}" to any comment 'Kubernetes Service Subnet'
ufw allow 80/tcp comment 'Ingress HTTP'
ufw allow 443/tcp comment 'Ingress HTTPS'

if [[ -n "${KUBEADM_JOIN_CMD:-}" && ! -f /etc/kubernetes/kubelet.conf ]]; then
  echo "Joining cluster with KUBEADM_JOIN_CMD..."
  eval "${KUBEADM_JOIN_CMD}"
fi

kubeadm version
crictl --version
echo "Kubernetes Worker prerequisites installed. Run the worker join command from /root/k8s-join-commands.sh on CP01."
