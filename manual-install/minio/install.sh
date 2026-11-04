#!/usr/bin/env bash
# ==============================================================================
# MinIO Server + MinIO Client (mc) CLI Installer (Ubuntu 24.04 LTS)
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
MINIO_VER="${MINIO_VER:-RELEASE.2024-12-18T13-15-44Z}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASS="${MINIO_ROOT_PASS:-ChangeMe_MinioSecretKey_2026!}"

echo "[1/4] Creating minio-user and directories..."
groupadd --system minio-user 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g minio-user minio-user 2>/dev/null || true
mkdir -p /var/lib/minio/data /etc/minio
chown -R minio-user:minio-user /var/lib/minio /etc/minio

echo "[2/4] Downloading MinIO (${MINIO_VER}) and mc CLI..."
curl -fsSL "https://dl.min.io/server/minio/release/linux-${ARCH}/archive/minio.${MINIO_VER}" \
  -o /usr/local/bin/minio
curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" \
  -o /usr/local/bin/mc
chmod 0755 /usr/local/bin/minio /usr/local/bin/mc

echo "[3/4] Configuring /etc/default/minio and systemd unit..."
cat >/etc/default/minio <<EOF
MINIO_VOLUMES="/var/lib/minio/data"
MINIO_OPTS="--address :9000 --console-address :9001"
MINIO_ROOT_USER="${MINIO_ROOT_USER}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASS}"
EOF
chmod 0600 /etc/default/minio
chown minio-user:minio-user /etc/default/minio

cat >/etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO S3-Compatible Object Storage
Wants=network-online.target
After=network-online.target

[Service]
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

ufw allow 9000/tcp comment 'MinIO S3 API'
ufw allow 9001/tcp comment 'MinIO Web Console'

systemctl daemon-reload
systemctl enable --now minio
sleep 3

echo "[4/4] Provisioning platform S3 buckets with mc CLI..."
mc alias set local http://127.0.0.1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASS}"
for bucket in gitlab-backups loki-chunks terraform-state artifacts; do
  mc mb --ignore-existing "local/${bucket}"
done
mc ls local
echo "MinIO Server and mc CLI installation complete."

