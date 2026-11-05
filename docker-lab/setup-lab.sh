#!/usr/bin/env bash
# ==============================================================================
# docker-lab/setup-lab.sh
# 3-Layer On-Premises DevOps Platform - Docker Lab Provisioner
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROFILE="core"
WITH_K8S=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: ./setup-lab.sh [OPTIONS]

Options:
  -p, --profile <name>   Compose profile to run:
                           core       - GitLab, Jenkins, Nexus, Garage (S3), PostgreSQL, Redis (Default, ~6-8GB RAM)
                           quality    - core + SonarQube (~8-10GB RAM)
                           monitoring - core + Prometheus, Grafana, Loki (~8-10GB RAM)
                           all        - Full Layer 1 stack (~10-12GB RAM)
  -k, --with-k8s         Provision KinD Kubernetes clusters for Layer 2 (Mgmt) & Layer 3 (App)
  -d, --dry-run          Validate configuration and prerequisite checks without starting services
  -h, --help             Show this help message

Examples:
  ./setup-lab.sh --profile core
  ./setup-lab.sh --profile all --with-k8s
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      PROFILE="$2"
      shift 2
      ;;
    -k|--with-k8s)
      WITH_K8S=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

echo "======================================================================"
echo "    3-Layer On-Premises DevOps Platform - Docker Lab Setup"
echo "======================================================================"
echo " Selected Profile : ${PROFILE}"
echo " With Kubernetes  : ${WITH_K8S}"
echo " Dry Run Mode     : ${DRY_RUN}"
echo "======================================================================"

# 1. Prerequisite Checks
echo "[+] Checking host prerequisites..."

if ! command -v docker &> /dev/null; then
  echo "[-] ERROR: Docker is not installed or not in PATH."
  exit 1
fi

if ! docker info &> /dev/null; then
  echo "[-] ERROR: Docker daemon is not running. Please start Docker Desktop/daemon."
  exit 1
fi

if ! docker compose version &> /dev/null; then
  echo "[-] ERROR: Docker Compose (v2) plugin is required."
  exit 1
fi

if [[ "${WITH_K8S}" == "true" ]]; then
  if ! command -v kind &> /dev/null; then
    echo "[-] ERROR: KinD (Kubernetes-in-Docker) is not installed."
    echo "    Install with: brew install kind (macOS) or see https://kind.sigs.k8s.io"
    exit 1
  fi
  if ! command -v kubectl &> /dev/null; then
    echo "[-] ERROR: kubectl is not installed."
    echo "    Install with: brew install kubectl (macOS)"
    exit 1
  fi
fi

# 2. Validate Compose File
echo "[+] Validating Docker Compose configuration..."
docker compose --profile "${PROFILE}" config > /dev/null
echo "[✓] Docker Compose syntax is valid."

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[✓] Dry-run check completed successfully. Exiting."
  exit 0
fi

# 3. Create Shared Bridge Network
echo "[+] Ensuring shared Docker bridge network 'devops-net' exists..."
if ! docker network inspect devops-net &> /dev/null; then
  docker network create devops-net
  echo "[✓] Created network: devops-net"
else
  echo "[✓] Network 'devops-net' already exists."
fi

# 4. Start Layer 1 DevOps Infrastructure
echo "[+] Starting Layer 1 DevOps services (Profile: ${PROFILE})..."
docker compose --profile "${PROFILE}" up -d

# 5. Initialize Garage Object Storage if running in profile
if [[ "${PROFILE}" == "core" || "${PROFILE}" == "all" ]]; then
  if docker ps --filter "name=devops-garage" --format "{{.Names}}" | grep -q "devops-garage"; then
    "${SCRIPT_DIR}/scripts/init-garage.sh" "devops-garage" || true
  fi
fi

# 6. Provision Kubernetes Clusters via KinD if requested
if [[ "${WITH_K8S}" == "true" ]]; then
  echo "----------------------------------------------------------------------"
  echo "[+] Layer 2: Provisioning Management Kubernetes Cluster (onprem-mgmt-k8s)..."
  if kind get clusters | grep -q "onprem-mgmt-k8s"; then
    echo "[✓] KinD cluster 'onprem-mgmt-k8s' is already running."
  else
    kind create cluster --config=kind-mgmt-cluster.yaml
    echo "[✓] Layer 2 Management cluster created."
  fi

  echo "[+] Layer 3: Provisioning Application Kubernetes Cluster (onprem-app-k8s)..."
  if kind get clusters | grep -q "onprem-app-k8s"; then
    echo "[✓] KinD cluster 'onprem-app-k8s' is already running."
  else
    kind create cluster --config=kind-app-cluster.yaml
    echo "[✓] Layer 3 Application cluster created."
  fi

  # Connect KinD node containers to devops-net for seamless cross-layer DNS
  echo "[+] Attaching KinD cluster nodes to 'devops-net' bridge network..."
  for node in $(docker ps --filter "name=onprem-" --format "{{.Names}}"); do
    docker network connect devops-net "${node}" 2>/dev/null || true
  done
  echo "[✓] Cross-layer network interconnectivity established."
fi

# 7. Display Endpoint Summary
echo "======================================================================"
echo "    Docker Lab Deployment Completed Successfully!"
echo "======================================================================"
cat <<EOF

Layer 1: External DevOps Infrastructure Endpoints:
  • GitLab CE        : http://localhost:8082
                       Username: root | Password: ChangeMeGitlab123!
  • Jenkins LTS      : http://localhost:8080
                       (Retrieve initial key with: docker exec devops-jenkins cat /var/jenkins_home/secrets/initialAdminPassword)
  • Nexus OSS        : http://localhost:8085
                       Docker Hosted: localhost:5002 | Group: localhost:5003
                       (Initial pass: docker exec devops-nexus cat /nexus-data/admin.password)
  • Garage S3 API    : http://localhost:3900 (Internal DNS: http://garage:3900)
                       S3 Web: http://localhost:3902 | Admin API: http://localhost:3903
                       Admin Token: ChangeMeAdminToken1234567890
                       Default Bucket: devops-artifacts (Key: devops-key)
  • PostgreSQL 16    : localhost:5435 (User: postgres, Pass: ChangeMePostgres123!)
  • Redis 7.4        : localhost:6381

EOF

if [[ "${PROFILE}" == "quality" || "${PROFILE}" == "all" ]]; then
cat <<EOF
Layer 1C: Quality:
  • SonarQube        : http://localhost:9002 (Default: admin/admin)
EOF
fi

if [[ "${PROFILE}" == "monitoring" || "${PROFILE}" == "all" ]]; then
cat <<EOF
Layer 1D: Observability:
  • Prometheus       : http://localhost:9090
  • Grafana          : http://localhost:3000 (User: admin, Pass: ChangeMeGrafana123!)
  • Loki Logs API    : http://localhost:3100
EOF
fi

if [[ "${WITH_K8S}" == "true" ]]; then
cat <<EOF
Layer 2 & Layer 3 Kubernetes Clusters (KinD):
  • Management K8s   : kubectl config use-context kind-onprem-mgmt-k8s
                       Argo CD Web UI NodePort: https://localhost:30443
  • Application K8s  : kubectl config use-context kind-onprem-app-k8s
                       App Ingress HTTP: http://localhost:8088
                       App Ingress HTTPS: https://localhost:8443
EOF
fi

echo "======================================================================"
echo "To stop or tear down the lab, run: ./destroy-lab.sh"
echo "======================================================================"
