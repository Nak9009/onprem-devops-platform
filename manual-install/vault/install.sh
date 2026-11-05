#!/usr/bin/env bash
# ==============================================================================
# HashiCorp Vault Server + vault CLI Installer (Ubuntu 24.04 LTS)
#
# Production-oriented defaults:
#   - TLS on the API and cluster listeners (own CA generated, or bring your own)
#   - Integrated Raft storage (single node, or a 3+ node cluster via VAULT_PEERS)
#   - Optional auto-unseal through a Transit seal on another Vault
#   - Firewall limited to client CIDR (8200) and peers (8201)
#   - Release zip verified against HashiCorp's SHA256SUMS
#
# Environment (all optional unless noted):
#   VAULT_PEERS="10.20.10.17,10.20.10.18"   other Raft nodes (retry_join), enables clustering
#   VAULT_CLIENT_CIDR=...                    networks allowed to reach :8200 (default: node /16)
#   VAULT_TLS_CERT / VAULT_TLS_KEY / VAULT_TLS_CA   bring your own certificate files
#   VAULT_TRANSIT_ADDR / VAULT_TRANSIT_TOKEN [VAULT_TRANSIT_KEY=autounseal]  auto-unseal
#
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

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
VAULT_VER="${VAULT_VER:-1.18.3}"
NODE_NAME="$(hostname -s)"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
VAULT_PEERS="${VAULT_PEERS:-}"
VAULT_CLIENT_CIDR="${VAULT_CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"
VAULT_TRANSIT_KEY="${VAULT_TRANSIT_KEY:-autounseal}"
TLS_DIR=/etc/vault.d/tls

if [[ -n "${VAULT_TRANSIT_ADDR:-}" && -z "${VAULT_TRANSIT_TOKEN:-}" ]]; then
  echo "ERROR: VAULT_TRANSIT_ADDR set without VAULT_TRANSIT_TOKEN" >&2
  exit 1
fi
if [[ "${PLATFORM_ENV:-}" == "production" && -z "${VAULT_TRANSIT_ADDR:-}" ]]; then
  echo "WARN: production without auto-unseal: Vault must be unsealed by hand after every restart." >&2
fi
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  echo "WARN: swap is enabled; Vault keeps secrets in memory. Run common/install.sh first (disables swap)." >&2
fi

echo "[1/5] Installing dependencies and creating the vault user..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl openssl jq
groupadd --system vault 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g vault vault 2>/dev/null || true
mkdir -p /etc/vault.d "${TLS_DIR}" /var/lib/vault/raft /var/log/vault
chown -R vault:vault /var/lib/vault /var/log/vault
chmod 0700 /var/lib/vault/raft

echo "[2/5] Downloading Vault ${VAULT_VER} and verifying its checksum..."
V_TMP="$(mktemp -d)"
trap 'rm -rf "${V_TMP}"' EXIT
V_ZIP="vault_${VAULT_VER}_linux_${ARCH}.zip"
V_BASE="https://releases.hashicorp.com/vault/${VAULT_VER}"
curl -fsSL "${V_BASE}/${V_ZIP}" -o "${V_TMP}/${V_ZIP}"
curl -fsSL "${V_BASE}/vault_${VAULT_VER}_SHA256SUMS" -o "${V_TMP}/SHA256SUMS"
(cd "${V_TMP}" && grep " ${V_ZIP}\$" SHA256SUMS | sha256sum -c -)
unzip -o "${V_TMP}/${V_ZIP}" vault -d /usr/local/bin
chmod 0755 /usr/local/bin/vault
chown root:root /usr/local/bin/vault
# Let the binary lock memory without running as root
setcap cap_ipc_lock=+ep /usr/local/bin/vault 2>/dev/null || true

echo "[3/5] Preparing TLS material in ${TLS_DIR}..."
if [[ -n "${VAULT_TLS_CERT:-}" && -n "${VAULT_TLS_KEY:-}" ]]; then
  install -m 0644 "${VAULT_TLS_CERT}" "${TLS_DIR}/vault.crt"
  install -m 0600 "${VAULT_TLS_KEY}" "${TLS_DIR}/vault.key"
  if [[ -n "${VAULT_TLS_CA:-}" ]]; then install -m 0644 "${VAULT_TLS_CA}" "${TLS_DIR}/ca.crt"; else cp "${TLS_DIR}/vault.crt" "${TLS_DIR}/ca.crt"; fi
elif [[ ! -f "${TLS_DIR}/vault.crt" ]]; then
  echo "No certificate supplied: generating a private CA and server certificate (valid 2 years)."
  openssl genrsa -out "${TLS_DIR}/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "${TLS_DIR}/ca.key" -sha256 -days 1825 \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -subj "/CN=Vault Internal CA/O=OnPrem-DevOps" -out "${TLS_DIR}/ca.crt"
  openssl genrsa -out "${TLS_DIR}/vault.key" 2048 2>/dev/null
  cat >"${V_TMP}/san.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = ${NODE_NAME}
[ext]
subjectAltName = DNS:${NODE_NAME},DNS:vault.${DOMAIN:-internal.example.com},DNS:localhost,IP:127.0.0.1,IP:${NODE_IP}${VAULT_IP:+,IP:${VAULT_IP}}
extendedKeyUsage = serverAuth,clientAuth
EOF
  openssl req -new -key "${TLS_DIR}/vault.key" -config "${V_TMP}/san.cnf" -out "${V_TMP}/vault.csr"
  openssl x509 -req -in "${V_TMP}/vault.csr" -CA "${TLS_DIR}/ca.crt" -CAkey "${TLS_DIR}/ca.key" \
    -CAcreateserial -out "${TLS_DIR}/vault.crt" -days 730 -sha256 \
    -extfile "${V_TMP}/san.cnf" -extensions ext 2>/dev/null
  chmod 0600 "${TLS_DIR}/ca.key"
fi
chown root:vault "${TLS_DIR}" "${TLS_DIR}"/vault.crt "${TLS_DIR}"/vault.key "${TLS_DIR}"/ca.crt
chmod 0750 "${TLS_DIR}"
chmod 0640 "${TLS_DIR}/vault.key"
chmod 0644 "${TLS_DIR}/vault.crt" "${TLS_DIR}/ca.crt"

echo "[4/5] Writing /etc/vault.d/vault.hcl and vault.service..."
RETRY_JOIN=""
if [[ -n "${VAULT_PEERS}" ]]; then
  IFS=',' read -ra PEER_ARR <<<"${VAULT_PEERS}"
  for peer in "${PEER_ARR[@]}"; do
    RETRY_JOIN+="
  retry_join {
    leader_api_addr         = \"https://${peer}:8200\"
    leader_ca_cert_file     = \"${TLS_DIR}/ca.crt\"
  }"
  done
fi

SEAL_BLOCK=""
if [[ -n "${VAULT_TRANSIT_ADDR:-}" ]]; then
  SEAL_BLOCK="
seal \"transit\" {
  address         = \"${VAULT_TRANSIT_ADDR}\"
  key_name        = \"${VAULT_TRANSIT_KEY}\"
  mount_path      = \"transit/\"
  disable_renewal = \"false\"
}"
fi

cat >/etc/vault.d/vault.hcl <<EOF
ui            = true
# Integrated storage (Raft) uses mmap; HashiCorp recommends disabling mlock here and disabling swap instead
disable_mlock = true
log_level     = "info"

storage "raft" {
  path    = "/var/lib/vault/raft"
  node_id = "${NODE_NAME}"
${RETRY_JOIN}
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file = "${TLS_DIR}/vault.crt"
  tls_key_file  = "${TLS_DIR}/vault.key"
  tls_min_version = "tls12"
}

api_addr     = "https://${NODE_IP}:8200"
cluster_addr = "https://${NODE_IP}:8201"
${SEAL_BLOCK}
EOF
# Transit token lives only in this file (readable by root and vault)
chown root:vault /etc/vault.d/vault.hcl
chmod 0640 /etc/vault.d/vault.hcl
if [[ -n "${VAULT_TRANSIT_TOKEN:-}" ]]; then
  echo "VAULT_TOKEN=${VAULT_TRANSIT_TOKEN}" >/etc/vault.d/vault.env
else
  : >/etc/vault.d/vault.env
fi
chown root:vault /etc/vault.d/vault.env
chmod 0640 /etc/vault.d/vault.env

cat >/etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=HashiCorp Vault Secret Management Server
Wants=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
EnvironmentFile=/etc/vault.d/vault.env
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
NoNewPrivileges=yes
ReadWritePaths=/var/lib/vault /var/log/vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/profile.d/vault.sh <<EOF
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${TLS_DIR}/ca.crt"
EOF

ufw allow from "${VAULT_CLIENT_CIDR}" to any port 8200 proto tcp comment 'Vault API/UI'
if [[ -n "${VAULT_PEERS}" ]]; then
  for peer in "${PEER_ARR[@]}"; do
    ufw allow from "${peer}" to any port 8200 proto tcp comment 'Vault peer API'
    ufw allow from "${peer}" to any port 8201 proto tcp comment 'Vault cluster port'
  done
fi

systemctl daemon-reload
systemctl enable vault
systemctl restart vault

echo "[5/5] Waiting for the Vault API..."
export VAULT_ADDR="https://127.0.0.1:8200" VAULT_CACERT="${TLS_DIR}/ca.crt"
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s --cacert "${TLS_DIR}/ca.crt" -o /dev/null -w '%{http_code}' "${VAULT_ADDR}/v1/sys/health" || true)"
  # 200 active, 429 standby, 472/473 DR/perf standby, 501 uninitialized, 503 sealed: all mean "Vault is up"
  if [[ "${code}" =~ ^(200|429|472|473|501|503)$ ]]; then ok=1; break; fi
  sleep 2
done
if [[ ${ok} -ne 1 ]]; then
  echo "ERROR: Vault API did not answer over TLS; check 'journalctl -u vault'" >&2
  exit 1
fi
vault --version
vault status || true

cat <<EOF

Vault ${VAULT_VER} is running (HTTP ${code}). Next steps (done by hand, once):
  1. export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=${TLS_DIR}/ca.crt
  2. vault operator init -key-shares=5 -key-threshold=3    # store each key with a DIFFERENT custodian
  3. vault operator unseal   (x3, skip if auto-unseal is configured)
  4. vault login <root token>; then enable auditing BEFORE storing secrets:
       vault audit enable file file_path=/var/log/vault/audit.log
  5. Create admin/AppRole policies, then revoke the root token.
  6. Schedule: vault operator raft snapshot save /backup/vault-\$(date +%F).snap
Distribute ${TLS_DIR}/ca.crt to every client that talks to Vault.
EOF
