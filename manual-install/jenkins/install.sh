#!/usr/bin/env bash
# ==============================================================================
# Jenkins LTS 2.479.3 + Buildah/Podman/Skopeo + Trivy CLI Installer
# Usage: sudo NEXUS_IP="192.168.252.12" ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  # shellcheck disable=SC1090
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./install.sh)" >&2
  exit 1
fi

NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
CLIENT_CIDR="${CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"
JENKINS_VER="${JENKINS_VER:-2.479.3}"
TRIVY_VER="${TRIVY_VER:-0.58.1}"
KUBECTL_VER="${KUBECTL_VER:-v1.31.4}"
HELM_VER="${HELM_VER:-v3.16.4}"
NEXUS_IP="${NEXUS_IP:-192.168.252.12}"
JENKINS_SKIP_WIZARD="${JENKINS_SKIP_WIZARD:-$([[ "${PLATFORM_ENV:-}" == "production" ]] && echo false || echo true)}"
ARCH_DEB="$(dpkg --print-architecture)"
TRIVY_ARCH="$([ "$ARCH_DEB" = "arm64" ] && echo "ARM64" || echo "64bit")"

echo "[1/4] Installing OpenJDK 17 and Jenkins LTS ${JENKINS_VER}..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y fontconfig openjdk-17-jre curl

mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | tee /etc/apt/keyrings/jenkins-keyring.asc >/dev/null
chmod 0644 /etc/apt/keyrings/jenkins-keyring.asc

cat >/etc/apt/sources.list.d/jenkins.sources <<'EOF'
Types: deb
URIs: https://pkg.jenkins.io/debian-stable
Suites: binary/
Signed-By: /etc/apt/keyrings/jenkins-keyring.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "jenkins=${JENKINS_VER}"
apt-mark hold jenkins

echo "[2/4] Installing rootless Buildah, Podman, and Skopeo..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  buildah podman skopeo uidmap slirp4netns fuse-overlayfs

grep -q "^jenkins:" /etc/subuid || echo "jenkins:100000:65536" >> /etc/subuid
grep -q "^jenkins:" /etc/subgid || echo "jenkins:100000:65536" >> /etc/subgid

mkdir -p /etc/containers/registries.conf.d
cat >/etc/containers/registries.conf.d/99-nexus.conf <<EOF
[[registry]]
location = "${NEXUS_IP}:5000"
insecure = true

[[registry]]
location = "${NEXUS_IP}:5001"
insecure = true
EOF

echo "[3/4] Installing Trivy ${TRIVY_VER}, kubectl ${KUBECTL_VER}, and Helm ${HELM_VER}..."
CI_TMP="$(mktemp -d)"
trap 'rm -rf "${CI_TMP}"' EXIT

TRIVY_BASE="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}"
TRIVY_TAR="trivy_${TRIVY_VER}_Linux-${TRIVY_ARCH}.tar.gz"
curl -fsSL "${TRIVY_BASE}/${TRIVY_TAR}" -o "${CI_TMP}/${TRIVY_TAR}"
if curl -fsSL "${TRIVY_BASE}/trivy_${TRIVY_VER}_checksums.txt" -o "${CI_TMP}/trivy.sha256" 2>/dev/null; then
  (cd "${CI_TMP}" && grep " ${TRIVY_TAR}\$" trivy.sha256 | sha256sum -c -)
fi
tar -xzf "${CI_TMP}/${TRIVY_TAR}" -C /usr/local/bin trivy
chmod 0755 /usr/local/bin/trivy

curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${ARCH_DEB}/kubectl" -o "${CI_TMP}/kubectl"
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${ARCH_DEB}/kubectl.sha256" -o "${CI_TMP}/kubectl.sha256"
echo "$(cat "${CI_TMP}/kubectl.sha256")  ${CI_TMP}/kubectl" | sha256sum -c -
install -m 0755 "${CI_TMP}/kubectl" /usr/local/bin/kubectl

HELM_TAR="helm-${HELM_VER}-linux-${ARCH_DEB}.tar.gz"
curl -fsSL "https://get.helm.sh/${HELM_TAR}" -o "${CI_TMP}/${HELM_TAR}"
if curl -fsSL "https://get.helm.sh/${HELM_TAR}.sha256sum" -o "${CI_TMP}/helm.sha256" 2>/dev/null; then
  (cd "${CI_TMP}" && sha256sum -c helm.sha256)
fi
tar -xzf "${CI_TMP}/${HELM_TAR}" -C "${CI_TMP}"
install -m 0755 "${CI_TMP}/linux-${ARCH_DEB}/helm" /usr/local/bin/helm

echo "[4/4] Configuring systemd override, UFW ports, and starting Jenkins..."
WIZARD_FLAG="-Djenkins.install.runSetupWizard=true"
if [[ "${JENKINS_SKIP_WIZARD}" == "true" ]]; then
  echo "WARN: JENKINS_SKIP_WIZARD=true disables initial Jenkins auth wizard (lab mode only)" >&2
  WIZARD_FLAG="-Djenkins.install.runSetupWizard=false"
fi

mkdir -p /etc/systemd/system/jenkins.service.d
cat >/etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true ${WIZARD_FLAG} -Xms512m -Xmx1024m"
Environment="JENKINS_PORT=8080"
EOF

ufw allow from "${CLIENT_CIDR}" to any port 8080 proto tcp comment 'Jenkins Web UI'
for agent_ip in "${JENKINS_AGENT01_IP:-}" "${JENKINS_AGENT02_IP:-}"; do
  [[ -n "${agent_ip}" ]] && ufw allow from "${agent_ip}" to any port 50000 proto tcp comment 'Jenkins JNLP Agent'
done

systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins

ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/login || true)"
  if [[ "${code}" =~ ^(200|403)$ ]]; then ok=1; break; fi
  sleep 2
done
[[ ${ok} -eq 1 ]] || { echo "ERROR: Jenkins did not become ready on :8080" >&2; exit 1; }

buildah --version
trivy --version
kubectl version --client
helm version --short
echo "Jenkins LTS and CI CLI tools installation complete."
