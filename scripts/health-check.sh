#!/usr/bin/env bash
# scripts/health-check.sh
# Performs a comprehensive OS and infrastructure health check across all nodes
# in the selected inventory (CPU load, RAM usage, Disk space, Swap, SSH, Fail2Ban, Chrony).
#
# Usage:
#   ./scripts/health-check.sh [--env local|production] [--limit <pattern>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_NAME="local"
LIMIT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)
      ENV_NAME="$2"
      shift 2
      ;;
    -l|--limit)
      LIMIT_ARGS=("-l" "$2")
      shift 2
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--env local|production] [--limit <host_or_group>]"
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
echo " On-Premises DevOps Platform - Node Health Check (${ENV_NAME})"
echo " Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "======================================================================"

ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -b -m ansible.builtin.shell -a '
  set -e
  OS_VER=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d "\"")
  UPTIME_STR=$(uptime -p)
  LOAD_AVG=$(awk "{print \$1, \$2, \$3}" /proc/loadavg)
  MEM_INFO=$(free -m | awk "/Mem:/ {printf \"%d/%d MB (%d%%)\", \$3, \$2, (\$3*100)/\$2}")
  SWAP_INFO=$(free -m | awk "/Swap:/ {printf \"%d/%d MB\", \$3, \$2}")
  DISK_INFO=$(df -h / | tail -1 | awk "{printf \"%s/%s (%s)\", \$3, \$2, \$5}")
  SSH_STATE=$(systemctl is-active ssh || echo inactive)
  CHRONY_STATE=$(systemctl is-active chrony || echo inactive)
  FAIL2BAN_STATE=$(systemctl is-active fail2ban || echo inactive)

  echo "----------------------------------------------------------------------"
  echo "Node      : $(hostname -f) ($(hostname -I | awk "{print \$1}"))"
  echo "OS        : ${OS_VER} | Kernel: $(uname -r)"
  echo "Uptime    : ${UPTIME_STR} | Load Avg: ${LOAD_AVG}"
  echo "Memory    : ${MEM_INFO} | Swap: ${SWAP_INFO}"
  echo "Root Disk : ${DISK_INFO}"
  echo "Services  : ssh=${SSH_STATE} | chrony=${CHRONY_STATE} | fail2ban=${FAIL2BAN_STATE}"
'

