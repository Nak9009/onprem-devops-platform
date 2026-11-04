# Jenkins CI Server Manual Installation & CLI Guide (`jenkins`)

- **Target Host:** `devops-jenkins` (`192.168.252.11`) or `prod-jenkins-01` (`10.20.10.11`)
- **Versions:** Jenkins LTS `2.479.3`, OpenJDK 17, Rootless `buildah`/`podman`/`skopeo`, Trivy `0.58.1`, `kubectl` `v1.31.4`, `helm` `v3.16.4`
- **Automated Script:** [`manual-install/jenkins/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/jenkins/install.sh)
- **Security Rules:**
  1. Do **NOT** install `docker-ce` or mount `/var/run/docker.sock` on Jenkins; use rootless `buildah` + `podman`.
  2. Do **NOT** place Kubernetes `cluster-admin` credentials on Jenkins; Jenkins updates the GitOps repository and Argo CD reconciles the cluster.

---

## 1. Install OpenJDK 17 & Jenkins LTS (`2.479.3`)

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fontconfig openjdk-17-jre

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /etc/apt/keyrings/jenkins-keyring.asc >/dev/null

sudo tee /etc/apt/sources.list.d/jenkins.sources >/dev/null <<'EOF'
Types: deb
URIs: https://pkg.jenkins.io/debian-stable
Suites: binary/
Signed-By: /etc/apt/keyrings/jenkins-keyring.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jenkins=2.479.3
sudo apt-mark hold jenkins
```

---

## 2. Install Rootless Container Build CLI (`buildah`, `podman`, `skopeo`)

```bash
NEXUS_IP="10.20.10.12"   # Or 192.168.252.12 for local

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  buildah podman skopeo uidmap slirp4netns fuse-overlayfs

# Configure subordinate UIDs/GIDs for rootless container builds under 'jenkins' user
grep -q "^jenkins:" /etc/subuid || echo "jenkins:100000:65536" | sudo tee -a /etc/subuid
grep -q "^jenkins:" /etc/subgid || echo "jenkins:100000:65536" | sudo tee -a /etc/subgid

sudo mkdir -p /etc/containers/registries.conf.d
sudo tee /etc/containers/registries.conf.d/99-nexus.conf >/dev/null <<EOF
[[registry]]
location = "${NEXUS_IP}:5000"
insecure = true

[[registry]]
location = "${NEXUS_IP}:5001"
insecure = true
EOF
```

---

## 3. Install Security & Kubernetes Manifest CLI (`trivy`, `kubectl`, `helm`)

```bash
ARCH_DEB=$(dpkg --print-architecture) # amd64 or arm64
TRIVY_ARCH=$([ "$ARCH_DEB" = "arm64" ] && echo "ARM64" || echo "64bit")
TRIVY_VER="0.58.1"

# 1. Trivy CLI
curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}/trivy_${TRIVY_VER}_Linux-${TRIVY_ARCH}.tar.gz" \
  -o /tmp/trivy.tar.gz
sudo tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
sudo chmod 0755 /usr/local/bin/trivy

# 2. kubectl CLI (for offline Kustomize & manifest validation in CI)
sudo curl -fsSL "https://dl.k8s.io/release/v1.31.4/bin/linux/${ARCH_DEB}/kubectl" -o /usr/local/bin/kubectl
sudo chmod 0755 /usr/local/bin/kubectl

# 3. Helm CLI
curl -fsSL "https://get.helm.sh/helm-v3.16.4-linux-${ARCH_DEB}.tar.gz" -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
sudo mv "/tmp/linux-${ARCH_DEB}/helm" /usr/local/bin/helm
sudo chmod 0755 /usr/local/bin/helm
```

---

## 4. Configure Systemd Override, Firewall & Download `jenkins-cli.jar`

```bash
sudo mkdir -p /etc/systemd/system/jenkins.service.d
sudo tee /etc/systemd/system/jenkins.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Xms512m -Xmx1024m"
Environment="JENKINS_PORT=8080"
EOF

sudo ufw allow 8080/tcp comment 'Jenkins Web UI'
sudo ufw allow 50000/tcp comment 'Jenkins Inbound JNLP Agents'

sudo systemctl daemon-reload
sudo systemctl enable --now jenkins

# Download official jenkins-cli.jar from running Jenkins server
curl -fsSL http://127.0.0.1:8080/jnlpJars/jenkins-cli.jar -o /usr/local/bin/jenkins-cli.jar
```

---

## 5. Jenkins & CI Tooling CLI Reference

### 5.1 `jenkins-cli.jar` (Jenkins Command-Line Interface)
```bash
export JENKINS_URL="http://127.0.0.1:8080"
export JENKINS_AUTH="admin:<ADMIN_PASSWORD_OR_TOKEN>"

# List all available CLI commands and Jenkins version
java -jar /usr/local/bin/jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" version
java -jar /usr/local/bin/jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" help

# Install plugins via CLI and safe-restart Jenkins
java -jar /usr/local/bin/jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" \
  install-plugin git workflow-aggregator git-client credentials-binding -deploy

# List jobs, trigger a pipeline build, and stream console output
java -jar /usr/local/bin/jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" list-jobs
java -jar /usr/local/bin/jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" build sample-api -s -v

# Safely restart Jenkins after all running jobs complete
java -jar /usr/local/bin/jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" safe-restart
```

### 5.2 Rootless `buildah`, `podman`, & `skopeo` CLI
```bash
# Build an OCI container image rootlessly using Buildah
sudo -u jenkins buildah bud --format oci -t 10.20.10.12:5000/devops/sample-api:1.0.0 .

# List local images and push to Nexus Docker Registry
sudo -u jenkins buildah images
sudo -u jenkins buildah push --tls-verify=false \
  --creds admin:<NEXUS_PASS> \
  10.20.10.12:5000/devops/sample-api:1.0.0 \
  docker://10.20.10.12:5000/devops/sample-api:1.0.0

# Inspect remote registry image metadata without pulling layers via skopeo
skopeo inspect --tls-verify=false docker://10.20.10.12:5000/devops/sample-api:1.0.0
```

### 5.3 `trivy` Vulnerability Scanner CLI
```bash
# Scan a container image for HIGH and CRITICAL vulnerabilities (fail CI on findings)
trivy image --severity HIGH,CRITICAL --exit-code 1 10.20.10.12:5000/devops/sample-api:1.0.0

# Scan filesystem / Git repository for secrets and misconfigurations
trivy fs --scanners vuln,secret,misconfig .
```

