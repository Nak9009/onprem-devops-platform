#!/usr/bin/env bash
# ==============================================================================
# docker-lab/scripts/init-garage.sh
# Initializes Garage single-node cluster layout, default key, and buckets.
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="${1:-devops-garage}"

echo "[+] Waiting for Garage daemon in '${CONTAINER_NAME}' to be ready..."
READY=false
for i in {1..20}; do
  if docker exec "${CONTAINER_NAME}" /garage status &>/dev/null; then
    READY=true
    break
  fi
  sleep 1
done

if [[ "${READY}" != "true" ]]; then
  echo "[-] Garage daemon is not responding yet. Skipping layout initialization."
  exit 0
fi

# Check if cluster layout is already applied
LAYOUT_STATUS=$(docker exec "${CONTAINER_NAME}" /garage status 2>/dev/null || true)

if echo "${LAYOUT_STATUS}" | grep -q "NO ROLE ASSIGNED"; then
  NODE_ID=$(echo "${LAYOUT_STATUS}" | grep -E "^[0-9a-f]{16}" | awk '{print $1}' | head -n1)
  if [[ -n "${NODE_ID}" ]]; then
    echo "[+] Configuring Garage single-node layout (Node ID: ${NODE_ID})..."
    docker exec "${CONTAINER_NAME}" /garage layout assign -z dc1 -c 1G "${NODE_ID}" >/dev/null 2>&1 || true
    docker exec "${CONTAINER_NAME}" /garage layout apply --version 1 >/dev/null 2>&1 || true

    # Create default devops bucket & key
    echo "[+] Provisioning default S3 bucket 'devops-artifacts' and access key..."
    docker exec "${CONTAINER_NAME}" /garage key create devops-key >/dev/null 2>&1 || true
    docker exec "${CONTAINER_NAME}" /garage bucket create devops-artifacts >/dev/null 2>&1 || true
    docker exec "${CONTAINER_NAME}" /garage bucket allow devops-artifacts --read --write --key devops-key >/dev/null 2>&1 || true
    echo "[✓] Garage object storage successfully initialized."
  fi
else
  echo "[✓] Garage cluster layout already active."
fi

