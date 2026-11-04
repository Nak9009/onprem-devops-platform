#!/usr/bin/env bash
# ==============================================================================
# Sonatype Nexus 3.75.1-01 Manual Installer (Ubuntu 24.04 LTS)
# Usage: sudo JVM_HEAP="1200m" ./install.sh
# ==============================================================================
set -euo pipefail

NEXUS_VER="${NEXUS_VER:-3.75.1-01}"
JVM_HEAP="${JVM_HEAP:-1200m}"

echo "[1/4] Installing OpenJDK 17 and creating nexus user..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jre-headless curl jq

groupadd --system nexus 2>/dev/null || true
useradd --system --home-dir /var/lib/nexus --create-home --shell /bin/bash -g nexus nexus 2>/dev/null || true
mkdir -p /opt/nexus /var/lib/nexus

echo "[2/4] Downloading and extracting Nexus ${NEXUS_VER}..."
curl -fsSL "https://download.sonatype.com/nexus/3/nexus-${NEXUS_VER}-unix.tar.gz" -o /tmp/nexus.tar.gz
tar -xzf /tmp/nexus.tar.gz -C /opt/nexus --strip-components=1
mv /opt/nexus/sonatype-work /var/lib/nexus/ 2>/dev/null || true

echo "[3/4] Writing nexus.vmoptions and nexus.properties..."
cat >/opt/nexus/bin/nexus.vmoptions <<EOF
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

echo 'run_as_user="nexus"' >/opt/nexus/bin/nexus.rc
mkdir -p /var/lib/nexus/nexus3/etc
cat >/var/lib/nexus/nexus3/etc/nexus.properties <<'EOF'
application-port=8081
application-host=0.0.0.0
nexus.scripts.allowCreation=true
nexus.onboarding.enabled=false
EOF
chown -R nexus:nexus /opt/nexus /var/lib/nexus

echo "[4/4] Creating systemd unit and opening UFW ports..."
cat >/etc/systemd/system/nexus.service <<'EOF'
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

ufw allow 8081/tcp comment 'Nexus Web UI and REST API'
ufw allow 5000/tcp comment 'Nexus Docker Hosted Registry'
ufw allow 5001/tcp comment 'Nexus Docker Proxy Registry'

systemctl daemon-reload
systemctl enable --now nexus
echo "Nexus installation complete. Check status with: systemctl status nexus"

