#!/usr/bin/env bash
# ==============================================================================
# docker-lab/destroy-lab.sh
# Safely stop and destroy the Docker Lab environment
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

REMOVE_VOLUMES=false

usage() {
  cat <<EOF
Usage: ./destroy-lab.sh [OPTIONS]

Options:
  -v, --volumes   Remove named Docker volumes (WARNING: permanently wipes all lab data)
  -h, --help      Show this help message

Examples:
  ./destroy-lab.sh              # Stop containers, keep persistent data
  ./destroy-lab.sh --volumes    # Stop containers and wipe all databases/volumes
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--volumes)
      REMOVE_VOLUMES=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

echo "======================================================================"
echo "    Destroying 3-Layer On-Premises DevOps Platform - Docker Lab"
echo "======================================================================"

# 1. Stop Docker Compose Stack
DOWN_ARGS="--profile all down"
if [[ "${REMOVE_VOLUMES}" == "true" ]]; then
  DOWN_ARGS="${DOWN_ARGS} -v"
  echo "[!] WARNING: Deleting persistent volumes."
fi

echo "[+] Stopping Docker Compose services..."
docker compose ${DOWN_ARGS} || true

# 2. Delete KinD Clusters if present
if command -v kind &> /dev/null; then
  CLUSTERS=$(kind get clusters 2>/dev/null || true)

  if echo "${CLUSTERS}" | grep -q "onprem-mgmt-k8s"; then
    echo "[+] Deleting KinD Management Cluster 'onprem-mgmt-k8s'..."
    kind delete cluster --name onprem-mgmt-k8s || true
  fi

  if echo "${CLUSTERS}" | grep -q "onprem-app-k8s"; then
    echo "[+] Deleting KinD Application Cluster 'onprem-app-k8s'..."
    kind delete cluster --name onprem-app-k8s || true
  fi
fi

# 3. Clean up network
if docker network inspect devops-net &> /dev/null; then
  echo "[+] Removing 'devops-net' bridge network..."
  docker network rm devops-net 2>/dev/null || true
fi

echo "[✓] Docker Lab teardown complete."

