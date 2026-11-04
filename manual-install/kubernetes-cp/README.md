# Kubernetes Control Plane, Calico & Argo CD Manual Installation & CLI Guide (`kubernetes-cp`)

- **Target Host(s):**
  - **Local:** `k8s-cp01` (`192.168.252.21` / `192.168.252.24`)
  - **Production HA:** `prod-k8s-cp01` (`10.20.20.21`), `prod-k8s-cp02` (`10.20.20.22`), `prod-k8s-cp03` (`10.20.20.23`) fronting VIP `10.20.20.20:8443`
- **Versions:** Kubernetes `1.31.4-1.1`, Calico `v3.29.1`, Argo CD `v2.13.2`
- **Installed CLIs:** `kubeadm`, `kubectl`, `crictl`, `calicoctl`, `argocd`
- **Automated Script:** [`manual-install/kubernetes-cp/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-cp/install.sh)

---

## 1. (Production HA Only) Configure Keepalived + HAProxy on `prod-k8s-cp01..03`

Skip to **Section 2** for a single-node local control plane.

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy keepalived

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

# Set STATE="MASTER" PRIORITY="101" on cp01; BACKUP/100 on cp02; BACKUP/99 on cp03
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

---

## 2. Install `containerd`, `kubeadm`, `kubelet`, `kubectl` (`1.31.4-1.1`)

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

# Configure crictl to use containerd socket
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock \
                   --set image-endpoint=unix:///run/containerd/containerd.sock
```

---

## 3. Open Firewall Ports & Initialize Kubernetes Cluster

```bash
sudo ufw allow 6443/tcp comment 'Kubernetes API Server'
sudo ufw allow 2379:2380/tcp comment 'etcd Server Client API'
sudo ufw allow 10250/tcp comment 'Kubelet API'
sudo ufw allow 10257/tcp comment 'kube-controller-manager'
sudo ufw allow 10259/tcp comment 'kube-scheduler'
sudo ufw allow 179/tcp comment 'Calico BGP'
sudo ufw allow 4789/udp comment 'Calico VXLAN'
sudo ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'

NODE_IP=$(hostname -I | awk '{print $1}')
CONTROL_PLANE_ENDPOINT="${NODE_IP}:6443"   # Or 10.20.20.20:8443 for Prod HA

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

sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

---

## 4. Install Calico CNI (`v3.29.1`) & `calicoctl` CLI

```bash
ARCH=$(dpkg --print-architecture) # amd64 or arm64
CALICO_VER="v3.29.1"

sudo mkdir -p /etc/kubernetes/addons/calico
sudo curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
  -o /etc/kubernetes/addons/calico/calico.yaml
kubectl apply -f /etc/kubernetes/addons/calico/calico.yaml

# Install calicoctl CLI binary
sudo curl -fsSL "https://github.com/projectcalico/calico/releases/download/${CALICO_VER}/calicoctl-linux-${ARCH}" \
  -o /usr/local/bin/calicoctl
sudo chmod 0755 /usr/local/bin/calicoctl
```

---

## 5. Install Argo CD (`v2.13.2`) & `argocd` CLI

```bash
ARCH=$(dpkg --print-architecture) # amd64 or arm64
ARGOCD_VER="v2.13.2"

sudo mkdir -p /etc/kubernetes/addons/argocd
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
sudo curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VER}/manifests/install.yaml" \
  -o /etc/kubernetes/addons/argocd/install.yaml
kubectl apply -n argocd -f /etc/kubernetes/addons/argocd/install.yaml

# Expose Argo CD Server via NodePort (30080 HTTP / 30443 HTTPS)
kubectl patch svc argocd-server -n argocd --type merge -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      {"name": "http", "port": 80, "targetPort": 8080, "nodePort": 30080, "protocol": "TCP"},
      {"name": "https", "port": 443, "targetPort": 8080, "nodePort": 30443, "protocol": "TCP"}
    ]
  }
}'

# Install argocd CLI binary
sudo curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VER}/argocd-linux-${ARCH}" \
  -o /usr/local/bin/argocd
sudo chmod 0755 /usr/local/bin/argocd
```

---

## 6. Kubernetes, Calico & Argo CD CLI Reference

### 6.1 `kubectl`, `kubeadm`, & `crictl` CLI
```bash
# Cluster nodes, pods, and system component status
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl top nodes

# Check kubeadm control-plane TLS certificate expiration dates
sudo kubeadm certs check-expiration

# Renew all control-plane TLS certificates via CLI
sudo kubeadm certs renew all

# Generate a new join command for worker nodes or HA control plane nodes
sudo kubeadm token create --print-join-command

# Inspect containerd pods and images directly on the node with crictl
sudo crictl ps
sudo crictl images
sudo crictl pods
```

### 6.2 `calicoctl` CLI (CNI & Network Policy Diagnostics)
```bash
# View Calico IP pools and utilization
DATASTORE_TYPE=kubernetes KUBECONFIG=~/.kube/config calicoctl get ippool -o wide

# Check BGP peer status and node networking health
sudo calicoctl node status

# List all Calico NetworkPolicies and WorkloadEndpoints across namespaces
DATASTORE_TYPE=kubernetes KUBECONFIG=~/.kube/config calicoctl get networkpolicy -A
DATASTORE_TYPE=kubernetes KUBECONFIG=~/.kube/config calicoctl get workloadendpoint -A
```

### 6.3 `argocd` CLI (GitOps Application Management)
```bash
# Retrieve initial Argo CD admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Authenticate argocd CLI against the local NodePort HTTPS endpoint
argocd login 127.0.0.1:30443 --username admin --password "${ARGOCD_PASS}" --insecure

# Change the admin password via CLI
argocd account update-password --current-password "${ARGOCD_PASS}" --new-password "<NEW_STRONG_PASSWORD>"

# Register internal GitLab GitOps repository
argocd repo add http://gitlab.internal.example.com/devops/gitops.git \
  --username root --password "<GITLAB_TOKEN>"

# List, inspect, sync, and rollback GitOps applications via CLI
argocd app list
argocd app get sample-api-dev
argocd app sync sample-api-dev
argocd app history sample-api-dev
argocd app rollback sample-api-dev <HISTORY_ID>
```

