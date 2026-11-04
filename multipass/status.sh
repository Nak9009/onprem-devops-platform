#!/usr/bin/env bash
# multipass/status.sh
# Displays the status, IP addresses, and resource allocations of local Multipass VMs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${MULTIPASS_PROFILE:-compact}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      PROFILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

PROFILE_FILE="${SCRIPT_DIR}/profiles/${PROFILE}.conf"

echo "======================================================================"
echo " Multipass VM Status (Profile: ${PROFILE})"
echo "======================================================================"

if ! command -v multipass >/dev/null 2>&1; then
  echo "[ERROR] Multipass CLI is not installed." >&2
  exit 1
fi

printf "%-18s %-12s %-16s %-8s %-10s %-10s\n" "VM NAME" "STATE" "IPV4 ADDRESS" "CPUS" "MEMORY" "DISK"
printf "%-18s %-12s %-16s %-8s %-10s %-10s\n" "------------------" "------------" "----------------" "--------" "----------" "----------"

EXISTING_CSV="$(multipass list --format csv | tail -n +2 || true)"

while IFS='|' read -r vm_name vm_cpus vm_mem vm_disk vm_groups; do
  [[ -z "${vm_name}" || "${vm_name}" =~ ^# ]] && continue
  ROW="$(echo "${EXISTING_CSV}" | grep "^${vm_name}," || true)"
  if [[ -n "${ROW}" ]]; then
    STATE="$(echo "${ROW}" | cut -d',' -f2)"
    IPV4="$(echo "${ROW}" | cut -d',' -f3)"
    printf "%-18s %-12s %-16s %-8s %-10s %-10s\n" "${vm_name}" "${STATE}" "${IPV4:-N/A}" "${vm_cpus}" "${vm_mem}" "${vm_disk}"
  else
    printf "%-18s %-12s %-16s %-8s %-10s %-10s\n" "${vm_name}" "NotCreated" "-" "${vm_cpus}" "${vm_mem}" "${vm_disk}"
  fi
done < "${PROFILE_FILE}"

echo "======================================================================"

