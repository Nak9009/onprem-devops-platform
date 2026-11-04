#!/usr/bin/env bash
# multipass/create-vms.sh
# Idempotent Multipass VM provisioning script for the On-Premises DevOps Platform.
#
# Usage:
#   ./multipass/create-vms.sh [--profile compact|minimal|ha] [--vm <name>] [--recreate] [--dry-run] [--allow-overcommit] [--skip-disk-check]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE="${MULTIPASS_PROFILE:-compact}"
UBUNTU_RELEASE="24.04"
RECREATE=false
DRY_RUN=false
ALLOW_OVERCOMMIT=false
SKIP_DISK_CHECK=false
TARGET_VM_FILTER=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -p, --profile <name>     VM sizing profile: compact (default, <=24GB host), minimal (32GB), ha (48GB)
  -v, --vm <name1,name2>   Provision only specific VM(s) from the profile (useful when host disk is low)
  -r, --recreate           Destroy existing profile VMs (with confirmation) before creating
  -d, --dry-run            Validate resources and display planned multipass commands without executing
  -f, --allow-overcommit   Allow launching even if total VM RAM exceeds 80% of host physical RAM
  --skip-disk-check        Allow launching even if host free disk space is below the safety reserve
  -h, --help               Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      PROFILE="$2"
      shift 2
      ;;
    -v|--vm)
      TARGET_VM_FILTER="$2"
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
    --skip-disk-check)
      SKIP_DISK_CHECK=true
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
[[ -n "${TARGET_VM_FILTER}" ]] && echo " VM Filter        : ${TARGET_VM_FILTER}"
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

vm_matches_filter() {
  local vm="$1"
  if [[ -z "${TARGET_VM_FILTER}" ]]; then
    return 0
  fi
  [[ ",${TARGET_VM_FILTER}," == *",${vm},"* ]]
}

EXISTING_VMS="$(multipass list --format csv | tail -n +2 | cut -d',' -f1 || true)"

TOTAL_REQ_CPUS=0
TOTAL_REQ_MEM_MB=0
VM_COUNT=0
NEW_VM_COUNT=0

while IFS='|' read -r vm_name vm_cpus vm_mem vm_disk vm_groups; do
  [[ -z "${vm_name}" || "${vm_name}" =~ ^# ]] && continue
  if ! vm_matches_filter "${vm_name}"; then
    continue
  fi
  TOTAL_REQ_CPUS=$(( TOTAL_REQ_CPUS + vm_cpus ))
  MEM_MB=$(convert_to_mb "${vm_mem}")
  TOTAL_REQ_MEM_MB=$(( TOTAL_REQ_MEM_MB + MEM_MB ))
  VM_COUNT=$(( VM_COUNT + 1 ))
  if ! echo "${EXISTING_VMS}" | grep -qx "${vm_name}"; then
    NEW_VM_COUNT=$(( NEW_VM_COUNT + 1 ))
  fi
done < "${PROFILE_FILE}"

# 3. Check Workstation Resources (CPU, RAM, and Disk)
if [[ "$(uname -s)" == "Darwin" ]]; then
  HOST_CPUS=$(sysctl -n hw.ncpu)
  HOST_MEM_BYTES=$(sysctl -n hw.memsize)
  HOST_MEM_MB=$(( HOST_MEM_BYTES / 1024 / 1024 ))
else
  HOST_CPUS=$(nproc)
  HOST_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  HOST_MEM_MB=$(( HOST_MEM_KB / 1024 ))
fi

HOST_FREE_DISK_KB=$(df -Pk / | tail -1 | awk '{print $4}')
HOST_FREE_DISK_GB=$(( HOST_FREE_DISK_KB / 1024 / 1024 ))
# Each fresh Ubuntu 24.04 cloud image instance consumes ~2.5 GB initially + 5 GB safety reserve for host OS
MIN_SAFE_DISK_GB=$(( NEW_VM_COUNT * 2 + 5 ))

SAFE_MEM_THRESHOLD_MB=$(( HOST_MEM_MB * 80 / 100 ))

echo "[INFO] Workstation Resource Assessment:"
echo "  Host Physical CPUs      : ${HOST_CPUS} cores"
echo "  Host Physical Memory    : ${HOST_MEM_MB} MB ($(( HOST_MEM_MB / 1024 )) GB)"
echo "  Safe VM Memory Ceiling  : ${SAFE_MEM_THRESHOLD_MB} MB (80% of host RAM)"
echo "  Host Free Disk Space (/): ${HOST_FREE_DISK_GB} GB (min recommended for ${NEW_VM_COUNT} new VMs: ${MIN_SAFE_DISK_GB} GB)"
echo "  Target VM Count         : ${VM_COUNT} VMs (${NEW_VM_COUNT} new to create)"
echo "  Target Total vCPUs      : ${TOTAL_REQ_CPUS} vCPUs (shared across hypervisor)"
echo "  Target Total Memory     : ${TOTAL_REQ_MEM_MB} MB (~$(( (TOTAL_REQ_MEM_MB + 512) / 1024 )) GB)"

if (( TOTAL_REQ_MEM_MB > SAFE_MEM_THRESHOLD_MB )) && [[ "${ALLOW_OVERCOMMIT}" == "false" ]]; then
  echo ""
  echo "[ERROR] Selected VMs require ${TOTAL_REQ_MEM_MB} MB RAM, which exceeds the safe ceiling"
  echo "        of ${SAFE_MEM_THRESHOLD_MB} MB on this ${HOST_MEM_MB} MB workstation."
  echo "        Recommendation: Run with '--profile compact' (16.5 GB total) or pass '--allow-overcommit'."
  exit 1
fi

if (( NEW_VM_COUNT > 0 && HOST_FREE_DISK_GB < MIN_SAFE_DISK_GB )) && [[ "${SKIP_DISK_CHECK}" == "false" ]] && [[ "${DRY_RUN}" == "false" ]]; then
  echo ""
  echo "[ERROR] Host root filesystem (/) only has ${HOST_FREE_DISK_GB} GB free space."
  echo "        Launching ${NEW_VM_COUNT} new Ubuntu 24.04 VMs requires at least ~${MIN_SAFE_DISK_GB} GB free to avoid filling your disk."
  echo "        Options:"
  echo "          1. Free up disk space on macOS or purge unused Multipass VMs/snapshots."
  echo "          2. Provision a single VM first: ./multipass/create-vms.sh --vm k8s-cp01"
  echo "          3. Override this safety check with: --skip-disk-check"
  exit 1
fi

# 4. Handle optional --recreate
if [[ "${RECREATE}" == "true" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Would invoke destroy-vms.sh --profile ${PROFILE}"
  else
    "${SCRIPT_DIR}/destroy-vms.sh" --profile "${PROFILE}"
    EXISTING_VMS="$(multipass list --format csv | tail -n +2 | cut -d',' -f1 || true)"
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
package_update: false
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

# 6. Launch or start VMs in profile
echo ""
echo "[INFO] Provisioning VMs for profile '${PROFILE}'..."

while IFS='|' read -r vm_name vm_cpus vm_mem vm_disk vm_groups; do
  [[ -z "${vm_name}" || "${vm_name}" =~ ^# ]] && continue
  if ! vm_matches_filter "${vm_name}"; then
    continue
  fi

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

# 7. Generate Ansible Inventory from live Multipass IPs
echo ""
if [[ -n "${TARGET_VM_FILTER}" ]]; then
  "${SCRIPT_DIR}/generate-inventory.sh" --profile "${PROFILE}" --running-only
else
  "${SCRIPT_DIR}/generate-inventory.sh" --profile "${PROFILE}"
fi

# 8. Display environment status
echo ""
"${SCRIPT_DIR}/status.sh" --profile "${PROFILE}"
