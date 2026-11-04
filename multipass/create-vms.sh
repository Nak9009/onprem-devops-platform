#!/usr/bin/env bash
# multipass/create-vms.sh
# Idempotent Multipass VM provisioning script for the On-Premises DevOps Platform.
#
# Usage:
#   ./multipass/create-vms.sh [--profile compact|minimal|ha] [--recreate] [--dry-run] [--allow-overcommit]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE="${MULTIPASS_PROFILE:-compact}"
UBUNTU_RELEASE="24.04"
RECREATE=false
DRY_RUN=false
ALLOW_OVERCOMMIT=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -p, --profile <name>     VM sizing profile: compact (default, <=24GB host), minimal (32GB), ha (48GB)
  -r, --recreate           Destroy existing profile VMs (with confirmation) before creating
  -d, --dry-run            Validate resources and display planned multipass commands without executing
  -f, --allow-overcommit   Allow launching even if total VM RAM exceeds 80% of host physical RAM
  -h, --help               Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      PROFILE="$2"
      shift 2
      ;;
    -r|--recreate)
      RECREATE=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -f|--allow-overcommit)
      ALLOW_OVERCOMMIT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

PROFILE_FILE="${SCRIPT_DIR}/profiles/${PROFILE}.conf"
if [[ ! -f "${PROFILE_FILE}" ]]; then
  echo "[ERROR] Profile file not found: ${PROFILE_FILE}" >&2
  echo "Available profiles: compact, minimal, ha" >&2
  exit 1
fi

echo "======================================================================"
echo " On-Premises DevOps Platform - Multipass Environment Provisioner"
echo " Selected Profile : ${PROFILE} (${PROFILE_FILE})"
echo " Target OS Image  : Ubuntu Server ${UBUNTU_RELEASE} LTS"
echo "======================================================================"

# 1. Verify Multipass installation
if ! command -v multipass >/dev/null 2>&1; then
  echo "[ERROR] 'multipass' CLI is not installed or not in PATH." >&2
  echo "Install on macOS: brew install --cask multipass" >&2
  exit 1
fi

echo "[INFO] Multipass version:"
multipass version | sed 's/^/  /'

# 2. Parse profile requirements
convert_to_mb() {
  local val="$1"
  if [[ "${val}" =~ ^([0-9]+)G$ ]]; then
    echo $(( BASH_REMATCH[1] * 1024 ))
  elif [[ "${val}" =~ ^([0-9]+)M$ ]]; then
    echo $(( BASH_REMATCH[1] ))
  else
    echo 2048
  fi
}

TOTAL_REQ_CPUS=0
TOTAL_REQ_MEM_MB=0
VM_COUNT=0

while IFS='|' read -r vm_name vm_cpus vm_mem vm_disk vm_groups; do
  [[ -z "${vm_name}" || "${vm_name}" =~ ^# ]] && continue
  TOTAL_REQ_CPUS=$(( TOTAL_REQ_CPUS + vm_cpus ))
  MEM_MB=$(convert_to_mb "${vm_mem}")
  TOTAL_REQ_MEM_MB=$(( TOTAL_REQ_MEM_MB + MEM_MB ))
  VM_COUNT=$(( VM_COUNT + 1 ))
done < "${PROFILE_FILE}"

# 3. Check Workstation Resources
if [[ "$(uname -s)" == "Darwin" ]]; then
  HOST_CPUS=$(sysctl -n hw.ncpu)
  HOST_MEM_BYTES=$(sysctl -n hw.memsize)
  HOST_MEM_MB=$(( HOST_MEM_BYTES / 1024 / 1024 ))
else
  HOST_CPUS=$(nproc)
  HOST_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  HOST_MEM_MB=$(( HOST_MEM_KB / 1024 ))
fi

SAFE_MEM_THRESHOLD_MB=$(( HOST_MEM_MB * 80 / 100 ))

echo "[INFO] Workstation Resource Assessment:"
echo "  Host Physical CPUs      : ${HOST_CPUS} cores"
echo "  Host Physical Memory    : ${HOST_MEM_MB} MB ($(( HOST_MEM_MB / 1024 )) GB)"
echo "  Safe VM Memory Ceiling  : ${SAFE_MEM_THRESHOLD_MB} MB (80% of host RAM)"
echo "  Profile VM Count        : ${VM_COUNT} VMs"
echo "  Profile Total vCPUs     : ${TOTAL_REQ_CPUS} vCPUs (shared across hypervisor)"
echo "  Profile Total Memory    : ${TOTAL_REQ_MEM_MB} MB (~$(( (TOTAL_REQ_MEM_MB + 512) / 1024 )) GB)"

if (( TOTAL_REQ_MEM_MB > SAFE_MEM_THRESHOLD_MB )) && [[ "${ALLOW_OVERCOMMIT}" == "false" ]]; then
  echo ""
  echo "[ERROR] Profile '${PROFILE}' requires ${TOTAL_REQ_MEM_MB} MB RAM, which exceeds the safe ceiling"
  echo "        of ${SAFE_MEM_THRESHOLD_MB} MB on this ${HOST_MEM_MB} MB workstation."
  echo "        Recommendation: Run with '--profile compact' (16.5 GB total) or pass '--allow-overcommit'."
  exit 1
fi

# 4. Handle optional --recreate
if [[ "${RECREATE}" == "true" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Would invoke destroy-vms.sh --profile ${PROFILE}"
  else
    "${SCRIPT_DIR}/destroy-vms.sh" --profile "${PROFILE}"
  fi
fi

# 5. Prepare SSH Keypair and Cloud-Init Configuration
SSH_DIR="${SCRIPT_DIR}/.ssh"
SSH_KEY="${SSH_DIR}/id_ed25519"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init-rendered.yaml"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "[INFO] Generating dedicated Ed25519 SSH keypair at ${SSH_KEY}..."
  ssh-keygen -t ed25519 -C "ansible@onprem-devops-local" -f "${SSH_KEY}" -N "" >/dev/null
fi

PUB_KEY_CONTENT="$(cat "${SSH_KEY}.pub")"

cat > "${CLOUD_INIT_FILE}" <<EOF
#cloud-config
package_update: true
users:
  - default
  - name: ansible
    gecos: Ansible Automation User
    groups: [adm, sudo]
    lock_passwd: true
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${PUB_KEY_CONTENT}
EOF

# 6. Query existing Multipass VMs for idempotency
EXISTING_VMS="$(multipass list --format csv | tail -n +2 | cut -d',' -f1 || true)"

# 7. Launch or start VMs in profile
echo ""
echo "[INFO] Provisioning VMs for profile '${PROFILE}'..."

while IFS='|' read -r vm_name vm_cpus vm_mem vm_disk vm_groups; do
  [[ -z "${vm_name}" || "${vm_name}" =~ ^# ]] && continue

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY-RUN] multipass launch ${UBUNTU_RELEASE} --name ${vm_name} --cpus ${vm_cpus} --memory ${vm_mem} --disk ${vm_disk} --cloud-init ${CLOUD_INIT_FILE}"
    continue
  fi

  if echo "${EXISTING_VMS}" | grep -qx "${vm_name}"; then
    VM_STATE="$(multipass info "${vm_name}" --format csv | tail -n +2 | cut -d',' -f2)"
    if [[ "${VM_STATE}" == "Running" ]]; then
      echo "  [OK] ${vm_name} already exists and is Running (idempotent skip)."
    else
      echo "  [START] ${vm_name} exists in state '${VM_STATE}'. Starting..."
      multipass start "${vm_name}"
    fi
  else
    echo "  [CREATE] Launching ${vm_name} (cpus=${vm_cpus}, memory=${vm_mem}, disk=${vm_disk})..."
    multipass launch "${UBUNTU_RELEASE}" \
      --name "${vm_name}" \
      --cpus "${vm_cpus}" \
      --memory "${vm_mem}" \
      --disk "${vm_disk}" \
      --cloud-init "${CLOUD_INIT_FILE}" \
      --timeout 600
  fi
done < "${PROFILE_FILE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "[DRY-RUN] Complete. No VMs were created."
  exit 0
fi

# 8. Generate Ansible Inventory from live Multipass IPs
echo ""
"${SCRIPT_DIR}/generate-inventory.sh" --profile "${PROFILE}"

# 9. Display environment status
echo ""
"${SCRIPT_DIR}/status.sh" --profile "${PROFILE}"

