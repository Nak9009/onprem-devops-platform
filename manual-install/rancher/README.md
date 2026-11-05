# Rancher Server Manual Installation & CLI Guide (`rancher`)

- **Target Host:** `devops-rancher` (`192.168.252.13`) or `prod-rancher-01` (`10.20.10.13`)
- **Versions:** Docker CE `27.4.1`, Rancher Server `v2.10.1`, Rancher CLI `v2.15.3`
- **Automated Script:** [`manual-install/rancher/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/rancher/install.sh)

---

## 1. Install Docker CE (`27.4.1`) via Official DEB822 Repository

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

---

## 2. Deploy Rancher Server (`v2.10.1`) via Systemd Service

```bash
export RANCHER_VER="v2.10.1"
export RANCHER_BOOTSTRAP_PASS="ChangeMe_RancherBootstrap_2026!"

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
```

---

## 3. Install Rancher CLI (`rancher`)

```bash
ARCH=$(dpkg --print-architecture) # amd64 or arm64
RANCHER_CLI_VER="v2.9.0"

curl -fsSL "https://github.com/rancher/cli/releases/download/${RANCHER_CLI_VER}/rancher-linux-${ARCH}-${RANCHER_CLI_VER}.tar.gz" \
  -o /tmp/rancher-cli.tar.gz
tar -xzf /tmp/rancher-cli.tar.gz -C /tmp
sudo mv "/tmp/rancher-${RANCHER_CLI_VER}/rancher" /usr/local/bin/rancher
sudo chmod 0755 /usr/local/bin/rancher
rancher --version
```

---

## 4. Docker & `rancher` CLI Reference

```bash
# 1. Inspect Rancher container status and logs via Docker CLI
sudo docker ps --filter name=rancher-server
sudo docker logs --tail 50 -f rancher-server

# 2. Verify Rancher HTTPS readiness
curl -sk https://127.0.0.1/ping

# 3. Authenticate Rancher CLI using a Bearer Token (from Rancher UI -> Account & API Keys)
rancher login https://rancher.internal.example.com --token <BEARER_TOKEN> --skip-verify

# 4. List managed Kubernetes clusters, nodes, and projects via Rancher CLI
rancher clusters ls
rancher nodes ls
rancher projects ls

# 5. Run kubectl commands through Rancher CLI proxy
rancher kubectl get nodes -o wide
rancher kubectl get pods -A
```

