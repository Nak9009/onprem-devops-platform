#!/usr/bin/env bash
# ==============================================================================
# Prometheus 2.53.3 + promtool + Grafana 11.4.0 + grafana-cli Installer
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

ARCH="$(dpkg --print-architecture)"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
CLIENT_CIDR="${CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"
PROM_VER="${PROM_VER:-2.53.3}"
GRAFANA_VER="${GRAFANA_VER:-11.4.0}"
GRAFANA_PASS="${GRAFANA_PASS:-ChangeMe_GrafanaAdmin_2026!}"

if [[ "${PLATFORM_ENV:-}" == "production" && "${GRAFANA_PASS}" == ChangeMe_* ]]; then
  echo "ERROR: set a real GRAFANA_PASS before a production install" >&2
  exit 1
fi

echo "[1/3] Installing Prometheus ${PROM_VER} and promtool CLI..."
groupadd --system prometheus 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g prometheus prometheus 2>/dev/null || true
mkdir -p /etc/prometheus/rules /var/lib/prometheus

PROM_TMP="$(mktemp -d)"
trap 'rm -rf "${PROM_TMP}"' EXIT
PROM_BASE="https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}"
PROM_TAR="prometheus-${PROM_VER}.linux-${ARCH}.tar.gz"
curl -fsSL "${PROM_BASE}/${PROM_TAR}" -o "${PROM_TMP}/${PROM_TAR}"
if curl -fsSL "${PROM_BASE}/sha256sums.txt" -o "${PROM_TMP}/sha256sums.txt" 2>/dev/null; then
  (cd "${PROM_TMP}" && grep " ${PROM_TAR}\$" sha256sums.txt | sha256sum -c -)
fi
tar -xzf "${PROM_TMP}/${PROM_TAR}" -C "${PROM_TMP}"
install -m 0755 -o prometheus -g prometheus "${PROM_TMP}/prometheus-${PROM_VER}.linux-${ARCH}/prometheus" /usr/local/bin/prometheus
install -m 0755 -o prometheus -g prometheus "${PROM_TMP}/prometheus-${PROM_VER}.linux-${ARCH}/promtool" /usr/local/bin/promtool

cat >/etc/prometheus/rules/alert.rules.yml <<'EOF'
groups:
  - name: node_and_platform_alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node or target {{ $labels.instance }} is down"
EOF

# Build node_exporter target list from platform.env IPs (deduplicated)
declare -A SEEN_IPS=()
NODE_TARGETS=("'127.0.0.1:9100'")
SEEN_IPS["127.0.0.1"]=1
SEEN_IPS["${NODE_IP}"]=1
for ip_var in GITLAB_IP JENKINS_IP JENKINS_AGENT01_IP JENKINS_AGENT02_IP NEXUS_IP \
              PG_LB1_IP PG_LB2_IP PG_DB1_IP PG_DB2_IP PG_DB3_IP REDIS_IP REDIS02_IP REDIS03_IP \
              MINIO01_IP MINIO02_IP MINIO03_IP MINIO04_IP VAULT_IP \
              K8S_MGMT_CP01_IP K8S_MGMT_CP02_IP K8S_MGMT_CP03_IP \
              K8S_APP_CP01_IP K8S_APP_CP02_IP K8S_APP_CP03_IP \
              K8S_APP_WORKER01_IP K8S_APP_WORKER02_IP K8S_APP_WORKER03_IP; do
  ip="${!ip_var:-}"
  if [[ -n "${ip}" && -z "${SEEN_IPS[${ip}]:-}" ]]; then
    SEEN_IPS["${ip}"]=1
    NODE_TARGETS+=("'${ip}:9100'")
  fi
done
TARGETS_CSV="$(IFS=,; echo "${NODE_TARGETS[*]}")"

PG_TARGETS=""
for ip in "${PG_DB1_IP:-}" "${PG_DB2_IP:-}" "${PG_DB3_IP:-}"; do
  [[ -n "${ip}" ]] && PG_TARGETS+="${PG_TARGETS:+,}'${ip}:9187'"
done

REDIS_TARGETS=""
for ip in "${REDIS_IP:-}" "${REDIS02_IP:-}" "${REDIS03_IP:-}"; do
  [[ -n "${ip}" ]] && REDIS_TARGETS+="${REDIS_TARGETS:+,}'${ip}:9121'"
done

cat >/etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/alert.rules.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:9090']
  - job_name: 'node_exporter'
    static_configs:
      - targets: [${TARGETS_CSV}]
EOF

if [[ -n "${PG_TARGETS}" ]]; then
  cat >>/etc/prometheus/prometheus.yml <<EOF
  - job_name: 'postgres_exporter'
    static_configs:
      - targets: [${PG_TARGETS}]
EOF
fi
if [[ -n "${REDIS_TARGETS}" ]]; then
  cat >>/etc/prometheus/prometheus.yml <<EOF
  - job_name: 'redis_exporter'
    static_configs:
      - targets: [${REDIS_TARGETS}]
EOF
fi

chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
promtool check config /etc/prometheus/prometheus.yml

cat >/etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus Time-Series Monitoring Server
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

ufw allow from "${CLIENT_CIDR}" to any port 9090 proto tcp comment 'Prometheus Web UI'
systemctl daemon-reload
systemctl enable prometheus
systemctl restart prometheus

echo "[2/3] Installing Grafana ${GRAFANA_VER} and grafana-cli..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | tee /etc/apt/keyrings/grafana.asc >/dev/null
chmod 0644 /etc/apt/keyrings/grafana.asc

cat >/etc/apt/sources.list.d/grafana.sources <<'EOF'
Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/grafana.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "grafana=${GRAFANA_VER}"
apt-mark hold grafana

cat >/etc/grafana/grafana.ini <<EOF
[server]
protocol = http
http_addr = 0.0.0.0
http_port = 3000

[security]
admin_user = admin
admin_password = ${GRAFANA_PASS}
cookie_secure = false

[users]
allow_sign_up = false
EOF
chown root:grafana /etc/grafana/grafana.ini
chmod 0640 /etc/grafana/grafana.ini

cat >/etc/grafana/provisioning/datasources/datasources.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://127.0.0.1:3100
    isDefault: false
    editable: false
EOF

ufw allow from "${CLIENT_CIDR}" to any port 3000 proto tcp comment 'Grafana Web UI'
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server

echo "[3/3] Verifying Prometheus and Grafana..."
for url in "http://127.0.0.1:9090/-/healthy" "http://127.0.0.1:3000/api/health"; do
  ok=0
  for _ in $(seq 1 20); do
    if curl -fsS "${url}" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
  done
  [[ ${ok} -eq 1 ]] || { echo "ERROR: ${url} did not become healthy" >&2; exit 1; }
done
echo "Prometheus and Grafana installation complete."
