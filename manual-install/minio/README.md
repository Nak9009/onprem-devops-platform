# MinIO S3 Storage Server Manual Installation & `mc` CLI Guide (`minio`)

- **Target Host:** `devops-nexus` (`192.168.252.12`) in local mode, or `prod-minio-01` (`10.20.10.15`) in production
- **Version:** MinIO Server `RELEASE.2024-12-18T13-15-44Z` + MinIO Client (`mc`) CLI
- **Automated Script:** [`manual-install/minio/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/minio/install.sh)

---

## 1. Create `minio-user` & Install `minio` + `mc` CLI Binaries

```bash
ARCH=$(dpkg --print-architecture) # amd64 or arm64
MINIO_VER="RELEASE.2024-12-18T13-15-44Z"

sudo groupadd --system minio-user || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g minio-user minio-user || true
sudo mkdir -p /var/lib/minio/data /etc/minio
sudo chown -R minio-user:minio-user /var/lib/minio /etc/minio

# Download MinIO Server binary
sudo curl -fsSL "https://dl.min.io/server/minio/release/linux-${ARCH}/archive/minio.${MINIO_VER}" \
  -o /usr/local/bin/minio

# Download MinIO Client (mc) CLI binary
sudo curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" \
  -o /usr/local/bin/mc

sudo chmod 0755 /usr/local/bin/minio /usr/local/bin/mc
```

---

## 2. Configure `/etc/default/minio`, Systemd Service & UFW Ports

```bash
export MINIO_ROOT_USER="minioadmin"
export MINIO_ROOT_PASS="ChangeMe_MinioSecretKey_2026!"

sudo tee /etc/default/minio >/dev/null <<EOF
MINIO_VOLUMES="/var/lib/minio/data"
MINIO_OPTS="--address :9000 --console-address :9001"
MINIO_ROOT_USER="${MINIO_ROOT_USER}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASS}"
EOF
sudo chmod 0600 /etc/default/minio
sudo chown minio-user:minio-user /etc/default/minio

sudo tee /etc/systemd/system/minio.service >/dev/null <<'EOF'
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

sudo ufw allow 9000/tcp comment 'MinIO S3 API'
sudo ufw allow 9001/tcp comment 'MinIO Web Console'

sudo systemctl daemon-reload
sudo systemctl enable --now minio
```

---

## 3. MinIO Client (`mc`) CLI Reference

```bash
# 1. Configure 'local' alias pointing to the MinIO S3 endpoint
mc alias set local http://127.0.0.1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASS}"

# 2. Check MinIO server cluster and drive health via CLI
mc admin info local

# 3. Create required platform S3 buckets (idempotent)
for bucket in gitlab-backups loki-chunks terraform-state artifacts; do
  mc mb --ignore-existing "local/${bucket}"
done

# 4. List all buckets and objects
mc ls local
mc ls --recursive local/gitlab-backups

# 5. Configure a 30-day automatic expiration lifecycle rule on gitlab-backups
mc ilm rule add --expire-days 30 local/gitlab-backups
mc ilm rule ls local/gitlab-backups

# 6. Upload, download, or mirror backup directories to S3
mc cp /var/backups/archive.tar.gz local/artifacts/
mc mirror /var/opt/gitlab/backups/ local/gitlab-backups/

# 7. Create a dedicated service account / access key for GitLab or Loki
mc admin user svcacct add local "${MINIO_ROOT_USER}"
```

