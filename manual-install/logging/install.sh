#!/usr/bin/env bash
# ==============================================================================
# Grafana Loki 3.3.2 + logcli + Promtail 3.3.2 Installer (Ubuntu 24.04 LTS)
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
LOKI_VER="${LOKI_VER:-3.3.2}"
LOKI_SERVER_IP="${LOKI_SERVER_IP:-127.0.0.1}"

echo "[1/4] Installing dependencies and creating loki user..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl

groupadd --system loki 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g loki loki 2>/dev/null || true
mkdir -p /etc/loki /var/lib/loki/chunks /var/lib/loki/rules

echo "[2/4] Downloading Loki, logcli, and Promtail (${LOKI_VER})..."
curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/loki-linux-${ARCH}.zip" -o /tmp/loki.zip
unzip -o /tmp/loki.zip -d /tmp
mv "/tmp/loki-linux-${ARCH}" /usr/local/bin/loki

curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/logcli-linux-${ARCH}.zip" -o /tmp/logcli.zip
unzip -o /tmp/logcli.zip -d /tmp
mv "/tmp/logcli-linux-${ARCH}" /usr/local/bin/logcli

curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/promtail-linux-${ARCH}.zip" -o /tmp/promtail.zip
unzip -o /tmp/promtail.zip -d /tmp
mv "/tmp/promtail-linux-${ARCH}" /usr/local/bin/promtail

chmod 0755 /usr/local/bin/loki /usr/local/bin/logcli /usr/local/bin/promtail
chown -R loki:loki /etc/loki /var/lib/loki /usr/local/bin/loki

echo "[3/4] Configuring and starting Loki service..."
cat >/etc/loki/loki-config.yml <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 168h
  allow_structured_metadata: true
EOF

cat >/etc/systemd/system/loki.service <<'EOF'
[Unit]
Description=Grafana Loki Log Aggregation Server
Wants=network-online.target
After=network-online.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

ufw allow 3100/tcp comment 'Loki HTTP API'
systemctl daemon-reload
systemctl enable --now loki

echo "[4/4] Configuring and starting Promtail service..."
mkdir -p /etc/promtail /var/lib/promtail
cat >/etc/promtail/promtail-config.yml <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://${LOKI_SERVER_IP}:3100/loki/api/v1/push

scrape_configs:
  - job_name: system-logs
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          host: $(hostname -s)
          __path__: /var/log/*.log
  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          host: $(hostname -s)
          __path__: /var/log/syslog
EOF

cat >/etc/systemd/system/promtail.service <<'EOF'
[Unit]
Description=Promtail Log Shipping Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now promtail
sleep 3
curl -fsS http://127.0.0.1:3100/ready && echo
logcli --version
echo "Loki, logcli, and Promtail installation complete."

