#!/usr/bin/env bash
# ==============================================================================
# Kubernetes v1.31.4 Control Plane + HA VIP + Calico v3.29.1 + Argo CD Installer
#
# Supports two modes automatically (detected from NODE_IP vs platform.env):
#   * 3-Node HA Control Plane (production):
#       - Layer 2 Mgmt Cluster:  K8S_MGMT_CP01..03_IP + K8S_MGMT_VIP
#       - Layer 3 App Cluster:   K8S_APP_CP01..03_IP  + K8S_APP_VIP
#     Installs HAProxy (:8443 -> CP1..3 :6443) + Keepalived (VIP) on all 3 CP
#     nodes. Node 1 runs `kubeadm init` against VIP:8443 and prints the exact
#     control-plane and worker join commands. Nodes 2 and 3 join as CP when
#     KUBEADM_JOIN_CMD is provided, or wait for you to run the printed join command.
#   * Single Control Plane (local lab):
#     Initializes directly on NODE_IP:6443.
#
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

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

ARCH="$(dpkg --print-architecture)"
K8S_VER="${K8S_VER:-1.31.4}"
K8S_PKG_VER="${K8S_PKG_VER:-1.31.4-1.1}"
CALICO_VER="${CALICO_VER:-v3.29.1}"
ARGOCD_VER="${ARGOCD_VER:-v2.13.2}"
NODE_NAME="$(hostname -s)"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
K8S_VRRP_PASS="${K8S_VRRP_PASS:-ChangeMe_K8sVrrp}"
K8S_CLUSTER_CIDR="${K8S_CLUSTER_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"

# ---- Detect Cluster Tier (Mgmt vs App) & HA Topology -------------------------
CLUSTER_TIER="${CLUSTER_TIER:-}"
CP_INDEX=1
HA_MODE=false
CP_IPS=()
API_VIP=""

if [[ -z "${CLUSTER_TIER}" ]]; then
  if [[ "${INSTALL_ARGOCD:-false}" == "true" ]] || [[ "${NODE_IP}" == "${K8S_MGMT_CP01_IP:-}" || "${NODE_IP}" == "${K8S_MGMT_CP02_IP:-}" || "${NODE_IP}" == "${K8S_MGMT_CP03_IP:-}" ]]; then
    CLUSTER_TIER="mgmt"
  else
    CLUSTER_TIER="app"
  fi
fi

if [[ "${CLUSTER_TIER}" == "mgmt" ]]; then
  POD_CIDR="${POD_CIDR:-${MGMT_POD_CIDR:-10.243.0.0/16}}"
  SVC_CIDR="${SVC_CIDR:-${MGMT_SVC_CIDR:-10.95.0.0/16}}"
  INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
  VRRP_ROUTER_ID=31
  if [[ -n "${K8S_MGMT_CP01_IP:-}" && -n "${K8S_MGMT_CP02_IP:-}" && -n "${K8S_MGMT_CP03_IP:-}" && "${K8S_MGMT_CP01_IP}" != "${K8S_MGMT_CP02_IP}" ]]; then
    CP_IPS=("${K8S_MGMT_CP01_IP}" "${K8S_MGMT_CP02_IP}" "${K8S_MGMT_CP03_IP}")
    API_VIP="${K8S_MGMT_VIP:-}"
  fi
else
  POD_CIDR="${POD_CIDR:-${APP_POD_CIDR:-10.244.0.0/16}}"
  SVC_CIDR="${SVC_CIDR:-${APP_SVC_CIDR:-10.96.0.0/12}}"
  INSTALL_ARGOCD="${INSTALL_ARGOCD:-false}"
  VRRP_ROUTER_ID=41
  if [[ -n "${K8S_APP_CP01_IP:-}" && -n "${K8S_APP_CP02_IP:-}" && -n "${K8S_APP_CP03_IP:-}" && "${K8S_APP_CP01_IP}" != "${K8S_APP_CP02_IP}" ]]; then
    CP_IPS=("${K8S_APP_CP01_IP}" "${K8S_APP_CP02_IP}" "${K8S_APP_CP03_IP}")
    API_VIP="${K8S_APP_VIP:-}"
  fi
fi

if [[ ${#CP_IPS[@]} -eq 3 && -n "${API_VIP}" ]]; then
  for i in 0 1 2; do
    if [[ "${CP_IPS[$i]}" == "${NODE_IP}" ]]; then
      HA_MODE=true
      CP_INDEX=$((i + 1))
    fi
  done
fi

if [[ "${HA_MODE}" == "true" ]]; then
  API_PORT="${K8S_API_PORT:-8443}"
  CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${API_VIP}:${API_PORT}}"
  # Mgmt cluster has no separate workers by default, so allow workloads on Mgmt CP; App cluster keeps CP tainted in production
  if [[ "${CLUSTER_TIER}" == "mgmt" ]]; then
    ALLOW_WORKLOADS_ON_CP="${ALLOW_WORKLOADS_ON_CP:-true}"
  else
    ALLOW_WORKLOADS_ON_CP="${ALLOW_WORKLOADS_ON_CP:-false}"
  fi
else
  API_PORT=6443
  CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${NODE_IP}:6443}"
  ALLOW_WORKLOADS_ON_CP="${ALLOW_WORKLOADS_ON_CP:-true}"
fi

if [[ "${PLATFORM_ENV:-}" == "production" && "${HA_MODE}" == "true" && "${K8S_VRRP_PASS}" == ChangeMe_* ]]; then
  echo "ERROR: set a real K8S_VRRP_PASS before a production HA install" >&2
  exit 1
fi

echo "Kubernetes CP (${CLUSTER_TIER}): ha=${HA_MODE} cp_index=${CP_INDEX} endpoint=${CONTROL_PLANE_ENDPOINT} pod_cidr=${POD_CIDR} svc_cidr=${SVC_CIDR}"

echo "[1/6] Installing and configuring containerd..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd curl gpg openssl

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

echo "[3/6] Configuring UFW firewall rules (scoped to ${K8S_CLUSTER_CIDR}) and HA VIP..."
# API server (6443 and HAProxy 8443) + NodePorts restricted to internal networks
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 6443 proto tcp comment 'Kubernetes API Server'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 8443 proto tcp comment 'Kubernetes HAProxy VIP'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 10250 proto tcp comment 'Kubelet API'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 179 proto tcp comment 'Calico BGP'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 4789 proto udp comment 'Calico VXLAN'
ufw allow from "${K8S_CLUSTER_CIDR}" to any port 30000:32767 proto tcp comment 'Kubernetes NodePort Services'
ufw allow from "${POD_CIDR}" to any comment 'Kubernetes Pod Subnet'
ufw allow from "${SVC_CIDR}" to any comment 'Kubernetes Service Subnet'

if [[ "${HA_MODE}" == "true" ]]; then
  for peer in "${CP_IPS[@]}"; do
    ufw allow from "${peer}" to any port 2379:2380 proto tcp comment 'etcd peer/client'
    ufw allow from "${peer}" to any port 10257 proto tcp comment 'kube-controller-manager'
    ufw allow from "${peer}" to any port 10259 proto tcp comment 'kube-scheduler'
  done

  DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy keepalived
  echo 'net.ipv4.ip_nonlocal_bind = 1' >/etc/sysctl.d/98-k8s-haproxy.conf
  sysctl --system >/dev/null

  cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 3000
    daemon

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    retries                 3
    timeout queue           1m
    timeout connect         10s
    timeout client          1h
    timeout server          1h
    timeout check           5s

frontend k8s_apiserver
    bind *:${API_PORT}
    default_backend k8s_cp_nodes

backend k8s_cp_nodes
    option tcp-check
    balance roundrobin
    server cp01 ${CP_IPS[0]}:6443 check fall 3 rise 2
    server cp02 ${CP_IPS[1]}:6443 check fall 3 rise 2
    server cp03 ${CP_IPS[2]}:6443 check fall 3 rise 2
EOF
  haproxy -c -f /etc/haproxy/haproxy.cfg

  IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  STATE="BACKUP"; [[ "${CP_INDEX}" == "1" ]] && STATE="MASTER"
  PRIO=$((150 - CP_INDEX * 10))
  PEER_LINES=""
  for peer in "${CP_IPS[@]}"; do
    [[ "${peer}" != "${NODE_IP}" ]] && PEER_LINES+="        ${peer}"$'\n'
  done

  cat >/etc/keepalived/keepalived.conf <<EOF
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/bin/pidof haproxy"
    interval 2
    fall 2
    rise 2
}

vrrp_instance K8S_API_VIP {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id ${VRRP_ROUTER_ID}
    priority ${PRIO}
    advert_int 1
    unicast_src_ip ${NODE_IP}
    unicast_peer {
${PEER_LINES}    }
    authentication {
        auth_type PASS
        auth_pass ${K8S_VRRP_PASS:0:8}
    }
    virtual_ipaddress {
        ${API_VIP}/24 dev ${IFACE}
    }
    track_script {
        chk_haproxy
    }
}
EOF
  chmod 0600 /etc/keepalived/keepalived.conf
  for peer in "${CP_IPS[@]}"; do
    [[ "${peer}" == "${NODE_IP}" ]] && continue
    if ! grep -q "k8s-vrrp-${peer}" /etc/ufw/before.rules; then
      sed -i "0,/^# End required lines/s//# End required lines\n# k8s-vrrp-${peer}\n-A ufw-before-input -p 112 -s ${peer} -j ACCEPT/" /etc/ufw/before.rules
    fi
  done
  ufw reload
  systemctl enable haproxy keepalived
  systemctl restart haproxy keepalived
  sleep 2
fi

# ---- Secondary HA Control Plane Nodes (CP02 / CP03) --------------------------
if [[ "${HA_MODE}" == "true" && "${CP_INDEX}" != "1" ]]; then
  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    if [[ -n "${KUBEADM_JOIN_CMD:-}" ]]; then
      echo "[4/6] Joining secondary control plane node ${NODE_NAME} to ${CONTROL_PLANE_ENDPOINT}..."
      eval "${KUBEADM_JOIN_CMD}"
    else
      cat <<EOF

Secondary Control Plane node ${NODE_NAME} (${NODE_IP}) prerequisites and HA VIP are ready.
Now copy and run the 'kubeadm join ... --control-plane --certificate-key ...' command
printed on CP01 (${CP_IPS[0]}) (saved in /root/k8s-join-commands.sh on CP01).
EOF
      exit 0
    fi
  fi
  export KUBECONFIG=/etc/kubernetes/admin.conf
  mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chmod 0600 /root/.kube/config
  kubectl get nodes -o wide
  exit 0
fi

# ---- Primary Control Plane Node (CP01 or Single Node) ------------------------
echo "[4/6] Initializing Kubernetes Control Plane (${CONTROL_PLANE_ENDPOINT})..."
if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  CERT_SANS="    - \"127.0.0.1\"
    - \"${NODE_IP}\"
    - \"${NODE_NAME}\""
  if [[ "${HA_MODE}" == "true" ]]; then
    CERT_SANS+="
    - \"${API_VIP}\""
    for peer in "${CP_IPS[@]}"; do CERT_SANS+=$'\n'"    - \"${peer}\""; done
  fi

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
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SVC_CIDR}"
  dnsDomain: "cluster.local"
apiServer:
  certSANs:
${CERT_SANS}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
serverTLSBootstrap: true
EOF
  chmod 0600 /etc/kubernetes/kubeadm-config.yaml
  kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 0600 /root/.kube/config
# Copy kubeconfig to operator accounts only when explicitly requested (default in non-production)
if [[ "${COPY_USER_KUBECONFIG:-$([[ "${PLATFORM_ENV:-}" == "production" ]] && echo false || echo true)}" == "true" ]]; then
  for user_home in /home/ubuntu /home/ansible; do
    if [[ -d "${user_home}" ]]; then
      mkdir -p "${user_home}/.kube"
      cp -f /etc/kubernetes/admin.conf "${user_home}/.kube/config"
      chown -R "$(stat -c '%u:%g' "${user_home}")" "${user_home}/.kube"
      chmod 0600 "${user_home}/.kube/config"
    fi
  done
fi

if [[ "${ALLOW_WORKLOADS_ON_CP}" == "true" ]]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
fi

# Save join commands for secondary CP nodes and workers
WORKER_JOIN="$(kubeadm token create --print-join-command)"
if [[ "${HA_MODE}" == "true" ]]; then
  CERT_KEY="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1)"
  CP_JOIN="${WORKER_JOIN} --control-plane --certificate-key ${CERT_KEY} --apiserver-advertise-address <THIS_CP_NODE_IP>"
else
  CP_JOIN="# (Single-CP mode: enable HA_MODE with K8S_*_CP01..03_IP + VIP to join additional control planes)"
fi
cat >/root/k8s-join-commands.sh <<EOF
# Generated on $(date -Is) on ${NODE_NAME}
# 1. Join Secondary Control Plane Nodes (CP02 / CP03):
${CP_JOIN}

# 2. Join Worker Nodes:
${WORKER_JOIN}
EOF
chmod 0600 /root/k8s-join-commands.sh

echo "[5/6] Installing Calico CNI (${CALICO_VER}) and calicoctl CLI..."
mkdir -p /etc/kubernetes/addons/calico
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
  -o /etc/kubernetes/addons/calico/calico.yaml
kubectl apply -f /etc/kubernetes/addons/calico/calico.yaml

CALICO_TMP="$(mktemp -d)"
trap 'rm -rf "${CALICO_TMP}"' EXIT
CALICO_BASE="https://github.com/projectcalico/calico/releases/download/${CALICO_VER}"
curl -fsSL "${CALICO_BASE}/calicoctl-linux-${ARCH}" -o "${CALICO_TMP}/calicoctl-linux-${ARCH}"
if curl -fsSL "${CALICO_BASE}/SHA256SUMS" -o "${CALICO_TMP}/SHA256SUMS" 2>/dev/null; then
  (cd "${CALICO_TMP}" && grep " calicoctl-linux-${ARCH}\$" SHA256SUMS | sha256sum -c -)
fi
install -m 0755 "${CALICO_TMP}/calicoctl-linux-${ARCH}" /usr/local/bin/calicoctl

if [[ "${INSTALL_ARGOCD}" == "true" ]]; then
  echo "[6/6] Installing Argo CD (${ARGOCD_VER}) and argocd CLI (Management Cluster Mode)..."
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

  ARGO_BASE="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VER}"
  curl -fsSL "${ARGO_BASE}/argocd-linux-${ARCH}" -o "${CALICO_TMP}/argocd-linux-${ARCH}"
  if curl -fsSL "${ARGO_BASE}/cli_checksums.txt" -o "${CALICO_TMP}/cli_checksums.txt" 2>/dev/null; then
    (cd "${CALICO_TMP}" && grep "argocd-linux-${ARCH}\$" cli_checksums.txt | sha256sum -c -)
  fi
  install -m 0755 "${CALICO_TMP}/argocd-linux-${ARCH}" /usr/local/bin/argocd
  argocd version --client
else
  echo "[6/6] Skipping Argo CD on Layer 3 Application Cluster (managed from Layer 2)."
fi

kubectl get nodes -o wide
calicoctl version
echo "Join commands saved in /root/k8s-join-commands.sh (mode 0600)."
echo "Kubernetes Control Plane installation complete."
