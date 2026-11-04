#!/usr/bin/env bash
# ==============================================================================
# Jenkins LTS 2.479.3 + Buildah/Podman/Skopeo + Trivy CLI Installer
# Usage: sudo NEXUS_IP="192.168.252.12" ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

JENKINS_VER="${JENKINS_VER:-2.479.3}"
TRIVY_VER="${TRIVY_VER:-0.58.1}"
KUBECTL_VER="${KUBECTL_VER:-v1.31.4}"
HELM_VER="${HELM_VER:-v3.16.4}"
NEXUS_IP="${NEXUS_IP:-192.168.252.12}"
ARCH_DEB="$(dpkg --print-architecture)"
TRIVY_ARCH="$([ "$ARCH_DEB" = "arm64" ] && echo "ARM64" || echo "64bit")"

echo "[1/4] Installing OpenJDK 17 and Jenkins LTS ${JENKINS_VER}..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y fontconfig openjdk-17-jre

mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | tee /etc/apt/keyrings/jenkins-keyring.asc >/dev/null

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
curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}/trivy_${TRIVY_VER}_Linux-${TRIVY_ARCH}.tar.gz" \
  -o /tmp/trivy.tar.gz
tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
chmod 0755 /usr/local/bin/trivy

curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${ARCH_DEB}/kubectl" -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

curl -fsSL "https://get.helm.sh/helm-${HELM_VER}-linux-${ARCH_DEB}.tar.gz" -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
mv "/tmp/linux-${ARCH_DEB}/helm" /usr/local/bin/helm
chmod 0755 /usr/local/bin/helm

echo "[4/4] Configuring systemd override, UFW ports, and starting Jenkins..."
mkdir -p /etc/systemd/system/jenkins.service.d
cat >/etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Xms512m -Xmx1024m"
Environment="JENKINS_PORT=8080"
EOF

ufw allow 8080/tcp comment 'Jenkins Web UI'
ufw allow 50000/tcp comment 'Jenkins Inbound JNLP Agents'

systemctl daemon-reload
systemctl enable --now jenkins

buildah --version
trivy --version
kubectl version --client
helm version --short
echo "Jenkins LTS and CI CLI tools installation complete."

