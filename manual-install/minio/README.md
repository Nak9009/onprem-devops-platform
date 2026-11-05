# Garage S3 Object Storage Manual Installation & CLI Guide (`minio`)

> **Why Garage instead of MinIO?** MinIO discontinued pre-compiled binaries for its Community Edition (`dl.min.io` returns HTTP 410 Gone) and archived its open-source repositories. This module deploys **Garage (`v2.5.0`)**, a lightweight, geo-distributed S3-compatible object store built for self-hosted clusters, while preserving the existing `MINIO*_IP` / `MINIO_VIP` environment variable names for backward compatibility.

- **Target Host(s):**
  - **Local Mode (1 Node):** `devops-nexus` (`192.168.252.12`) — `replication_factor = 1`
  - **Production Mode (4-Node Cluster in `VLAN 60`):** `prod-minio-01..04` (`10.20.60.11..14`, shared Keepalived VIP `10.20.60.10`) — `replication_factor = 3`
- **Version:** Garage `v2.5.0` + Nginx TLS Reverse Proxy (`:9443`) + Keepalived VIP
- **Installed CLI:** `garage`
- **Automated Script:** [`manual-install/minio/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/minio/install.sh)

---

## 0. Automated Install (`install.sh`) — Read This First

The script automatically selects **distributed** mode (when the host IP matches `MINIO01_IP..MINIO04_IP`) or **single** mode (local lab).

### Single-Node (Local Lab)
```bash
sudo ./install.sh
```
Automatically starts Garage (`replication_factor = 1`), assigns the layout, provisions all platform buckets (`gitlab-backups`, `loki-chunks`, `terraform-state`, `artifacts`, `pgbackrest`), and writes per-bucket S3 keys to `/root/garage-s3-credentials.env`.

### 4-Node Distributed Cluster (Production)
```bash
# 1. Generate ONE shared RPC secret (64 hex chars) and compute the binary SHA256 on a trusted host:
export GARAGE_RPC_SECRET="$(openssl rand -hex 32)"
export GARAGE_SHA256="<sha256-of-garage-v2.5.0-binary>"
export GARAGE_VRRP_PASS="<strong-vrrp-pass>"

# 2. Run on prod-minio-01 first; copy /etc/garage/tls/server.{crt,key} to nodes 02..04 so all nodes share the VIP certificate.
# 3. Run on all 4 nodes (prod-minio-01..04). Each prints its node ID and saves it to /etc/garage/node-id.txt:
sudo PLATFORM_ENV=production GARAGE_RPC_SECRET="$GARAGE_RPC_SECRET" \
     GARAGE_SHA256="$GARAGE_SHA256" GARAGE_VRRP_PASS="$GARAGE_VRRP_PASS" ./install.sh

# 4. On prod-minio-01, bootstrap the cluster layout and create buckets + per-bucket keys:
sudo PLATFORM_ENV=production GARAGE_RPC_SECRET="$GARAGE_RPC_SECRET" \
     GARAGE_SHA256="$GARAGE_SHA256" GARAGE_VRRP_PASS="$GARAGE_VRRP_PASS" \
     GARAGE_BOOTSTRAP=true \
     GARAGE_PEERS="<id2@10.20.60.12:3901>,<id3@10.20.60.13:3901>,<id4@10.20.60.14:3901>" \
     ./install.sh
```

| Variable | Purpose | Default |
|---|---|---|
| `GARAGE_VER` | Pinned Garage release tag | `v2.5.0` |
| `GARAGE_SHA256` | Expected SHA256 of the binary (**required in production**) | unset |
| `GARAGE_RPC_SECRET` | 64-char hex RPC secret shared across all cluster nodes | auto-generated in single mode |
| `GARAGE_TLS_PORT` | HTTPS port served by Nginx in front of `127.0.0.1:3900` | `9443` |
| `GARAGE_CAPACITY` | Per-node storage capacity assigned in layout | 90% of `GARAGE_DATA_DIR` filesystem |
| `GARAGE_BUCKETS` | Space-separated buckets created on bootstrap | `gitlab-backups loki-chunks terraform-state artifacts pgbackrest` |

---

## 1. Architecture & Security Details

- **TLS Termination:** Garage's S3 API (`127.0.0.1:3900`) and Admin API (`127.0.0.1:3903`) listen on loopback only. Nginx terminates TLS (`TLSv1.2`/`TLSv1.3`) on port `9443` and proxies `/` to `:3900` and `/health` to `:3903/health`.
- **High Availability VIP:** In 4-node mode, Keepalived floats `MINIO_VIP` (`10.20.60.10`) across nodes `01..04` using `systemctl is-active --quiet garage nginx` as its health check.
- **Least-Privilege Keys:** Instead of a single root key, bootstrap creates one dedicated key per bucket (`svc-gitlab-backups`, `svc-pgbackrest`, etc.) and writes them to `/root/garage-s3-credentials.env` (`0600`). Copy those credentials into HashiCorp Vault and delete the file.

---

## 2. `garage` CLI & S3 Client Reference

```bash
# 1. Inspect cluster status, nodes, and layout
sudo garage status
sudo garage layout show

# 2. List buckets and inspect size / authorized keys
sudo garage bucket list
sudo garage bucket info pgbackrest

# 3. List or create API access keys
sudo garage key list
sudo garage key info svc-pgbackrest

# 4. Test S3 API using AWS CLI (path-style addressing, region 'garage')
source /root/garage-s3-credentials.env
AWS_ACCESS_KEY_ID="$S3_PGBACKREST_ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$S3_PGBACKREST_SECRET_KEY" \
  aws --endpoint-url "https://${MINIO_VIP:-127.0.0.1}:9443" \
      --ca-bundle /etc/garage/tls/server.crt \
      --region garage s3 ls
```
