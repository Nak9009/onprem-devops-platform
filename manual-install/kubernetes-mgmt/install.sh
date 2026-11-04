#!/usr/bin/env bash
# ==============================================================================
# Layer 2 Dedicated Kubernetes Management Cluster (Rancher + Argo CD) Installer
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MGMT_POD_CIDR="${MGMT_POD_CIDR:-10.243.0.0/16}"
export MGMT_SVC_CIDR="${MGMT_SVC_CIDR:-10.95.0.0/12}"
export ALLOW_WORKLOADS_ON_CP="true"

# Delegate base K8s + Calico + Argo CD installation to kubernetes-cp/install.sh
bash "${SCRIPT_DIR}/../kubernetes-cp/install.sh"
echo "Layer 2 Management Kubernetes Cluster (with Argo CD) ready."

