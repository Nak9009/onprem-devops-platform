#!/usr/bin/env bash
# multipass/destroy-vms.sh
# Safely stops, deletes, and purges Multipass VMs belonging to the DevOps platform.
# Never destroys existing VMs without explicit interactive confirmation (or --confirm-destroy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${MULTIPASS_PROFILE:-compact}"
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      PROFILE="$2"
      shift 2
      ;;
    --confirm-destroy)
      CONFIRM=true
      shift
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

PROFILE_FILE="${SCRIPT_DIR}/profiles/${PROFILE}.conf"
if [[ ! -f "${PROFILE_FILE}" ]]; then
  echo "[ERROR] Profile file not found: ${PROFILE_FILE}" >&2
  exit 1
fi

EXISTING_VMS="$(multipass list --format csv | tail -n +2 | cut -d',' -f1 || true)"
TARGET_VMS=()

while IFS='|' read -r vm_name vm_cpus vm_mem vm_disk vm_groups; do
  [[ -z "${vm_name}" || "${vm_name}" =~ ^# ]] && continue
  if echo "${EXISTING_VMS}" | grep -qx "${vm_name}"; then
    TARGET_VMS+=("${vm_name}")
  fi
done < "${PROFILE_FILE}"

if [[ ${#TARGET_VMS[@]} -eq 0 ]]; then
  echo "[INFO] No running or stopped Multipass VMs found for profile '${PROFILE}'."
  exit 0
fi

echo "======================================================================"
echo " WARNING: Destructive Operation - Destroy Local Multipass VMs"
echo "======================================================================"
echo "The following VMs in profile '${PROFILE}' will be permanently deleted:"
for vm in "${TARGET_VMS[@]}"; do
  echo "  - ${vm}"
done
echo ""

if [[ "${CONFIRM}" != "true" ]]; then
  read -r -p "Type 'yes' to confirm permanent deletion of these VMs: " USER_INPUT
  if [[ "${USER_INPUT}" != "yes" ]]; then
    echo "[ABORTED] VM destruction cancelled by user."
    exit 1
  fi
fi

for vm in "${TARGET_VMS[@]}"; do
  echo "[DELETE] Stopping and deleting ${vm}..."
  multipass delete --purge "${vm}"
done

echo "[OK] Selected Multipass VMs have been deleted and purged."

