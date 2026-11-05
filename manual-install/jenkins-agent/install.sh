#!/usr/bin/env bash
# ==============================================================================
# Dedicated Jenkins Build Agent Installer (Rootless Buildah/Podman + Trivy CLI)
# Usage: sudo NEXUS_IP="10.20.20.14" ./install.sh
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

NEXUS_IP="${NEXUS_IP:-10.20.20.14}"
TRIVY_VER="${TRIVY_VER:-0.58.1}"
KUBECTL_VER="${KUBECTL_VER:-v1.31.4}"
HELM_VER="${HELM_VER:-v3.16.4}"
ARCH_DEB="$(dpkg --print-architecture)"
TRIVY_ARCH="$([ "$ARCH_DEB" = "arm64" ] && echo "ARM64" || echo "64bit")"

echo "[1/3] Installing OpenJDK 17 and rootless container build tools..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openjdk-17-jre-headless git curl jq \
  buildah podman skopeo uidmap slirp4netns fuse-overlayfs

groupadd --system jenkins-agent 2>/dev/null || true
useradd --system --home-dir /var/lib/jenkins-agent --create-home --shell /bin/bash -g jenkins-agent jenkins-agent 2>/dev/null || true

grep -q "^jenkins-agent:" /etc/subuid || echo "jenkins-agent:165536:65536" >> /etc/subuid
grep -q "^jenkins-agent:" /etc/subgid || echo "jenkins-agent:165536:65536" >> /etc/subgid

mkdir -p /etc/containers/registries.conf.d
cat >/etc/containers/registries.conf.d/99-nexus.conf <<EOF
[[registry]]
location = "${NEXUS_IP}:5000"
insecure = true

[[registry]]
location = "${NEXUS_IP}:5001"
insecure = true
EOF

echo "[2/3] Installing Trivy ${TRIVY_VER}, kubectl ${KUBECTL_VER}, and Helm ${HELM_VER}..."
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

echo "[3/3] Verifying Jenkins Agent tools..."
buildah --version
trivy --version
kubectl version --client
helm version --short
echo "Jenkins Build Agent installation complete."
