#!/usr/bin/env bash
# ==============================================================================
# Dedicated Jenkins Build Agent Installer (Rootless Buildah/Podman + Trivy CLI)
# Usage: sudo NEXUS_IP="10.20.20.14" ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

NEXUS_IP="${NEXUS_IP:-10.20.20.14}"
TRIVY_VER="${TRIVY_VER:-0.58.1}"
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
EOF

echo "[2/3] Installing Trivy ${TRIVY_VER}, kubectl, and helm..."
curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}/trivy_${TRIVY_VER}_Linux-${TRIVY_ARCH}.tar.gz" -o /tmp/trivy.tar.gz
tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
chmod 0755 /usr/local/bin/trivy

curl -fsSL "https://dl.k8s.io/release/v1.31.4/bin/linux/${ARCH_DEB}/kubectl" -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

echo "[3/3] Verifying Jenkins Agent tools..."
buildah --version
trivy --version
kubectl version --client
echo "Jenkins Build Agent installation complete."

