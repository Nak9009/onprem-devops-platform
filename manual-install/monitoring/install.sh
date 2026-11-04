#!/usr/bin/env bash
# ==============================================================================
# Prometheus 2.53.3 + promtool + Grafana 11.4.0 + grafana-cli Installer
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
PROM_VER="${PROM_VER:-2.53.3}"
GRAFANA_VER="${GRAFANA_VER:-11.4.0}"
GRAFANA_PASS="${GRAFANA_PASS:-ChangeMe_GrafanaAdmin_2026!}"

echo "[1/3] Installing Prometheus ${PROM_VER} and promtool CLI..."
groupadd --system prometheus 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g prometheus prometheus 2>/dev/null || true
mkdir -p /etc/prometheus/rules /var/lib/prometheus

curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH}.tar.gz" \
  -o /tmp/prometheus.tar.gz
tar -xzf /tmp/prometheus.tar.gz -C /tmp
cp "/tmp/prometheus-${PROM_VER}.linux-${ARCH}/prometheus" /usr/local/bin/
cp "/tmp/prometheus-${PROM_VER}.linux-${ARCH}/promtool" /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
chmod 0755 /usr/local/bin/prometheus /usr/local/bin/promtool

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

cat >/etc/prometheus/prometheus.yml <<'EOF'
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
      - targets: ['127.0.0.1:9100']
EOF

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
  --web.enable-lifecycle \
  --web.enable-admin-api
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

ufw allow 9090/tcp comment 'Prometheus Web UI'
systemctl daemon-reload
systemctl enable --now prometheus

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

ufw allow 3000/tcp comment 'Grafana Web UI'
systemctl daemon-reload
systemctl enable --now grafana-server

echo "[3/3] Verifying Prometheus and Grafana..."
sleep 3
curl -fsS http://127.0.0.1:9090/-/healthy && echo
curl -fsS http://127.0.0.1:3000/api/health && echo
echo "Prometheus and Grafana installation complete."

