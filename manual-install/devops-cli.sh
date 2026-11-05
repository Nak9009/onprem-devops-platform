#!/usr/bin/env bash
# ==============================================================================
# manual-install/devops-cli.sh
# Unified Global CLI for Manual Server Installation, Remote Execution,
# Client CLI Provisioning, and Live 3-Layer Platform Health Verification.
# ==============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ENV="production"

if [[ "${1:-}" == "-e" || "${1:-}" == "--env" ]]; then
  TARGET_ENV="${2:-production}"
  shift 2
fi

if [[ -n "${PLATFORM_ENV_FILE:-}" ]]; then
  ENV_FILE="${PLATFORM_ENV_FILE}"
elif [[ -f "${BASE_DIR}/${TARGET_ENV}.env" ]]; then
  ENV_FILE="${BASE_DIR}/${TARGET_ENV}.env"
else
  ENV_FILE="${BASE_DIR}/platform.env"
fi
export PLATFORM_ENV_FILE="${ENV_FILE}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

MODULES=(
  "common"
  "gitlab"
  "jenkins"
  "jenkins-agent"
  "nexus"
  "postgresql-ha"
  "redis"
  "minio"
  "monitoring"
  "logging"
  "vault"
  "rancher"
  "kubernetes-mgmt"
  "kubernetes-cp"
  "kubernetes-worker"
)

usage() {
  cat <<'EOF'
Usage: ./manual-install/devops-cli.sh <command> [arguments]

Commands:
  env                              Display active global variables from platform.env
  list                             List all 15 server install modules and target IPs
  install <module>                 Run <module>/install.sh locally on this server
  multipass-install <module> <vm>  Copy platform.env + <module> into a Multipass VM and execute via 'multipass exec'
  remote-install <module> <host>   Copy platform.env + <module>/install.sh to <user@host> (or Multipass VM) and execute
  install-clis                     Install all operator client CLIs (kubectl, helm, argocd, rancher, glab, garage, logcli, trivy, vault, psql, redis-cli)
  status                           Check live TCP/HTTP health across Layer 1, Layer 2, and Layer 3 endpoints
EOF
}

check_http() {
  local name="$1"
  local url="$2"
  local vm_hint="${3:-}"
  if [[ "${TARGET_ENV}" == "local" && -n "${vm_hint}" ]] && command -v multipass >/dev/null 2>&1; then
    if ! multipass list --format csv 2>/dev/null | grep -q "^${vm_hint},Running,"; then
      printf "  [SKIP] %-28s %-42s (VM '%s' not running)\n" "${name}" "${url}" "${vm_hint}"
      return 0
    fi
  fi
  local code
  code="$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 3 "${url}" || true)"
  if [[ "${code}" =~ ^(200|204|301|302|401|403)$ ]]; then
    printf "  [OK]   %-28s %-42s (HTTP %s)\n" "${name}" "${url}" "${code}"
  elif [[ "${name}" == *"Vault"* && "${code}" =~ ^(429|501|503)$ ]]; then
    printf "  [OK]   %-28s %-42s (HTTP %s - Vault Running)\n" "${name}" "${url}" "${code}"
  else
    printf "  [DOWN] %-28s %-42s (HTTP %s)\n" "${name}" "${url}" "${code}"
  fi
}

check_tcp() {
  local name="$1"
  local host="$2"
  local port="$3"
  local vm_hint="${4:-}"
  if [[ "${TARGET_ENV}" == "local" && -n "${vm_hint}" ]] && command -v multipass >/dev/null 2>&1; then
    if ! multipass list --format csv 2>/dev/null | grep -q "^${vm_hint},Running,"; then
      printf "  [SKIP] %-28s %s:%s (VM '%s' not running)\n" "${name}" "${host}" "${port}" "${vm_hint}"
      return 0
    fi
  fi
  if nc -z -w 2 "${host}" "${port}" >/dev/null 2>&1; then
    printf "  [OK]   %-28s %s:%s (TCP OPEN)\n" "${name}" "${host}" "${port}"
  else
    printf "  [DOWN] %-28s %s:%s (TCP CLOSED)\n" "${name}" "${host}" "${port}"
  fi
}

cmd_list() {
  printf "%-20s %-10s %-22s %s\n" "MODULE" "LAYER" "DEFAULT TARGET IP" "INSTALLER PATH"
  printf "%-20s %-10s %-22s %s\n" "------" "-----" "-----------------" "--------------"
  printf "%-20s %-10s %-22s %s\n" "common"            "All"     "All Nodes"             "manual-install/common/install.sh"
  printf "%-20s %-10s %-22s %s\n" "gitlab"            "Layer 1" "${GITLAB_IP}"          "manual-install/gitlab/install.sh"
  printf "%-20s %-10s %-22s %s\n" "jenkins"           "Layer 1" "${JENKINS_IP}"         "manual-install/jenkins/install.sh"
  printf "%-20s %-10s %-22s %s\n" "jenkins-agent"     "Layer 1" "${JENKINS_AGENT01_IP}" "manual-install/jenkins-agent/install.sh"
  printf "%-20s %-10s %-22s %s\n" "nexus"             "Layer 1" "${NEXUS_IP}"           "manual-install/nexus/install.sh"
  printf "%-20s %-10s %-22s %s\n" "postgresql-ha"     "Layer 1" "${PG_VIP} (5 VMs)"     "manual-install/postgresql-ha/install.sh"
  printf "%-20s %-10s %-22s %s\n" "redis"             "Layer 1" "${REDIS_IP}"           "manual-install/redis/install.sh"
  printf "%-20s %-10s %-22s %s\n" "minio"             "Layer 1" "${MINIO_VIP}"          "manual-install/minio/install.sh"
  printf "%-20s %-10s %-22s %s\n" "monitoring"        "Layer 1" "${MONITOR_IP}"         "manual-install/monitoring/install.sh"
  printf "%-20s %-10s %-22s %s\n" "logging"           "Layer 1" "${MONITOR_IP}"         "manual-install/logging/install.sh"
  printf "%-20s %-10s %-22s %s\n" "vault"             "Layer 1" "${VAULT_IP}"           "manual-install/vault/install.sh"
  printf "%-20s %-10s %-22s %s\n" "rancher"           "Layer 2" "${K8S_MGMT_CP01_IP}"   "manual-install/rancher/install.sh"
  printf "%-20s %-10s %-22s %s\n" "kubernetes-mgmt"   "Layer 2" "${K8S_MGMT_VIP}"       "manual-install/kubernetes-mgmt/install.sh"
  printf "%-20s %-10s %-22s %s\n" "kubernetes-cp"     "Layer 3" "${K8S_APP_VIP}"        "manual-install/kubernetes-cp/install.sh"
  printf "%-20s %-10s %-22s %s\n" "kubernetes-worker" "Layer 3" "${K8S_APP_WORKER01_IP}" "manual-install/kubernetes-worker/install.sh"
}

cmd_install() {
  local mod="${1:-}"
  if [[ -z "${mod}" || ! -f "${BASE_DIR}/${mod}/install.sh" ]]; then
    echo "[ERROR] Unknown module '${mod}'. Run './manual-install/devops-cli.sh list' to see valid modules." >&2
    exit 1
  fi
  echo "[INFO] Running local installer for '${mod}' with global env ${ENV_FILE}..."
  sudo -E bash "${BASE_DIR}/${mod}/install.sh"
}

write_resolved_env() {
  local out_file="$1"
  cat "${ENV_FILE}" > "${out_file}"
  cat >> "${out_file}" <<EOF

# --- Host-Resolved Live Environment Overrides ---
export PLATFORM_ENV="${PLATFORM_ENV:-${TARGET_ENV}}"
export GITLAB_IP="${GITLAB_IP}"
export JENKINS_IP="${JENKINS_IP}"
export JENKINS_AGENT01_IP="${JENKINS_AGENT01_IP}"
export NEXUS_IP="${NEXUS_IP}"
export MINIO_VIP="${MINIO_VIP}"
export PG_DB1_IP="${PG_DB1_IP}"
export PG_DB2_IP="${PG_DB2_IP:-}"
export PG_DB3_IP="${PG_DB3_IP:-}"
export PG_LB1_IP="${PG_LB1_IP}"
export PG_LB2_IP="${PG_LB2_IP:-}"
export PG_VIP="${PG_VIP}"
export PG_RO_VIP="${PG_RO_VIP}"
export REDIS_IP="${REDIS_IP}"
export MONITOR_IP="${MONITOR_IP}"
export LOKI_SERVER_IP="${LOKI_SERVER_IP}"
export BACKUP_IP="${BACKUP_IP}"
export VAULT_IP="${VAULT_IP}"
export K8S_MGMT_CP01_IP="${K8S_MGMT_CP01_IP}"
export K8S_MGMT_VIP="${K8S_MGMT_VIP}"
export K8S_APP_CP01_IP="${K8S_APP_CP01_IP}"
export K8S_APP_VIP="${K8S_APP_VIP}"
export K8S_APP_WORKER01_IP="${K8S_APP_WORKER01_IP}"
export GITLAB_URL="${GITLAB_URL}"
EOF
}

cmd_multipass_install() {
  local mod="${1:-}"
  local vm="${2:-}"
  if [[ -z "${mod}" || -z "${vm}" || ! -f "${BASE_DIR}/${mod}/install.sh" ]]; then
    echo "Usage: ./manual-install/devops-cli.sh --env local multipass-install <module> <vm-name>" >&2
    exit 1
  fi
  if ! command -v multipass >/dev/null 2>&1; then
    echo "[ERROR] 'multipass' CLI not found on PATH." >&2
    exit 1
  fi

  local tmp_env
  tmp_env="$(mktemp)"
  write_resolved_env "${tmp_env}"

  echo "[INFO] Deploying '${mod}' to Multipass VM '${vm}' via multipass transfer/exec (env: ${TARGET_ENV})..."
  multipass exec "${vm}" -- bash -c "rm -rf /tmp/manual-install/${mod} && mkdir -p /tmp/manual-install"
  multipass transfer "${tmp_env}" "${vm}:/tmp/manual-install/platform.env"
  rm -f "${tmp_env}"
  multipass transfer -r "${BASE_DIR}/${mod}" "${vm}:/tmp/manual-install/${mod}"
  if [[ "${mod}" == "kubernetes-mgmt" ]]; then
    multipass exec "${vm}" -- bash -c "rm -rf /tmp/manual-install/kubernetes-cp"
    multipass transfer -r "${BASE_DIR}/kubernetes-cp" "${vm}:/tmp/manual-install/kubernetes-cp"
  fi
  multipass exec "${vm}" -- sudo PLATFORM_ENV_FILE=/tmp/manual-install/platform.env bash "/tmp/manual-install/${mod}/install.sh"
}

cmd_remote_install() {
  local mod="${1:-}"
  local target="${2:-}"
  if [[ -z "${mod}" || -z "${target}" || ! -f "${BASE_DIR}/${mod}/install.sh" ]]; then
    echo "Usage: ./manual-install/devops-cli.sh [--env local|production] remote-install <module> <vm-name|user@host>" >&2
    exit 1
  fi

  # If target is a running Multipass VM name (without '@'), use native multipass transfer/exec
  if [[ "${target}" != *"@"* ]] && command -v multipass >/dev/null 2>&1; then
    if multipass list --format csv 2>/dev/null | grep -q "^${target},Running,"; then
      cmd_multipass_install "${mod}" "${target}"
      return 0
    fi
  fi

  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  local mp_key="${BASE_DIR}/../multipass/.ssh/id_ed25519"
  if [[ "${TARGET_ENV}" == "local" && -f "${mp_key}" ]]; then
    ssh_opts+=(-i "${mp_key}")
  fi

  local tmp_env
  tmp_env="$(mktemp)"
  write_resolved_env "${tmp_env}"

  echo "[INFO] Deploying '${mod}' to remote host ${target} (env: ${TARGET_ENV})..."
  ssh "${ssh_opts[@]}" "${target}" "mkdir -p /tmp/manual-install/${mod}"
  scp -q "${ssh_opts[@]}" "${tmp_env}" "${target}:/tmp/manual-install/platform.env"
  rm -f "${tmp_env}"
  scp -q "${ssh_opts[@]}" -r "${BASE_DIR}/${mod}/"* "${target}:/tmp/manual-install/${mod}/"
  if [[ "${mod}" == "kubernetes-mgmt" ]]; then
    ssh "${ssh_opts[@]}" "${target}" "mkdir -p /tmp/manual-install/kubernetes-cp"
    scp -q "${ssh_opts[@]}" -r "${BASE_DIR}/kubernetes-cp/"* "${target}:/tmp/manual-install/kubernetes-cp/"
  fi
  ssh -t "${ssh_opts[@]}" "${target}" "sudo PLATFORM_ENV_FILE=/tmp/manual-install/platform.env bash /tmp/manual-install/${mod}/install.sh"
}

cmd_install_clis() {
  local arch
  arch="$(dpkg --print-architecture)"
  local trivy_arch
  trivy_arch="$([ "$arch" = "arm64" ] && echo "ARM64" || echo "64bit")"

  echo "[INFO] Installing all operator client CLIs on $(hostname -s) (${arch})..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget jq unzip git postgresql-client redis-tools

  # kubectl
  sudo curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${arch}/kubectl" -o /usr/local/bin/kubectl
  # helm
  curl -fsSL "https://get.helm.sh/helm-${HELM_VER}-linux-${arch}.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp && sudo mv "/tmp/linux-${arch}/helm" /usr/local/bin/helm
  # argocd
  sudo curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VER}/argocd-linux-${arch}" -o /usr/local/bin/argocd
  # calicoctl
  sudo curl -fsSL "https://github.com/projectcalico/calico/releases/download/${CALICO_VER}/calicoctl-linux-${arch}" -o /usr/local/bin/calicoctl
  # rancher CLI
  curl -fsSL "https://github.com/rancher/cli/releases/download/${RANCHER_CLI_VER}/rancher-linux-${arch}-${RANCHER_CLI_VER}.tar.gz" -o /tmp/rancher.tar.gz
  tar -xzf /tmp/rancher.tar.gz -C /tmp && sudo mv "/tmp/rancher-${RANCHER_CLI_VER}/rancher" /usr/local/bin/rancher
  # garage CLI (replaces discontinued MinIO mc binary)
  local g_triple="x86_64-unknown-linux-musl"
  [[ "${arch}" == "arm64" ]] && g_triple="aarch64-unknown-linux-musl"
  sudo curl -fsSL "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VER:-v2.5.0}/${g_triple}/garage" -o /usr/local/bin/garage
  # logcli (Loki CLI)
  curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VER}/logcli-linux-${arch}.zip" -o /tmp/logcli.zip
  sudo unzip -o /tmp/logcli.zip -d /tmp && sudo mv "/tmp/logcli-linux-${arch}" /usr/local/bin/logcli
  # trivy CLI
  curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}/trivy_${TRIVY_VER}_Linux-${trivy_arch}.tar.gz" -o /tmp/trivy.tar.gz
  sudo tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
  # vault CLI
  curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_${arch}.zip" -o /tmp/vault.zip
  sudo unzip -o /tmp/vault.zip -d /usr/local/bin
  # glab CLI
  curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VER}/downloads/glab_${GLAB_VER}_linux_${arch}.deb" -o /tmp/glab.deb
  sudo dpkg -i /tmp/glab.deb

  sudo chmod 0755 /usr/local/bin/kubectl /usr/local/bin/helm /usr/local/bin/argocd \
    /usr/local/bin/calicoctl /usr/local/bin/rancher /usr/local/bin/garage \
    /usr/local/bin/logcli /usr/local/bin/trivy /usr/local/bin/vault
  echo "[OK] All operator CLIs installed in /usr/local/bin."
}

cmd_status() {
  echo "=== Layer 1: DevOps, Databases, Storage & Observability ==="
  check_http "GitLab CE"          "http://${GITLAB_IP}/-/readiness"                 "devops-gitlab"
  check_http "Jenkins LTS"        "http://${JENKINS_IP}:8080/login"                 "devops-jenkins"
  check_http "Sonatype Nexus"     "http://${NEXUS_IP}:8081/service/rest/v1/status"  "devops-nexus"
  check_http "Garage S3 API"      "https://${MINIO_VIP}:${GARAGE_TLS_PORT:-9443}/health" "devops-nexus"
  check_tcp  "PostgreSQL RW VIP"  "${PG_VIP}" "5432"                                "pg-db1"
  check_tcp  "PostgreSQL RO VIP"  "${PG_VIP}" "5433"                                "pg-lb1"
  check_http "Patroni pg-db1"     "http://${PG_DB1_IP}:8008/health"                 "pg-db1"
  check_tcp  "Redis Server"       "${REDIS_IP}" "6379"                              "pg-db1"
  check_http "Prometheus"         "http://${MONITOR_IP}:9090/-/healthy"             "devops-monitor"
  check_http "Grafana"            "http://${MONITOR_IP}:3000/api/health"            "devops-monitor"
  check_http "Grafana Loki"       "http://${MONITOR_IP}:3100/ready"                 "devops-monitor"
  check_http "HashiCorp Vault"    "https://${VAULT_IP}:8200/v1/sys/health"           "devops-monitor"
  echo
  echo "=== Layer 2: Dedicated Kubernetes Management Cluster ==="
  check_tcp  "Mgmt K8s API"       "${K8S_MGMT_CP01_IP}" "6443"                      "k8s-mgmt-cp01"
  check_http "Rancher Server"     "https://${K8S_MGMT_CP01_IP}/ping"                "k8s-mgmt-cp01"
  check_http "Argo CD Server"     "https://${K8S_MGMT_CP01_IP}:30443/healthz"       "k8s-mgmt-cp01"
  echo
  echo "=== Layer 3: Application Kubernetes Cluster ==="
  check_tcp  "App K8s API"        "${K8S_APP_CP01_IP}" "6443"                       "k8s-cp01"
}

case "${1:-}" in
  env)
    cat "${ENV_FILE}"
    ;;
  list)
    cmd_list
    ;;
  install)
    shift
    cmd_install "$@"
    ;;
  multipass-install)
    shift
    cmd_multipass_install "$@"
    ;;
  remote-install)
    shift
    cmd_remote_install "$@"
    ;;
  install-clis)
    cmd_install_clis
    ;;
  status)
    cmd_status
    ;;
  *)
    usage
    ;;
esac

