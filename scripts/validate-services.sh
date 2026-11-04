#!/usr/bin/env bash
# scripts/validate-services.sh
# Phase-aware automated validation script for both Local and Production environments.
#
# Usage:
#   ./scripts/validate-services.sh [--env local|production] [--phase 2|3|4|5|6|all] [--limit <pattern>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_NAME="local"
PHASE="2"
LIMIT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)
      ENV_NAME="$2"
      shift 2
      ;;
    -p|--phase)
      PHASE="$2"
      shift 2
      ;;
    -l|--limit)
      LIMIT_ARGS=("-l" "$2")
      shift 2
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--env local|production] [--phase 2|3|4|5|6|all] [--limit <pattern>]"
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

INVENTORY_FILE="${PROJECT_ROOT}/inventories/${ENV_NAME}/hosts.yml"
if [[ ! -f "${INVENTORY_FILE}" ]]; then
  echo "[ERROR] Inventory file not found: ${INVENTORY_FILE}" >&2
  exit 1
fi

echo "======================================================================"
echo " Platform Service Validator | Environment: ${ENV_NAME} | Phase: ${PHASE}"
echo "======================================================================"

validate_phase2() {
  echo ">>> [Phase 2] Validating OS Baseline, SSH Hardening, Kernel Sysctl, and Firewall..."
  "${SCRIPT_DIR}/validate-network.sh" --env "${ENV_NAME}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"}
  "${SCRIPT_DIR}/health-check.sh" --env "${ENV_NAME}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"}
}

validate_phase3() {
  echo ">>> [Phase 3] Validating DevOps Core Services (GitLab, Jenkins, Nexus, MinIO)..."
  ansible gitlab -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1/-/readiness status_code=200" -o
  ansible jenkins -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1:8080/login status_code=200" -o
  ansible nexus -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1:8081/service/rest/v1/status status_code=200" -o
  ansible minio -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1:9000/minio/health/live status_code=200" -o
}

validate_phase4() {
  echo ">>> [Phase 4] Validating Kubernetes Control Plane, Workers, Calico, Rancher, and Argo CD..."
  ansible k8s_control_plane[0] -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -b -m ansible.builtin.shell \
    -a "kubectl get nodes -o wide && kubectl get pods -A"
  ansible rancher -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=https://127.0.0.1/ping validate_certs=no status_code=200" -o
}

validate_phase6() {
  echo ">>> [Phase 6] Validating Monitoring & Logging Stack (Prometheus, Grafana, Loki)..."
  ansible monitoring -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1:9090/-/healthy status_code=200" -o
  ansible monitoring -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1:3000/api/health status_code=200" -o
  ansible monitoring -i "${INVENTORY_FILE}" ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} -m ansible.builtin.uri \
    -a "url=http://127.0.0.1:3100/ready status_code=200" -o
}

case "${PHASE}" in
  2)
    validate_phase2
    ;;
  3)
    validate_phase3
    ;;
  4|5)
    validate_phase4
    ;;
  6)
    validate_phase6
    ;;
  all)
    validate_phase2
    validate_phase3
    validate_phase4
    validate_phase6
    ;;
  *)
    echo "[ERROR] Unsupported phase: ${PHASE}" >&2
    exit 1
    ;;
esac

echo "[OK] Phase ${PHASE} validation completed successfully."

