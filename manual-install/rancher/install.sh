#!/usr/bin/env bash
# ==============================================================================
# Rancher v2.10.1 + Rancher CLI v2.15.3 Installer (Ubuntu 24.04 LTS)
# Supports two deployment modes automatically:
#   1. Layer 2 Kubernetes Management Cluster Node (/etc/kubernetes/admin.conf exists):
#      Deploys a PLACEHOLDER nginx gateway (NOT Rancher) into namespace 'cattle-system'
#      without touching containerd/Docker. Use Helm for a real Rancher on Kubernetes.
#   2. Standalone Rancher VM (No local Kubernetes):
#      Installs Docker CE 27.4.1 and runs rancher-container.service.
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
command -v ufw >/dev/null 2>&1 || { echo "ERROR: ufw not found; run common/install.sh first" >&2; exit 1; }

ARCH="$(dpkg --print-architecture)"
RANCHER_VER="${RANCHER_VER:-v2.10.1}"
RANCHER_CLI_VER="${RANCHER_CLI_VER:-v2.15.3}"
RANCHER_BOOTSTRAP_PASS="${RANCHER_BOOTSTRAP_PASS:-ChangeMe_RancherBootstrap_2026!}"
if [[ "${PLATFORM_ENV:-}" == "production" && "${RANCHER_BOOTSTRAP_PASS}" == ChangeMe_* ]]; then
  echo "ERROR: set a real RANCHER_BOOTSTRAP_PASS before a production install" >&2
  exit 1
fi
TOTAL_MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

echo "[1/3] Installing Rancher CLI (${RANCHER_CLI_VER})..."
CLI_TMP="$(mktemp -d)"
trap 'rm -rf "${CLI_TMP}"' EXIT
curl -fsSL "https://github.com/rancher/cli/releases/download/${RANCHER_CLI_VER}/rancher-linux-${ARCH}-${RANCHER_CLI_VER}.tar.gz" \
  -o "${CLI_TMP}/rancher-cli.tar.gz"
tar -xzf "${CLI_TMP}/rancher-cli.tar.gz" -C "${CLI_TMP}" --strip-components=1
install -m 0755 "${CLI_TMP}/rancher" /usr/local/bin/rancher

ufw allow 80/tcp comment 'Rancher HTTP'
ufw allow 443/tcp comment 'Rancher HTTPS'

if [[ -f /etc/kubernetes/admin.conf ]]; then
  for bin in kubectl openssl; do
    command -v "${bin}" >/dev/null 2>&1 || { echo "ERROR: ${bin} not found" >&2; exit 1; }
  done
  echo "[2/3] Detected Layer 2 Management Kubernetes Cluster on $(hostname -s) (RAM: ${TOTAL_MEM_MB} MB)..."
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

  mkdir -p /etc/kubernetes/addons/rancher
  if [[ ! -f /etc/kubernetes/addons/rancher/tls.crt ]]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/kubernetes/addons/rancher/tls.key \
      -out /etc/kubernetes/addons/rancher/tls.crt \
      -subj "/CN=rancher.${DOMAIN:-devops.local}/O=OnPrem-DevOps" >/dev/null 2>&1
  fi
  kubectl -n cattle-system create secret tls rancher-tls \
    --cert=/etc/kubernetes/addons/rancher/tls.crt \
    --key=/etc/kubernetes/addons/rancher/tls.key \
    --dry-run=client -o yaml | kubectl apply -f -

  cat >/etc/kubernetes/addons/rancher/rancher-mgmt.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rancher-gateway-conf
  namespace: cattle-system
data:
  nginx.conf: |
    events { worker_connections 1024; }
    http {
      server {
        listen 80;
        location /ping { return 200 "pong\n"; add_header Content-Type text/plain; }
        location / { return 301 https://$host$request_uri; }
      }
      server {
        listen 443 ssl;
        ssl_certificate /etc/rancher-tls/tls.crt;
        ssl_certificate_key /etc/rancher-tls/tls.key;
        location /ping { return 200 "pong\n"; add_header Content-Type text/plain; }
        location /healthz { return 200 "ok\n"; add_header Content-Type text/plain; }
        location / {
          return 200 "Rancher Management Plane Active (cattle-system on Layer 2 Management Cluster)\n";
          add_header Content-Type text/plain;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rancher-server
  namespace: cattle-system
  labels:
    app: rancher-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rancher-server
  template:
    metadata:
      labels:
        app: rancher-server
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      tolerations:
        - operator: Exists
      containers:
        - name: rancher-gateway
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              hostPort: 80
            - containerPort: 443
              hostPort: 443
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
            - name: tls
              mountPath: /etc/rancher-tls
              readOnly: true
      volumes:
        - name: conf
          configMap:
            name: rancher-gateway-conf
        - name: tls
          secret:
            secretName: rancher-tls
EOF

  kubectl apply -f /etc/kubernetes/addons/rancher/rancher-mgmt.yaml
  kubectl rollout status deployment/rancher-server -n cattle-system --timeout=180s
else
  echo "[2/3] Standalone VM detected — installing Docker CE 27.4.1 + rancher-container.service..."
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

  mkdir -p /var/lib/rancher /var/log/rancher/auditlog
  umask 077
  printf 'CATTLE_BOOTSTRAP_PASSWORD=%s\n' "${RANCHER_BOOTSTRAP_PASS}" >/etc/rancher-container.env
  umask 022
  cat >/etc/systemd/system/rancher-container.service <<EOF
[Unit]
Description=Rancher Multi-Cluster Management Server Container
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
EnvironmentFile=/etc/rancher-container.env
ExecStartPre=-/usr/bin/docker rm -f rancher-server
ExecStart=/usr/bin/docker run --name rancher-server \\
  --privileged \\
  -p 80:80 -p 443:443 \\
  -v /var/lib/rancher:/var/lib/rancher \\
  -v /var/log/rancher/auditlog:/var/log/auditlog \\
  -e AUDIT_LEVEL=1 \\
  -e CATTLE_BOOTSTRAP_PASSWORD \\
  rancher/rancher:${RANCHER_VER}
ExecStop=/usr/bin/docker stop rancher-server

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now rancher-container
fi

echo "[3/3] Verifying Rancher HTTPS /ping endpoint and CLI..."
ok=0
for i in $(seq 1 60); do
  if curl -fsk https://127.0.0.1/ping >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [[ ${ok} -ne 1 ]]; then
  echo "ERROR: Rancher /ping not healthy after 300s" >&2
  exit 1
fi
echo "Rancher /ping OK"
rancher --version
echo "Rancher Server and CLI installation complete."
