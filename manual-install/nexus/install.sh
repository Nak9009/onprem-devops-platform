#!/usr/bin/env bash
# ==============================================================================
# Sonatype Nexus 3.75.1-01 Manual Installer (Ubuntu 24.04 LTS)
# Usage: sudo JVM_HEAP="1200m" ./install.sh
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

NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
CLIENT_CIDR="${CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"
NEXUS_VER="${NEXUS_VER:-3.75.1-01}"
JVM_HEAP="${JVM_HEAP:-1200m}"
NEXUS_ALLOW_GROOVY="${NEXUS_ALLOW_GROOVY:-$([[ "${PLATFORM_ENV:-}" == "production" ]] && echo false || echo true)}"

echo "[1/4] Installing OpenJDK 17 and creating nexus user..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jre-headless curl jq

groupadd --system nexus 2>/dev/null || true
useradd --system --home-dir /var/lib/nexus --create-home --shell /bin/bash -g nexus nexus 2>/dev/null || true
mkdir -p /opt/nexus /var/lib/nexus

echo "[2/4] Downloading and extracting Nexus ${NEXUS_VER}..."
NX_TMP="$(mktemp -d)"
trap 'rm -rf "${NX_TMP}"' EXIT
curl -fsSL "https://download.sonatype.com/nexus/3/nexus-${NEXUS_VER}-unix.tar.gz" -o "${NX_TMP}/nexus.tar.gz"
if [[ -n "${NEXUS_SHA256:-}" ]]; then
  echo "${NEXUS_SHA256}  ${NX_TMP}/nexus.tar.gz" | sha256sum -c -
fi
tar -xzf "${NX_TMP}/nexus.tar.gz" -C /opt/nexus --strip-components=1
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
cat >/var/lib/nexus/nexus3/etc/nexus.properties <<EOF
application-port=8081
application-host=0.0.0.0
nexus.scripts.allowCreation=${NEXUS_ALLOW_GROOVY}
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

ufw allow from "${CLIENT_CIDR}" to any port 8081 proto tcp comment 'Nexus Web UI and REST API'
ufw allow from "${CLIENT_CIDR}" to any port 5000 proto tcp comment 'Nexus Docker Hosted Registry'
ufw allow from "${CLIENT_CIDR}" to any port 5001 proto tcp comment 'Nexus Docker Proxy Registry'

systemctl daemon-reload
systemctl enable nexus
systemctl restart nexus

echo "Waiting for Nexus REST API on :8081 (up to 180s)..."
ok=0
for _ in $(seq 1 36); do
  if curl -fsS http://127.0.0.1:8081/service/rest/v1/status >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
[[ ${ok} -eq 1 ]] || echo "WARN: Nexus still initializing in background; check 'systemctl status nexus'" >&2
echo "Nexus installation complete."
