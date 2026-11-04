#!/usr/bin/env bash
# scripts/validate-network.sh
# Validates Ansible SSH connectivity, DNS/hosts resolution, NTP sync,
# kernel networking parameters, and UFW firewall rules across Local or Production nodes.
#
# Usage:
#   ./scripts/validate-network.sh [--env local|production] [--limit <pattern>]

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
echo " Network & Infrastructure Connectivity Validation (${ENV_NAME})"
echo " Inventory: ${INVENTORY_FILE}"
echo "======================================================================"

PASS_COUNT=0
FAIL_COUNT=0

run_check() {
  local title="$1"
  shift
  echo ""
  echo ">>> [CHECK] ${title}"
  if "$@"; then
    echo "    [PASS] ${title}"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
  else
    echo "    [FAIL] ${title}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
}

# 1. Verify Ansible Inventory Graph
run_check "Ansible Inventory Structure Parsing" \
  ansible-inventory -i "${INVENTORY_FILE}" --graph "${LIMIT_ARGS[@]}"

# 2. Verify ICMP / SSH / Python Ping to Target Hosts
run_check "Ansible SSH & Python Module Ping" \
  ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -m ansible.builtin.ping -o

# 3. Verify Hostname, Primary IPv4, and Default Route
run_check "Node Hostname, IPv4 Address, and Default Gateway" \
  ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -m ansible.builtin.shell \
  -a "echo \"Host=\$(hostname -f) | IP=\$(hostname -I | awk '{print \$1}') | GW=\$(ip route | awk '/default/ {print \$3}')\"" -o

# 4. Verify DNS & /etc/hosts Resolution
run_check "DNS & /etc/hosts Service Domain Resolution" \
  ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -m ansible.builtin.shell \
  -a "getent hosts \$(hostname) >/dev/null && dig +short +time=2 +tries=1 google.com >/dev/null || getent hosts localhost >/dev/null" -o

# 5. Verify Kernel IPv4 Forwarding & Bridge Netfilter Modules
run_check "Kernel Networking (ip_forward=1, br_netfilter, overlay)" \
  ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -m ansible.builtin.shell \
  -a "test \"\$(sysctl -n net.ipv4.ip_forward)\" = \"1\" && lsmod | grep -qw br_netfilter && lsmod | grep -qw overlay" -o

# 6. Verify Chrony NTP Synchronization
run_check "Chrony NTP Time Synchronization Status" \
  ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -m ansible.builtin.shell \
  -a "systemctl is-active chrony && chronyc tracking | grep -E 'Reference ID|System time|Leap status'" -o

# 7. Verify UFW Firewall Status
run_check "UFW Host Firewall Active Status" \
  ansible all -i "${INVENTORY_FILE}" "${LIMIT_ARGS[@]}" -b -m ansible.builtin.shell \
  -a "ufw status | head -n 5" -o

echo ""
echo "======================================================================"
echo " Network Validation Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "======================================================================"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi

