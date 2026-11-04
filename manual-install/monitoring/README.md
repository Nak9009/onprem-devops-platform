# Monitoring Server (Prometheus & Grafana) Manual Installation & CLI Guide (`monitoring`)

- **Target Host:** `devops-monitor` (`192.168.252.14` / `192.168.252.25`) or `prod-monitor-01` (`10.20.10.14`)
- **Versions:** Prometheus `2.53.3`, Grafana `11.4.0`
- **Installed CLIs:** `promtool`, `grafana-cli`
- **Automated Script:** [`manual-install/monitoring/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/monitoring/install.sh)

---

## 1. Install Prometheus Server (`2.53.3`) & `promtool` CLI

```bash
PROM_VER="2.53.3"
ARCH=$(dpkg --print-architecture) # amd64 or arm64

sudo groupadd --system prometheus || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g prometheus prometheus || true
sudo mkdir -p /etc/prometheus/rules /var/lib/prometheus

curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH}.tar.gz" \
  -o /tmp/prometheus.tar.gz
tar -xzf /tmp/prometheus.tar.gz -C /tmp
sudo cp "/tmp/prometheus-${PROM_VER}.linux-${ARCH}/prometheus" /usr/local/bin/
sudo cp "/tmp/prometheus-${PROM_VER}.linux-${ARCH}/promtool" /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
sudo chmod 0755 /usr/local/bin/prometheus /usr/local/bin/promtool
```

---

## 2. Configure Prometheus Rules, Scrape Targets & Systemd Unit

```bash
sudo tee /etc/prometheus/rules/alert.rules.yml >/dev/null <<'EOF'
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
      - alert: HighNodeMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage (>85%) on {{ $labels.instance }}"
EOF

sudo tee /etc/prometheus/prometheus.yml >/dev/null <<'EOF'
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
      - targets:
          - '127.0.0.1:9100'
EOF

sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# Validate configuration and alert rules via promtool CLI before starting
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/alert.rules.yml

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
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

sudo ufw allow 9090/tcp comment 'Prometheus Web UI'
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
```

---

## 3. Install Grafana (`11.4.0`) & Provision Datasources

```bash
export GRAFANA_PASS="ChangeMe_GrafanaAdmin_2026!"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | sudo tee /etc/apt/keyrings/grafana.asc >/dev/null
sudo chmod 0644 /etc/apt/keyrings/grafana.asc

sudo tee /etc/apt/sources.list.d/grafana.sources >/dev/null <<'EOF'
Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/grafana.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y grafana=11.4.0
sudo apt-mark hold grafana

sudo tee /etc/grafana/grafana.ini >/dev/null <<EOF
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

sudo tee /etc/grafana/provisioning/datasources/datasources.yml >/dev/null <<'EOF'
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

sudo ufw allow 3000/tcp comment 'Grafana Web UI'
sudo systemctl daemon-reload
sudo systemctl enable --now grafana-server
```

---

## 4. `promtool` & `grafana-cli` Reference

### 4.1 `promtool` CLI (Validation, Queries & TSDB Diagnostics)
```bash
# Validate Prometheus main configuration and alerting rules
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/alert.rules.yml

# Execute an instant PromQL query from the command line
promtool query instant http://127.0.0.1:9090 'up'
promtool query instant http://127.0.0.1:9090 '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'

# Inspect active label values or series via CLI
promtool query labels http://127.0.0.1:9090 instance

# Trigger a hot configuration reload or TSDB snapshot via HTTP API
curl -X POST http://127.0.0.1:9090/-/reload
curl -X POST http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot
```

### 4.2 `grafana-cli` (Grafana Administration & Plugin CLI)
```bash
# Reset the Grafana 'admin' password via CLI
sudo grafana-cli admin reset-admin-password "<NEW_STRONG_PASSWORD>"

# List installed plugins, search remote plugins, or install a plugin
sudo grafana-cli plugins ls
sudo grafana-cli plugins list-remote | grep piechart
sudo grafana-cli plugins install grafana-piechart-panel
sudo systemctl restart grafana-server
```

