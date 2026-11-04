# GitLab Server Manual Installation & CLI Guide (`gitlab`)

- **Target Host:** `devops-gitlab` (`192.168.252.10`) or `prod-gitlab-01` (`10.20.10.10`)
- **Version:** `gitlab-ce=17.7.1-ce.0` + GitLab CLI (`glab`)
- **Automated Script:** [`manual-install/gitlab/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/gitlab/install.sh)

---

## 1. Install GitLab CE (`17.7.1-ce.0`)

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssh-server ca-certificates tzdata perl

# Add official GitLab CE repository
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash

# Install pinned GitLab CE version
export GITLAB_URL="http://gitlab.internal.example.com"   # Or http://192.168.252.10 for local
export GITLAB_ROOT_PASS="ChangeMe_GitLabRootPass_2026!"

sudo EXTERNAL_URL="${GITLAB_URL}" \
  GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASS}" \
  DEBIAN_FRONTEND=noninteractive \
  apt-get install -y gitlab-ce=17.7.1-ce.0

sudo apt-mark hold gitlab-ce
```

---

## 2. Configure `/etc/gitlab/gitlab.rb` & Reconfigure

```bash
sudo tee /etc/gitlab/gitlab.rb >/dev/null <<EOF
external_url '${GITLAB_URL}'
gitlab_rails['time_zone'] = 'UTC'
gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASS}'

# Memory-tuned Puma & Sidekiq workers
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10

# External Prometheus scrapes gitlab_exporter; disable bundled Prometheus server
prometheus_monitoring['enable'] = false
gitlab_exporter['enable'] = true

# Backup retention (7 days = 604800 seconds)
gitlab_rails['backup_keep_time'] = 604800
EOF

sudo chmod 0600 /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure

# Open UFW Firewall ports
sudo ufw allow 80/tcp comment 'GitLab HTTP'
sudo ufw allow 443/tcp comment 'GitLab HTTPS'
```

---

## 3. Install GitLab CLI (`glab`)

```bash
GLAB_VER="1.51.0"
ARCH=$(dpkg --print-architecture) # amd64 or arm64

curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VER}/downloads/glab_${GLAB_VER}_linux_${ARCH}.deb" \
  -o /tmp/glab.deb
sudo dpkg -i /tmp/glab.deb
glab --version
```

---

## 4. GitLab Server & `glab` CLI Reference

### 4.1 `gitlab-ctl` (Omnibus Service Management CLI)
```bash
# Check status of all GitLab internal components (puma, sidekiq, postgresql, redis, nginx, gitaly)
sudo gitlab-ctl status

# Reconfigure GitLab after editing /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure

# Start / Stop / Restart all components or a single component
sudo gitlab-ctl restart
sudo gitlab-ctl restart sidekiq

# Tail all GitLab logs or a specific service log
sudo gitlab-ctl tail
sudo gitlab-ctl tail nginx/gitlab_access.log
```

### 4.2 `gitlab-rake` & `gitlab-backup` (Administration & Backup CLI)
```bash
# Run GitLab system and environment diagnostics
sudo gitlab-rake gitlab:env:info
sudo gitlab-rake gitlab:check SANITIZE=true

# Reset the 'root' administrator password via CLI
sudo gitlab-rake "gitlab:password:reset[root]"

# Create a full GitLab backup archive in /var/opt/gitlab/backups/
sudo gitlab-backup create

# Restore a backup (specify timestamp prefix without _gitlab_backup.tar)
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq
sudo gitlab-backup restore BACKUP=1730700000_2026_11_04_17.7.1
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
```

### 4.3 `glab` (Official GitLab CLI for Repos, MRs, & Pipelines)
```bash
# Authenticate glab against your self-hosted GitLab instance
glab auth login --hostname gitlab.internal.example.com --token <PERSONAL_ACCESS_TOKEN>

# Check authentication status
glab auth status

# Create a new repository (e.g., gitops or sample-api)
glab repo create devops/gitops --private --description "Argo CD GitOps Repository"

# List projects, merge requests, and CI/CD pipelines
glab repo list
glab mr list --repo devops/gitops
glab ci status --repo devops/gitops
```

