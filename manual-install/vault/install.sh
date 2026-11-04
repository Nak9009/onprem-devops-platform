#!/usr/bin/env bash
# ==============================================================================
# HashiCorp Vault 1.18.3 Server + vault CLI Installer (Ubuntu 24.04 LTS)
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
VAULT_VER="${VAULT_VER:-1.18.3}"

echo "[1/3] Installing dependencies and creating vault user..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl

groupadd --system vault 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g vault vault 2>/dev/null || true
mkdir -p /etc/vault.d /var/lib/vault/data

echo "[2/3] Downloading Vault ${VAULT_VER} binary..."
curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_${ARCH}.zip" \
  -o /tmp/vault.zip
unzip -o /tmp/vault.zip -d /usr/local/bin
chmod 0755 /usr/local/bin/vault
chown -R vault:vault /etc/vault.d /var/lib/vault

echo "[3/3] Configuring /etc/vault.d/vault.hcl and starting vault.service..."
cat >/etc/vault.d/vault.hcl <<'EOF'
ui = true
disable_mlock = true

storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8200"
EOF
chmod 0640 /etc/vault.d/vault.hcl
chown vault:vault /etc/vault.d/vault.hcl

cat >/etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=HashiCorp Vault Secret Management Server
Wants=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

ufw allow 8200/tcp comment 'HashiCorp Vault API/UI'
systemctl daemon-reload
systemctl enable --now vault

vault --version
echo "HashiCorp Vault installation complete. Run 'VAULT_ADDR=http://127.0.0.1:8200 vault status' to verify."

