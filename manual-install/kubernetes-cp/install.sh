#!/usr/bin/env bash
# ==============================================================================
# Kubernetes v1.31.4 Control Plane + Calico v3.29.1 + Argo CD v2.13.2 + CLIs
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
K8S_VER="${K8S_VER:-1.31.4}"
K8S_PKG_VER="${K8S_PKG_VER:-1.31.4-1.1}"
CALICO_VER="${CALICO_VER:-v3.29.1}"
ARGOCD_VER="${ARGOCD_VER:-v2.13.2}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${NODE_IP}:6443}"
ALLOW_WORKLOADS_ON_CP="${ALLOW_WORKLOADS_ON_CP:-true}"

echo "[1/6] Installing and configuring containerd..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|g' /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

echo "[2/6] Installing kubeadm, kubelet, and kubectl (${K8S_PKG_VER})..."
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
  "kubelet=${K8S_PKG_VER}" "kubeadm=${K8S_PKG_VER}" "kubectl=${K8S_PKG_VER}"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock \
              --set image-endpoint=unix:///run/containerd/containerd.sock

echo "[3/6] Opening UFW ports and initializing Kubernetes Control Plane..."
ufw allow 6443/tcp comment 'Kubernetes API Server'
ufw allow 2379:2380/tcp comment 'etcd Server Client API'
ufw allow 10250/tcp comment 'Kubelet API'
ufw allow 10257/tcp comment 'kube-controller-manager'
ufw allow 10259/tcp comment 'kube-scheduler'
ufw allow 179/tcp comment 'Calico BGP'
ufw allow 4789/udp comment 'Calico VXLAN'
ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  cat >/etc/kubernetes/kubeadm-config.yaml <<EOF
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
kubernetesVersion: "v${K8S_VER}"
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
  kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
if [[ "${ALLOW_WORKLOADS_ON_CP}" == "true" ]]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
fi

echo "[4/6] Installing Calico CNI (${CALICO_VER}) and calicoctl CLI..."
mkdir -p /etc/kubernetes/addons/calico
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
  -o /etc/kubernetes/addons/calico/calico.yaml
kubectl apply -f /etc/kubernetes/addons/calico/calico.yaml

curl -fsSL "https://github.com/projectcalico/calico/releases/download/${CALICO_VER}/calicoctl-linux-${ARCH}" \
  -o /usr/local/bin/calicoctl
chmod 0755 /usr/local/bin/calicoctl

echo "[5/6] Installing Argo CD (${ARGOCD_VER}) and argocd CLI..."
mkdir -p /etc/kubernetes/addons/argocd
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VER}/manifests/install.yaml" \
  -o /etc/kubernetes/addons/argocd/install.yaml
kubectl apply -n argocd -f /etc/kubernetes/addons/argocd/install.yaml

kubectl patch svc argocd-server -n argocd --type merge -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      {"name": "http", "port": 80, "targetPort": 8080, "nodePort": 30080, "protocol": "TCP"},
      {"name": "https", "port": 443, "targetPort": 8080, "nodePort": 30443, "protocol": "TCP"}
    ]
  }
}'

curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VER}/argocd-linux-${ARCH}" \
  -o /usr/local/bin/argocd
chmod 0755 /usr/local/bin/argocd

echo "[6/6] Verifying Kubernetes Control Plane, Calico, and Argo CD CLIs..."
kubectl get nodes -o wide
calicoctl version
argocd version --client
echo "Kubernetes Control Plane, Calico, and Argo CD installation complete."

