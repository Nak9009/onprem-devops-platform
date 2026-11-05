#!/usr/bin/env bash
# ==============================================================================
# Grafana Loki 3.3.2 + logcli + Promtail 3.3.2 Installer (Ubuntu 24.04 LTS)
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
LOKI_VER="${LOKI_VER:-3.3.2}"
LOKI_SERVER_IP="${LOKI_SERVER_IP:-127.0.0.1}"

echo "[1/4] Installing dependencies and creating loki & promtail users..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl

groupadd --system loki 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g loki loki 2>/dev/null || true
mkdir -p /etc/loki /var/lib/loki/chunks /var/lib/loki/rules

groupadd --system promtail 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g promtail promtail 2>/dev/null || true
for grp in adm systemd-journal; do
  getent group "${grp}" >/dev/null 2>&1 && usermod -a -G "${grp}" promtail
done

echo "[2/4] Downloading Loki, logcli, and Promtail (${LOKI_VER})..."
LOKI_TMP="$(mktemp -d)"
trap 'rm -rf "${LOKI_TMP}"' EXIT
LOKI_BASE="https://github.com/grafana/loki/releases/download/v${LOKI_VER}"
HAS_SUMS=0
if curl -fsSL "${LOKI_BASE}/SHA256SUMS" -o "${LOKI_TMP}/SHA256SUMS" 2>/dev/null; then
  HAS_SUMS=1
fi

for bin in loki logcli promtail; do
  zip_name="${bin}-linux-${ARCH}.zip"
  curl -fsSL "${LOKI_BASE}/${zip_name}" -o "${LOKI_TMP}/${zip_name}"
  if [[ ${HAS_SUMS} -eq 1 ]]; then
    (cd "${LOKI_TMP}" && grep " ${zip_name}\$" SHA256SUMS | sha256sum -c -)
  fi
  unzip -o "${LOKI_TMP}/${zip_name}" -d "${LOKI_TMP}"
  install -m 0755 "${LOKI_TMP}/${bin}-linux-${ARCH}" "/usr/local/bin/${bin}"
done
chown -R loki:loki /etc/loki /var/lib/loki

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
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=/var/lib/loki

[Install]
WantedBy=multi-user.target
EOF

ufw allow from "${CLIENT_CIDR}" to any port 3100 proto tcp comment 'Loki HTTP API'
systemctl daemon-reload
systemctl enable loki
systemctl restart loki

echo "[4/4] Configuring and starting Promtail service..."
mkdir -p /etc/promtail /var/lib/promtail
chown -R promtail:promtail /etc/promtail /var/lib/promtail
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
User=promtail
Group=promtail
SupplementaryGroups=adm systemd-journal
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yml
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=/var/lib/promtail

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable promtail
systemctl restart promtail

ok=0
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:3100/ready >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[[ ${ok} -eq 1 ]] || { echo "ERROR: Loki did not become ready on :3100" >&2; exit 1; }
logcli --version
echo "Loki, logcli, and Promtail installation complete."
