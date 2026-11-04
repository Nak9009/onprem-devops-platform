#!/usr/bin/env bash
# ==============================================================================
# GitLab CE 17.7.1-ce.0 + glab CLI Manual Installer (Ubuntu 24.04 LTS)
# Usage: sudo GITLAB_URL="http://192.168.252.10" ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

GITLAB_VER="${GITLAB_VER:-17.7.1-ce.0}"
GITLAB_URL="${GITLAB_URL:-http://$(hostname -I | awk '{print $1}')}"
GITLAB_ROOT_PASS="${GITLAB_ROOT_PASS:-ChangeMe_GitLabRootPass_2026!}"
GLAB_VER="${GLAB_VER:-1.51.0}"
ARCH="$(dpkg --print-architecture)"

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
gitlab_rails['time_zone'] = 'UTC'
gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASS}'
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10
prometheus_monitoring['enable'] = false
gitlab_exporter['enable'] = true
gitlab_rails['backup_keep_time'] = 604800
EOF
chmod 0600 /etc/gitlab/gitlab.rb
gitlab-ctl reconfigure

ufw allow 80/tcp comment 'GitLab HTTP'
ufw allow 443/tcp comment 'GitLab HTTPS'

echo "[4/4] Installing GitLab CLI (glab v${GLAB_VER})..."
curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VER}/downloads/glab_${GLAB_VER}_linux_${ARCH}.deb" \
  -o /tmp/glab.deb
dpkg -i /tmp/glab.deb

gitlab-ctl status
glab --version
echo "GitLab CE and glab CLI installation complete."

