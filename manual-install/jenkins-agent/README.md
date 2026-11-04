# Dedicated Jenkins Build Agent Manual Installation & CLI Guide (`jenkins-agent`)

- **Target Host(s):** `prod-jenkins-agent01..02` (`10.20.20.12..13`, `VLAN 20`) or `devops-jenkins-agent01`
- **Versions:** OpenJDK 17, Rootless `buildah` + `podman` + `skopeo`, Trivy `0.58.1`, `kubectl` `v1.31.4`, `helm` `v3.16.4`
- **Automated Script:** [`manual-install/jenkins-agent/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/jenkins-agent/install.sh)

---

## 1. Create `jenkins-agent` User & Install Rootless Build Tools

```bash
NEXUS_IP="10.20.20.14"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openjdk-17-jre-headless git curl jq \
  buildah podman skopeo uidmap slirp4netns fuse-overlayfs

sudo groupadd --system jenkins-agent || true
sudo useradd --system --home-dir /var/lib/jenkins-agent --create-home --shell /bin/bash -g jenkins-agent jenkins-agent || true

grep -q "^jenkins-agent:" /etc/subuid || echo "jenkins-agent:165536:65536" | sudo tee -a /etc/subuid
grep -q "^jenkins-agent:" /etc/subgid || echo "jenkins-agent:165536:65536" | sudo tee -a /etc/subgid

sudo mkdir -p /etc/containers/registries.conf.d
sudo tee /etc/containers/registries.conf.d/99-nexus.conf >/dev/null <<EOF
[[registry]]
location = "${NEXUS_IP}:5000"
insecure = true
EOF
```

---

## 2. Install `trivy`, `kubectl`, and `helm` CLIs on Agent

```bash
ARCH_DEB=$(dpkg --print-architecture)
TRIVY_ARCH=$([ "$ARCH_DEB" = "arm64" ] && echo "ARM64" || echo "64bit")
TRIVY_VER="0.58.1"

curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VER}/trivy_${TRIVY_VER}_Linux-${TRIVY_ARCH}.tar.gz" -o /tmp/trivy.tar.gz
sudo tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
sudo chmod 0755 /usr/local/bin/trivy

sudo curl -fsSL "https://dl.k8s.io/release/v1.31.4/bin/linux/${ARCH_DEB}/kubectl" -o /usr/local/bin/kubectl
sudo chmod 0755 /usr/local/bin/kubectl

curl -fsSL "https://get.helm.sh/helm-v3.16.4-linux-${ARCH_DEB}.tar.gz" -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
sudo mv "/tmp/linux-${ARCH_DEB}/helm" /usr/local/bin/helm
sudo chmod 0755 /usr/local/bin/helm
```

---

## 3. Jenkins Agent CLI Reference

```bash
# Test rootless container build and push as jenkins-agent user
sudo -u jenkins-agent buildah version
sudo -u jenkins-agent podman info

# Scan a built OCI image with Trivy before pushing to Nexus
trivy image --severity HIGH,CRITICAL --exit-code 1 10.20.20.14:5000/devops/sample-api:1.0.0

# Validate Kustomize GitOps overlays offline (without K8s cluster access)
kubectl kustomize gitops/applications/api/overlays/production
```

