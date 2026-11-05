#!/usr/bin/env bash
# ==============================================================================
# Garage S3 object storage installer (Ubuntu 24.04 LTS)
# Replaces the MinIO installer: MinIO Community stopped publishing binaries
# (dl.min.io now returns HTTP 410).  https://garagehq.deuxfleurs.fr
#
# Topology (the legacy MINIO*_IP variable names in platform.env are kept):
#   * Distributed (production): this host's IP is MINIO01_IP..MINIO04_IP.
#     replication_factor = 3, one Garage zone per node, TLS front (nginx :9443)
#     on every node and a Keepalived VIP (MINIO_VIP) shared by the four nodes.
#   * Single node (lab): MINIO01..04_IP not set -> replication_factor = 1.
#
# Install flow for the distributed cluster:
#   1. Create ONE shared secret and ONE TLS pair, copy them to every node:
#        export GARAGE_RPC_SECRET="$(openssl rand -hex 32)"
#        mkdir -p /etc/garage/tls   # put server.crt + server.key from node 1 on all nodes (optional,
#                                   # otherwise node 1 generates them; copy before running the others)
#   2. Run this script on all four nodes. Each prints and stores its node id in /etc/garage/node-id.txt.
#   3. On node 1 run it again to form the cluster, assign the layout and create buckets/keys:
#        GARAGE_BOOTSTRAP=true GARAGE_PEERS="<id2@ip2:3901>,<id3@ip3:3901>,<id4@ip4:3901>" ./install.sh
#
# Environment:
#   GARAGE_VER (v2.5.0)        GARAGE_SHA256  checksum of the binary (REQUIRED in production)
#   GARAGE_RPC_SECRET          64 hex chars, same on every node (required when distributed)
#   GARAGE_DATA_DIR            data path (default /var/lib/garage/data; mount a big disk here)
#   GARAGE_META_DIR            metadata path (default /var/lib/garage/meta; SSD recommended)
#   GARAGE_CAPACITY            per-node capacity for the layout, e.g. 800G (default: 90% of data FS)
#   GARAGE_BUCKETS             space-separated bucket list
#   GARAGE_TLS_PORT (9443)     GARAGE_CLIENT_CIDR   networks allowed to reach the TLS port
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
case "${ARCH}" in
  amd64) G_TRIPLE="x86_64-unknown-linux-musl" ;;
  arm64) G_TRIPLE="aarch64-unknown-linux-musl" ;;
  *) echo "ERROR: unsupported architecture ${ARCH}" >&2; exit 1 ;;
esac

GARAGE_VER="${GARAGE_VER:-v2.5.0}"
GARAGE_DATA_DIR="${GARAGE_DATA_DIR:-/var/lib/garage/data}"
GARAGE_META_DIR="${GARAGE_META_DIR:-/var/lib/garage/meta}"
GARAGE_TLS_PORT="${GARAGE_TLS_PORT:-9443}"
GARAGE_BUCKETS="${GARAGE_BUCKETS:-gitlab-backups loki-chunks terraform-state artifacts pgbackrest}"
GARAGE_VRRP_PASS="${GARAGE_VRRP_PASS:-ChangeMe_Vrrp26}"
GARAGE_BOOTSTRAP="${GARAGE_BOOTSTRAP:-false}"
GARAGE_PEERS="${GARAGE_PEERS:-}"
NODE_NAME="$(hostname -s)"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
GARAGE_CLIENT_CIDR="${GARAGE_CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"
TLS_DIR=/etc/garage/tls
export GARAGE_CONFIG_FILE=/etc/garage.toml

# ---- Mode / node detection ----------------------------------------------------
MODE=single; NODE_INDEX=1; PEER_IPS=()
if [[ -n "${MINIO01_IP:-}" && -n "${MINIO02_IP:-}" && -n "${MINIO03_IP:-}" && -n "${MINIO04_IP:-}" ]]; then
  ALL_IPS=("${MINIO01_IP}" "${MINIO02_IP}" "${MINIO03_IP}" "${MINIO04_IP}")
  for i in 0 1 2 3; do
    if [[ "${ALL_IPS[$i]}" == "${NODE_IP}" ]]; then MODE=distributed; NODE_INDEX=$((i + 1)); fi
  done
  if [[ "${MODE}" == "distributed" ]]; then
    for ip in "${ALL_IPS[@]}"; do [[ "${ip}" != "${NODE_IP}" ]] && PEER_IPS+=("${ip}"); done
  fi
fi
REPL_FACTOR=1; [[ "${MODE}" == "distributed" ]] && REPL_FACTOR=3
echo "Garage ${GARAGE_VER}: mode=${MODE} node=${NODE_NAME} index=${NODE_INDEX} ip=${NODE_IP}"

# ---- Production safety guards -------------------------------------------------
if [[ "${PLATFORM_ENV:-}" == "production" ]]; then
  if [[ -z "${GARAGE_SHA256:-}" ]]; then
    echo "ERROR: production requires GARAGE_SHA256 (checksum of the garage binary, computed on a trusted machine)" >&2
    exit 1
  fi
  if [[ "${MODE}" != "distributed" ]]; then
    echo "WARN: production Garage running single node (replication_factor=1, no redundancy)." >&2
  fi
  if [[ "${GARAGE_VRRP_PASS}" == ChangeMe_* && "${MODE}" == "distributed" ]]; then
    echo "ERROR: set a real GARAGE_VRRP_PASS" >&2; exit 1
  fi
fi
if [[ "${MODE}" == "distributed" ]]; then
  [[ "${GARAGE_RPC_SECRET:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: distributed mode needs GARAGE_RPC_SECRET (64 hex chars, same on all nodes): openssl rand -hex 32" >&2; exit 1; }
fi

echo "[1/6] Installing packages (nginx TLS front, keepalived)..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl nginx
[[ "${MODE}" == "distributed" ]] && DEBIAN_FRONTEND=noninteractive apt-get install -y keepalived

echo "[2/6] Downloading Garage ${GARAGE_VER}..."
G_TMP="$(mktemp -d)"
trap 'rm -rf "${G_TMP}"' EXIT
curl -fsSL "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VER}/${G_TRIPLE}/garage" -o "${G_TMP}/garage"
if [[ -n "${GARAGE_SHA256:-}" ]]; then
  echo "${GARAGE_SHA256}  ${G_TMP}/garage" | sha256sum -c -
else
  echo "WARN: GARAGE_SHA256 not set; binary integrity NOT verified (sha256: $(sha256sum "${G_TMP}/garage" | awk '{print $1}'))" >&2
fi
install -m 0755 "${G_TMP}/garage" /usr/local/bin/garage

groupadd --system garage 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g garage garage 2>/dev/null || true
mkdir -p /etc/garage "${GARAGE_DATA_DIR}" "${GARAGE_META_DIR}" "${TLS_DIR}"
chown -R garage:garage "${GARAGE_DATA_DIR}" "${GARAGE_META_DIR}"
chmod 0700 "${GARAGE_DATA_DIR}" "${GARAGE_META_DIR}"

if [[ "${PLATFORM_ENV:-}" == "production" ]]; then
  root_src="$(findmnt -n -o SOURCE --target / || true)"
  data_src="$(findmnt -n -o SOURCE --target "${GARAGE_DATA_DIR}" || true)"
  if [[ -n "${root_src}" && "${root_src}" == "${data_src}" ]]; then
    echo "WARN: ${GARAGE_DATA_DIR} is on the root filesystem; mount a dedicated data disk there first." >&2
  fi
fi

echo "[3/6] Writing /etc/garage.toml, secrets and the systemd unit..."
if [[ "${MODE}" == "distributed" ]]; then
  RPC_SECRET="${GARAGE_RPC_SECRET}"
elif [[ -f /etc/garage/rpc_secret ]]; then
  RPC_SECRET="$(cat /etc/garage/rpc_secret)"
else
  RPC_SECRET="${GARAGE_RPC_SECRET:-$(openssl rand -hex 32)}"
fi
umask 077
printf '%s' "${RPC_SECRET}" >/etc/garage/rpc_secret
[[ -f /etc/garage/admin_token ]] || openssl rand -hex 24 | tr -d '\n' >/etc/garage/admin_token
umask 022
chown root:garage /etc/garage/rpc_secret /etc/garage/admin_token
chmod 0640 /etc/garage/rpc_secret /etc/garage/admin_token

cat >/etc/garage.toml <<EOF
metadata_dir = "${GARAGE_META_DIR}"
data_dir = "${GARAGE_DATA_DIR}"
db_engine = "lmdb"
metadata_auto_snapshot_interval = "6h"

replication_factor = ${REPL_FACTOR}
consistency_mode = "consistent"
compression_level = 2

rpc_bind_addr = "${NODE_IP}:3901"
rpc_public_addr = "${NODE_IP}:3901"
rpc_secret_file = "/etc/garage/rpc_secret"

# S3 API is plain HTTP on loopback only; nginx terminates TLS in front of it
[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3900"

[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token_file = "/etc/garage/admin_token"
EOF
chown root:garage /etc/garage.toml
chmod 0640 /etc/garage.toml

cat >/etc/systemd/system/garage.service <<'EOF'
[Unit]
Description=Garage S3 Object Storage
Documentation=https://garagehq.deuxfleurs.fr
After=network-online.target
Wants=network-online.target

[Service]
User=garage
Group=garage
Environment=RUST_LOG=garage=info
ExecStart=/usr/local/bin/garage server
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/garage

[Install]
WantedBy=multi-user.target
EOF

echo "[4/6] TLS front (nginx :${GARAGE_TLS_PORT}) and firewall..."
if [[ ! -f "${TLS_DIR}/server.crt" ]]; then
  SAN="DNS:${NODE_NAME},DNS:localhost,IP:127.0.0.1,IP:${NODE_IP}"
  [[ -n "${MINIO_VIP:-}" ]] && SAN+=",IP:${MINIO_VIP}"
  if [[ "${MODE}" == "distributed" ]]; then for ip in "${PEER_IPS[@]}"; do SAN+=",IP:${ip}"; done; fi
  echo "No certificate in ${TLS_DIR}: generating a self-signed one (valid 2 years). In a cluster, copy it to the other nodes BEFORE they run this script."
  openssl req -x509 -newkey rsa:2048 -nodes -days 730 -subj "/CN=garage-s3/O=OnPrem-DevOps" \
    -addext "subjectAltName=${SAN}" -keyout "${TLS_DIR}/server.key" -out "${TLS_DIR}/server.crt" 2>/dev/null
fi
chown -R root:root "${TLS_DIR}"
chmod 0600 "${TLS_DIR}/server.key"
chmod 0644 "${TLS_DIR}/server.crt"

rm -f /etc/nginx/sites-enabled/default
cat >/etc/nginx/conf.d/garage-s3.conf <<EOF
server {
    listen ${GARAGE_TLS_PORT} ssl;
    server_name _;
    ssl_certificate     ${TLS_DIR}/server.crt;
    ssl_certificate_key ${TLS_DIR}/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;

    location = /health {
        proxy_pass http://127.0.0.1:3903/health;
    }

    location / {
        proxy_pass http://127.0.0.1:3900;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_http_version 1.1;
        proxy_connect_timeout 5s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
nginx -t

ufw allow from "${GARAGE_CLIENT_CIDR}" to any port "${GARAGE_TLS_PORT}" proto tcp comment 'Garage S3 (TLS)'
if [[ "${MODE}" == "distributed" ]]; then
  for ip in "${PEER_IPS[@]}"; do
    ufw allow from "${ip}" to any port 3901 proto tcp comment 'Garage RPC peer'
    ufw allow from "${ip}" to any port "${GARAGE_TLS_PORT}" proto tcp comment 'Garage S3 peer'
  done
fi

systemctl daemon-reload
systemctl enable garage nginx
systemctl restart garage
systemctl restart nginx

echo "[5/6] Waiting for Garage and recording the node id..."
ok=0
for _ in $(seq 1 30); do
  if garage status >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[[ ${ok} -eq 1 ]] || { echo "ERROR: garage did not start; check 'journalctl -u garage'" >&2; exit 1; }
NODE_ID_FULL="$(garage node id 2>/dev/null | grep -oE '[0-9a-f]{64}@[^ ]+' | head -1 || true)"
if [[ -n "${NODE_ID_FULL}" ]]; then
  echo "${NODE_ID_FULL}" >/etc/garage/node-id.txt
  echo "Node id (give this to node 1): ${NODE_ID_FULL}"
fi

# ---- Cluster formation (single node: automatic; distributed: only when asked) --
if [[ "${MODE}" == "single" ]]; then
  GARAGE_BOOTSTRAP=true
fi

if [[ "${MODE}" == "distributed" ]]; then
  # Keepalived VIP shared by the four nodes (any node can serve S3)
  if [[ -n "${MINIO_VIP:-}" ]]; then
    IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    PEER_LINES=""; for ip in "${PEER_IPS[@]}"; do PEER_LINES+="        ${ip}"$'\n'; done
    PRIO=$((160 - NODE_INDEX * 10)); STATE=BACKUP; [[ "${NODE_INDEX}" == "1" ]] && STATE=MASTER
    cat >/etc/keepalived/keepalived.conf <<EOF
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_garage {
    script "/usr/bin/systemctl is-active --quiet garage nginx"
    interval 3
    fall 2
    rise 2
}

vrrp_instance GARAGE_VIP {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id 61
    priority ${PRIO}
    advert_int 1
    unicast_src_ip ${NODE_IP}
    unicast_peer {
${PEER_LINES}    }
    authentication {
        auth_type PASS
        auth_pass ${GARAGE_VRRP_PASS:0:8}
    }
    virtual_ipaddress {
        ${MINIO_VIP}/${GARAGE_VIP_PREFIX:-24} dev ${IFACE}
    }
    track_script {
        chk_garage
    }
}
EOF
    chmod 0600 /etc/keepalived/keepalived.conf
    for ip in "${PEER_IPS[@]}"; do
      if ! grep -q "garage-vrrp-${ip}" /etc/ufw/before.rules; then
        sed -i "0,/^# End required lines/s//# End required lines\n# garage-vrrp-${ip}\n-A ufw-before-input -p 112 -s ${ip} -j ACCEPT/" /etc/ufw/before.rules
      fi
    done
    ufw reload
    systemctl enable keepalived
    systemctl restart keepalived
  fi
fi

echo "[6/6] Cluster layout, buckets and access keys..."
if [[ "${MODE}" == "distributed" && "${GARAGE_BOOTSTRAP}" != "true" ]]; then
  cat <<EOF

Node ${NODE_NAME} is installed. Run this script on the other nodes, collect their ids
(/etc/garage/node-id.txt), then on ${MINIO01_IP} run:
  GARAGE_BOOTSTRAP=true GARAGE_PEERS="<id2@ip2:3901>,<id3@ip3:3901>,<id4@ip4:3901>" ./install.sh
EOF
  exit 0
fi

if [[ "${MODE}" == "distributed" ]]; then
  [[ "${NODE_INDEX}" == "1" ]] || { echo "ERROR: bootstrap must run on node 1 (${MINIO01_IP})" >&2; exit 1; }
  IFS=',' read -ra PEER_ARR <<<"${GARAGE_PEERS}"
  for peer in "${PEER_ARR[@]}"; do
    [[ -n "${peer}" ]] && garage node connect "${peer}"
  done
fi

EXPECTED_NODES=1; [[ "${MODE}" == "distributed" ]] && EXPECTED_NODES=4
node_rows() { garage status 2>/dev/null | awk '$1 ~ /^[0-9a-f]{16}$/ {print $1" "$2}'; }
ok=0
for _ in $(seq 1 30); do
  if [[ "$(node_rows | wc -l)" -ge ${EXPECTED_NODES} ]]; then ok=1; break; fi
  sleep 2
done
[[ ${ok} -eq 1 ]] || { echo "ERROR: expected ${EXPECTED_NODES} nodes in 'garage status', saw $(node_rows | wc -l)" >&2; exit 1; }

# Per-node capacity: GARAGE_CAPACITY, or 90% of the data filesystem
if [[ -z "${GARAGE_CAPACITY:-}" ]]; then
  size_g="$(df -BG --output=size "${GARAGE_DATA_DIR}" | tail -1 | tr -dc '0-9')"
  GARAGE_CAPACITY="$(( size_g * 9 / 10 ))G"
fi
echo "Per-node capacity for the layout: ${GARAGE_CAPACITY}"

CUR_VER="$(garage layout show 2>/dev/null | awk '/Current cluster layout version:/ {print $NF}')"
if [[ "${CUR_VER:-0}" -ge 1 ]]; then
  echo "Layout already applied (version ${CUR_VER}); leaving it unchanged."
else
  # One zone per node (zone name = hostname) so replicas land on distinct machines
  while read -r nid host; do
    garage layout assign "${nid}" -z "${host}" -c "${GARAGE_CAPACITY}"
  done < <(node_rows)
  garage layout show
  garage layout apply --version 1
  sleep 3
fi

CREDS=/root/garage-s3-credentials.env
touch "${CREDS}"; chmod 0600 "${CREDS}"
for b in ${GARAGE_BUCKETS}; do
  garage bucket info "${b}" >/dev/null 2>&1 || garage bucket create "${b}"
  key="svc-${b}"
  if ! garage key info "${key}" >/dev/null 2>&1; then
    out="$(garage key create "${key}")"
    kid="$(echo "${out}" | awk -F': *' '/Key ID/ {print $2}')"
    ksec="$(echo "${out}" | awk -F': *' '/Secret key/ {print $2}')"
    varname="$(echo "${b}" | tr 'a-z-' 'A-Z_')"
    {
      echo "S3_${varname}_ACCESS_KEY=${kid}"
      echo "S3_${varname}_SECRET_KEY=${ksec}"
    } >>"${CREDS}"
  fi
  garage bucket allow --read --write --owner "${b}" --key "${key}"
done

garage status
garage bucket list
cat <<EOF

Garage is ready.
  S3 endpoint:  https://${MINIO_VIP:-${NODE_IP}}:${GARAGE_TLS_PORT}   region: garage   path-style addressing
  TLS cert:     ${TLS_DIR}/server.crt  (give it to clients as their CA file)
  Credentials:  ${CREDS}  (one key per bucket; keep it root-only, move to Vault, then delete)
Test: AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... aws --endpoint-url https://${NODE_IP}:${GARAGE_TLS_PORT} --ca-bundle ${TLS_DIR}/server.crt --region garage s3 ls
EOF
