# Kubernetes Worker Node Manual Installation & CLI Guide (`kubernetes-worker`)

- **Target Host(s):** `k8s-worker01..02` (`192.168.252.31..32`) or `prod-k8s-worker01..03` (`10.20.20.31..33`)
- **Versions:** `containerd` `1.7.x`, `kubelet` & `kubeadm` `1.31.4-1.1`
- **Installed CLIs:** `kubeadm`, `crictl`, `ctr`
- **Automated Script:** [`manual-install/kubernetes-worker/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-worker/install.sh)

---

## 1. Install `containerd` (`SystemdCgroup = true`)

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

---

## 2. Install `kubeadm` & `kubelet` (`1.31.4-1.1`) and Open UFW Ports

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
  kubelet=1.31.4-1.1 kubeadm=1.31.4-1.1
sudo apt-mark hold kubelet kubeadm
sudo systemctl enable kubelet

# Configure crictl CLI to use containerd runtime socket
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock \
                   --set image-endpoint=unix:///run/containerd/containerd.sock

# Open Worker Node firewall ports
sudo ufw allow 10250/tcp comment 'Kubelet API'
sudo ufw allow 179/tcp comment 'Calico BGP'
sudo ufw allow 4789/udp comment 'Calico VXLAN'
sudo ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'
```

---

## 3. Join Worker Node to the Cluster

1. On `k8s-cp01` (or `prod-k8s-cp01`), generate a join token:
   ```bash
   sudo kubeadm token create --print-join-command
   ```
2. On the worker node, run the printed `kubeadm join` command:
   ```bash
   sudo kubeadm join <CP_ENDPOINT>:6443 --token <TOKEN> \
     --discovery-token-ca-cert-hash sha256:<HASH>
   ```
3. On `k8s-cp01`, label the worker node:
   ```bash
   kubectl label node <worker-hostname> node-role.kubernetes.io/worker=worker --overwrite
   ```

---

## 4. Worker Node CLI Reference (`crictl`, `ctr`, `journalctl`)

```bash
# List running containers and pods on this worker node via crictl
sudo crictl ps
sudo crictl pods

# View container logs or inspect a container directly on the node
sudo crictl logs <CONTAINER_ID>
sudo crictl inspect <CONTAINER_ID>

# List cached images and prune unused container images
sudo crictl images
sudo crictl rmi --prune

# Query containerd namespaces and tasks directly with ctr CLI
sudo ctr -n k8s.io containers ls
sudo ctr -n k8s.io images ls

# Inspect kubelet service status and real-time logs
sudo systemctl status kubelet
sudo journalctl -u kubelet -f
```

