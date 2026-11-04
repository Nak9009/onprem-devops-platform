# Logging Server (Grafana Loki, `logcli` & Promtail) Manual Installation & CLI Guide (`logging`)

- **Target Host:**
  - **Loki Server + `logcli`:** `devops-monitor` (`192.168.252.14` / `192.168.252.25`) or `prod-monitor-01` (`10.20.10.14`)
  - **Promtail Agent:** All Servers
- **Version:** `3.3.2`
- **Installed CLIs:** `loki`, `logcli`, `promtail`
- **Automated Script:** [`manual-install/logging/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/logging/install.sh)

---

## 1. Install Loki Server (`3.3.2`) & `logcli` CLI

```bash
LOKI_VER="3.3.2"
ARCH=$(dpkg --print-architecture) # amd64 or arm64

sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl

sudo groupadd --system loki || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g loki loki || true
sudo mkdir -p /etc/loki /var/lib/loki/chunks /var/lib/loki/rules

# Download Loki Server binary
curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/loki-linux-${ARCH}.zip" \
  -o /tmp/loki.zip
sudo unzip -o /tmp/loki.zip -d /tmp
sudo mv "/tmp/loki-linux-${ARCH}" /usr/local/bin/loki

# Download LogCLI (Loki Command-Line Query Tool)
curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/logcli-linux-${ARCH}.zip" \
  -o /tmp/logcli.zip
sudo unzip -o /tmp/logcli.zip -d /tmp
sudo mv "/tmp/logcli-linux-${ARCH}" /usr/local/bin/logcli

sudo chmod 0755 /usr/local/bin/loki /usr/local/bin/logcli
sudo chown -R loki:loki /etc/loki /var/lib/loki /usr/local/bin/loki
```

---

## 2. Configure `/etc/loki/loki-config.yml` & Systemd Service

```bash
sudo tee /etc/loki/loki-config.yml >/dev/null <<'EOF'
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

sudo tee /etc/systemd/system/loki.service >/dev/null <<'EOF'
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

sudo ufw allow 3100/tcp comment 'Loki HTTP API'
sudo systemctl daemon-reload
sudo systemctl enable --now loki
```

---

## 3. Install Promtail Log Shipper (`3.3.2`)

```bash
LOKI_VER="3.3.2"
ARCH=$(dpkg --print-architecture) # amd64 or arm64
LOKI_SERVER_IP="127.0.0.1"        # Set to Monitoring/Logging server IP on remote nodes

sudo mkdir -p /etc/promtail /var/lib/promtail
curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/promtail-linux-${ARCH}.zip" \
  -o /tmp/promtail.zip
sudo unzip -o /tmp/promtail.zip -d /tmp
sudo mv "/tmp/promtail-linux-${ARCH}" /usr/local/bin/promtail
sudo chmod 0755 /usr/local/bin/promtail

sudo tee /etc/promtail/promtail-config.yml >/dev/null <<EOF
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

sudo tee /etc/systemd/system/promtail.service >/dev/null <<'EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable --now promtail
```

---

## 4. `logcli` & `promtail` CLI Reference

```bash
export LOKI_ADDR="http://127.0.0.1:3100"

# 1. List all available log label names and values in Loki
logcli labels
logcli labels host
logcli labels job

# 2. Query logs using LogQL from the terminal
logcli query '{job="syslog"}' --limit=50
logcli query '{host="devops-monitor"} |= "error"' --since=1h

# 3. Live-tail logs in real time via logcli
logcli query '{job="varlogs"}' --tail

# 4. Validate and dry-run Promtail configuration from the CLI
promtail -config.file=/etc/promtail/promtail-config.yml -check-syntax
promtail -config.file=/etc/promtail/promtail-config.yml -dry-run
```

