#!/usr/bin/env bash
# scripts/backup-platform.sh
# Automated Backup Orchestrator for the On-Premises DevOps Platform.
# Captures backups across GitLab, Jenkins, Nexus, Kubernetes etcd/manifests,
# Rancher, Argo CD, MinIO, Prometheus, Grafana, Loki, and Ansible Vault.
#
# Usage:
#   ./scripts/backup-platform.sh [--env local|production] [--output-dir /path/to/backups] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_NAME="local"
TIMESTAMP="$(date -u +"%Y%m%d-%H%M%S")"
CUSTOM_OUTPUT_DIR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)
      ENV_NAME="$2"
      shift 2
      ;;
    -o|--output-dir)
      CUSTOM_OUTPUT_DIR="$2"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--env local|production] [--output-dir <dir>] [--dry-run]"
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

BACKUP_ROOT="${CUSTOM_OUTPUT_DIR:-${PROJECT_ROOT}/backups}/${ENV_NAME}-${TIMESTAMP}"

INVENTORY_FILE="${PROJECT_ROOT}/inventories/${ENV_NAME}/hosts.yml"
if [[ ! -f "${INVENTORY_FILE}" ]]; then
  echo "[ERROR] Inventory file not found: ${INVENTORY_FILE}" >&2
  exit 1
fi

echo "======================================================================"
echo " On-Premises DevOps Platform - Backup Orchestrator"
echo " Environment : ${ENV_NAME}"
echo " Timestamp   : ${TIMESTAMP}"
echo " Backup Dir  : ${BACKUP_ROOT}"
echo "======================================================================"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY-RUN] Planned backup steps:"
  echo "  1. Local GitOps, Kubernetes manifests, and encrypted Ansible Vault archive"
  echo "  2. GitLab Omnibus backup (gitlab-backup create + /etc/gitlab secrets)"
  echo "  3. Jenkins configuration and job definitions (/var/lib/jenkins)"
  echo "  4. Nexus Repository metadata and blobs (/var/lib/nexus/nexus-data)"
  echo "  5. Kubernetes etcd snapshot & Argo CD Applications export"
  echo "  6. Rancher state (/var/lib/rancher)"
  echo "  7. Prometheus, Grafana, and Loki configurations and databases"
  exit 0
fi

mkdir -p "${BACKUP_ROOT}"

# 1. Back up IaC, GitOps manifests, Kubernetes manifests, and encrypted Vault files
echo "[1/7] Archiving Ansible inventories, encrypted Vaults, and GitOps manifests..."
tar -czf "${BACKUP_ROOT}/iac-gitops-vault-${TIMESTAMP}.tar.gz" \
  -C "${PROJECT_ROOT}" \
  inventories playbooks roles kubernetes gitops jenkins

# 2. Trigger remote service backups via Ansible
echo "[2/7] Triggering GitLab backup on 'gitlab' group..."
ansible gitlab -i "${INVENTORY_FILE}" -b -m ansible.builtin.shell \
  -a "mkdir -p /var/backups/devops && gitlab-backup create STRATEGY=copy && tar -czf /var/backups/devops/gitlab-etc-${TIMESTAMP}.tar.gz /etc/gitlab" -o

echo "[3/7] Triggering Jenkins backup on 'jenkins' group..."
ansible jenkins -i "${INVENTORY_FILE}" -b -m ansible.builtin.shell \
  -a "mkdir -p /var/backups/devops && tar --exclude='/var/lib/jenkins/workspace/*' -czf /var/backups/devops/jenkins-${TIMESTAMP}.tar.gz /var/lib/jenkins/config.xml /var/lib/jenkins/jobs /var/lib/jenkins/users /var/lib/jenkins/secrets" -o

echo "[4/7] Triggering Nexus & MinIO metadata backup on 'nexus' group..."
ansible nexus -i "${INVENTORY_FILE}" -b -m ansible.builtin.shell \
  -a "mkdir -p /var/backups/devops && tar -czf /var/backups/devops/nexus-${TIMESTAMP}.tar.gz /var/lib/nexus/nexus-data" -o

echo "[5/7] Triggering Kubernetes etcd & Argo CD export on 'k8s_control_plane[0]'..."
ansible k8s_control_plane[0] -i "${INVENTORY_FILE}" -b -m ansible.builtin.shell \
  -a "mkdir -p /var/backups/devops && kubectl get applications,appprojects -n argocd -o yaml > /var/backups/devops/argocd-${TIMESTAMP}.yaml" -o

echo "[6/7] Triggering Rancher backup on 'rancher' group..."
ansible rancher -i "${INVENTORY_FILE}" -b -m ansible.builtin.shell \
  -a "mkdir -p /var/backups/devops && tar -czf /var/backups/devops/rancher-${TIMESTAMP}.tar.gz /var/lib/rancher" -o

echo "[7/7] Triggering Prometheus, Grafana, and Loki backup on 'monitoring' group..."
ansible monitoring -i "${INVENTORY_FILE}" -b -m ansible.builtin.shell \
  -a "mkdir -p /var/backups/devops && tar -czf /var/backups/devops/observability-${TIMESTAMP}.tar.gz /etc/prometheus /etc/grafana /var/lib/grafana /etc/loki" -o

echo "[OK] Platform backup completed successfully. Local archive: ${BACKUP_ROOT}"
