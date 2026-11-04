#!/usr/bin/env bash
# ==============================================================================
# Layer 2 Dedicated Kubernetes Management Cluster (Rancher + Argo CD) Installer
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  # shellcheck disable=SC1090
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

export POD_CIDR="${MGMT_POD_CIDR:-10.243.0.0/16}"
export SVC_CIDR="${MGMT_SVC_CIDR:-10.95.0.0/12}"
export ALLOW_WORKLOADS_ON_CP="true"
export INSTALL_ARGOCD="true"

# Delegate K8s + Calico + Argo CD installation to kubernetes-cp/install.sh
bash "${SCRIPT_DIR}/../kubernetes-cp/install.sh"
echo "Layer 2 Management Kubernetes Cluster (with Argo CD) ready."
