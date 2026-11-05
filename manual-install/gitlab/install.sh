#!/usr/bin/env bash
# ==============================================================================
# GitLab CE 17.7.1-ce.0 + glab CLI Manual Installer (Ubuntu 24.04 LTS)
# Usage: sudo GITLAB_URL="http://192.168.252.10" ./install.sh
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
GITLAB_VER="${GITLAB_VER:-17.7.1-ce.0}"
GITLAB_URL="${GITLAB_URL:-http://${NODE_IP}}"
GITLAB_ROOT_PASS="${GITLAB_ROOT_PASS:-ChangeMe_GitLabRootPass_2026!}"
GLAB_VER="${GLAB_VER:-1.51.0}"
ARCH="$(dpkg --print-architecture)"
CLIENT_CIDR="${CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"

if [[ "${PLATFORM_ENV:-}" == "production" && "${GITLAB_ROOT_PASS}" == ChangeMe_* ]]; then
  echo "ERROR: set a real GITLAB_ROOT_PASS before a production install" >&2
  exit 1
fi

echo "[1/4] Installing dependencies and GitLab CE APT repository..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssh-server ca-certificates tzdata perl
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash

echo "[2/4] Installing gitlab-ce=${GITLAB_VER}..."
EXTERNAL_URL="${GITLAB_URL}" \
  GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASS}" \
  DEBIAN_FRONTEND=noninteractive \
  apt-get install -y "gitlab-ce=${GITLAB_VER}"
apt-mark hold gitlab-ce

echo "[3/4] Writing /etc/gitlab/gitlab.rb and reconfiguring..."
cat >/etc/gitlab/gitlab.rb <<EOF
external_url '${GITLAB_URL}'
gitlab_rails['time_zone'] = '${TIMEZONE:-UTC}'
gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASS}'
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10
prometheus_monitoring['enable'] = false
gitlab_exporter['enable'] = true
gitlab_rails['backup_keep_time'] = 604800
EOF
chmod 0600 /etc/gitlab/gitlab.rb
gitlab-ctl reconfigure

ufw allow from "${CLIENT_CIDR}" to any port 80 proto tcp comment 'GitLab HTTP'
ufw allow from "${CLIENT_CIDR}" to any port 443 proto tcp comment 'GitLab HTTPS'

echo "[4/4] Installing GitLab CLI (glab v${GLAB_VER})..."
GLAB_TMP="$(mktemp -d)"
trap 'rm -rf "${GLAB_TMP}"' EXIT
GLAB_BASE="https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VER}/downloads"
GLAB_DEB="glab_${GLAB_VER}_linux_${ARCH}.deb"
curl -fsSL "${GLAB_BASE}/${GLAB_DEB}" -o "${GLAB_TMP}/${GLAB_DEB}"
if curl -fsSL "${GLAB_BASE}/checksums.txt" -o "${GLAB_TMP}/checksums.txt" 2>/dev/null; then
  (cd "${GLAB_TMP}" && grep " ${GLAB_DEB}\$" checksums.txt | sha256sum -c -)
fi
dpkg -i "${GLAB_TMP}/${GLAB_DEB}"

gitlab-ctl status
glab --version
echo "GitLab CE and glab CLI installation complete."
