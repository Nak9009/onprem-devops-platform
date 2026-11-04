# Sonatype Nexus Server Manual Installation & CLI Guide (`nexus`)

- **Target Host:** `devops-nexus` (`192.168.252.12`) or `prod-nexus-01` (`10.20.10.12`)
- **Version:** Sonatype Nexus Repository Manager OSS `3.75.1-01` + OpenJDK 17
- **Automated Script:** [`manual-install/nexus/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/nexus/install.sh)

---

## 1. Install OpenJDK 17 & Extract Nexus (`3.75.1-01`)

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jre-headless curl jq

sudo groupadd --system nexus || true
sudo useradd --system --home-dir /var/lib/nexus --create-home --shell /bin/bash -g nexus nexus || true
sudo mkdir -p /opt/nexus /var/lib/nexus

NEXUS_VER="3.75.1-01"
curl -fsSL "https://download.sonatype.com/nexus/3/nexus-${NEXUS_VER}-unix.tar.gz" -o /tmp/nexus.tar.gz
sudo tar -xzf /tmp/nexus.tar.gz -C /opt/nexus --strip-components=1
sudo mv /opt/nexus/sonatype-work /var/lib/nexus/ || true
sudo chown -R nexus:nexus /opt/nexus /var/lib/nexus
```

---

## 2. Configure JVM Options (`/opt/nexus/bin/nexus.vmoptions`) & Properties

```bash
# Use 1200m for local Multipass or 4096m for production
JVM_HEAP="1200m"

sudo tee /opt/nexus/bin/nexus.vmoptions >/dev/null <<EOF
-Xms${JVM_HEAP}
-Xmx${JVM_HEAP}
-XX:MaxDirectMemorySize=${JVM_HEAP}
-XX:+UnlockDiagnosticVMOptions
-XX:+LogVMOutput
-XX:LogFile=/var/lib/nexus/nexus3/log/jvm.log
-XX:-OmitStackTraceInFastThrow
-Djava.net.preferIPv4Stack=true
-Dkaraf.home=.
-Dkaraf.base=.
-Dkaraf.etc=etc/karaf
-Djava.util.logging.config.file=etc/karaf/java.util.logging.properties
-Dkaraf.data=/var/lib/nexus/nexus3
-Dkaraf.log=/var/lib/nexus/nexus3/log
-Djava.io.tmpdir=/var/lib/nexus/nexus3/tmp
EOF

sudo tee /opt/nexus/bin/nexus.rc >/dev/null <<'EOF'
run_as_user="nexus"
EOF

sudo mkdir -p /var/lib/nexus/nexus3/etc
sudo tee /var/lib/nexus/nexus3/etc/nexus.properties >/dev/null <<'EOF'
application-port=8081
application-host=0.0.0.0
nexus.scripts.allowCreation=true
nexus.onboarding.enabled=false
EOF
sudo chown -R nexus:nexus /opt/nexus /var/lib/nexus
```

---

## 3. Configure Systemd Service & UFW Ports

```bash
sudo tee /etc/systemd/system/nexus.service >/dev/null <<'EOF'
[Unit]
Description=Sonatype Nexus Repository Manager 3
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
LimitNOFILE=65536
User=nexus
Group=nexus
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
Restart=on-abort
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 8081/tcp comment 'Nexus Web UI and REST API'
sudo ufw allow 5000/tcp comment 'Nexus Docker Hosted Registry'
sudo ufw allow 5001/tcp comment 'Nexus Docker Proxy Registry'

sudo systemctl daemon-reload
sudo systemctl enable --now nexus
```

---

## 4. Nexus Service & REST API CLI Reference

### 4.1 Nexus Binary CLI (`/opt/nexus/bin/nexus`)
```bash
# Check service status, start, stop, or run in foreground
sudo -u nexus /opt/nexus/bin/nexus status
sudo systemctl status nexus

# Retrieve initial generated admin password (first boot only)
sudo cat /var/lib/nexus/nexus3/admin.password && echo
```

### 4.2 Nexus REST API CLI (`curl` + `jq`)
```bash
export NEXUS_URL="http://127.0.0.1:8081"
export NEXUS_USER="admin"
export NEXUS_PASS="<ADMIN_PASSWORD>"

# 1. Verify Nexus system health (read-only & write status)
curl -fsS "${NEXUS_URL}/service/rest/v1/status"
curl -fsS "${NEXUS_URL}/service/rest/v1/status/writable"

# 2. List all configured repositories via CLI
curl -fsS -u "${NEXUS_USER}:${NEXUS_PASS}" "${NEXUS_URL}/service/rest/v1/repositories" \
  | jq -r '.[] | "\(.name)\t\(.format)\t\(.type)\t\(.url)"'

# 3. Create a Docker Hosted repository on port 5000 via REST API CLI
curl -fsS -u "${NEXUS_USER}:${NEXUS_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "${NEXUS_URL}/service/rest/v1/repositories/docker/hosted" \
  -d '{
    "name": "docker-hosted",
    "online": true,
    "storage": {
      "blobStoreName": "default",
      "strictContentTypeValidation": true,
      "writePolicy": "ALLOW"
    },
    "docker": {
      "v1Enabled": false,
      "forceBasicAuth": true,
      "httpPort": 5000
    }
  }'

# 4. List uploaded components/images in docker-hosted repository
curl -fsS -u "${NEXUS_USER}:${NEXUS_PASS}" \
  "${NEXUS_URL}/service/rest/v1/components?repository=docker-hosted" \
  | jq -r '.items[] | "\(.name):\(.version)"'
```

