# Backup and Disaster Recovery Guide

This guide defines the backup architecture, RPO/RTO targets, encryption standards, and step-by-step restoration procedures for all 11 stateful platform components (**Section 14**).

---

## 1. Backup Policy, RPO, and RTO Matrix

All backups are encrypted with **AES-256 (`gpg --cipher-algo AES256`)** and replicated off-host to dedicated backup storage (`s3://devops-backups` on isolated MinIO/S3 hardware or an external NFS backup appliance).

| # | Component | Backup Frequency | Retention | Primary Backup Location | RPO | RTO |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | **GitLab Repositories & Config** | Daily (`01:00`) + Config on change | 14 Daily / 4 Weekly | `s3://devops-backups/gitlab/` | 24h (or 15m w/ Git mirror) | 45m |
| 2 | **Jenkins Config & Job History** | Daily (`02:00`) | 14 Daily | `s3://devops-backups/jenkins/` | 24h | 30m |
| 3 | **Nexus Repositories & Blobs** | Daily (`02:30`) | 14 Daily / 4 Weekly | `s3://devops-backups/nexus/` | 24h | 60m |
| 4 | **Kubernetes etcd & Manifests** | Every 6 hours (`0 */6 * * *`) | 28 Snapshots (7 days) | `s3://devops-backups/k8s-etcd/` | 6h (Manifests in Git: 0m) | 30m |
| 5 | **Rancher Configuration** | Daily (`03:00`) | 14 Daily | `s3://devops-backups/rancher/` | 24h | 30m |
| 6 | **Argo CD Configuration** | Daily (`03:15`) + Git | 30 Daily | `s3://devops-backups/argocd/` | 24h | 15m |
| 7 | **MinIO Buckets & Metadata** | Continuous (`mc mirror`) + Daily | 30 Days | Secondary Off-Host NAS/S3 | 1h | 30m |
| 8 | **Prometheus TSDB & Rules** | Daily (`03:30`) | 14 Daily | `s3://devops-backups/prometheus/` | 24h | 20m |
| 9 | **Grafana Dashboards & SQLite/DB** | Daily (`03:45`) | 30 Daily | `s3://devops-backups/grafana/` | 24h | 15m |
| 10 | **Loki Log Chunks & Index** | Daily (`04:00`) | 14 Daily | `s3://devops-backups/loki/` | 24h | 20m |
| 11 | **Ansible Vault & Keys** | On every change | 90 Days (Versioned) | Offline Encrypted Vault + Git | 0m | 5m |

---

## 2. Automated Backup Execution

Run the platform backup script (`scripts/backup-platform.sh`):
```bash
./scripts/backup-platform.sh --env production --output-dir /var/backups/devops-platform
```

---

## 3. Component-by-Component Backup & Restore Procedures

### 3.1 GitLab CE (Repositories, Database, and `/etc/gitlab` Secrets)
- **Backup Command:**
  ```bash
  sudo gitlab-backup create STRATEGY=copy
  sudo tar -czf /var/opt/gitlab/backups/gitlab-secrets-$(date +%F).tar.gz /etc/gitlab/gitlab.rb /etc/gitlab/gitlab-secrets.json /etc/gitlab/ssl
  ```
- **Restore Procedure:**
  ```bash
  sudo tar -xzf gitlab-secrets-<date>.tar.gz -C /
  sudo gitlab-ctl stop puma && sudo gitlab-ctl stop sidekiq
  sudo gitlab-backup restore BACKUP=<timestamp_version> force=yes
  sudo gitlab-ctl reconfigure && sudo gitlab-ctl restart
  sudo gitlab-rake gitlab:check SANITIZE=true
  ```

### 3.2 Jenkins Configuration and Jobs (`/var/lib/jenkins`)
- **Backup Command:**
  ```bash
  sudo tar --exclude='/var/lib/jenkins/workspace/*' --exclude='/var/lib/jenkins/caches/*' \
    -czf /var/backups/jenkins-backup-$(date +%F).tar.gz \
    /var/lib/jenkins/config.xml /var/lib/jenkins/jobs /var/lib/jenkins/users /var/lib/jenkins/secrets /var/lib/jenkins/plugins
  ```
- **Restore Procedure:**
  ```bash
  sudo systemctl stop jenkins
  sudo tar -xzf /var/backups/jenkins-backup-<date>.tar.gz -C /
  sudo chown -R jenkins:jenkins /var/lib/jenkins
  sudo systemctl start jenkins
  ```

### 3.3 Nexus Repository OSS (`/var/lib/nexus/nexus-data`)
- **Backup Command:**
  ```bash
  sudo tar -czf /var/backups/nexus-data-$(date +%F).tar.gz -C /var/lib/nexus nexus-data
  ```
- **Restore Procedure:**
  ```bash
  sudo systemctl stop nexus
  sudo rm -rf /var/lib/nexus/nexus-data
  sudo tar -xzf /var/backups/nexus-data-<date>.tar.gz -C /var/lib/nexus
  sudo chown -R 200:200 /var/lib/nexus/nexus-data
  sudo systemctl start nexus
  ```

### 3.4 Kubernetes etcd Snapshot & Manifests
- **Backup Command (on `prod-k8s-cp01`):**
  ```bash
  sudo ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd-snapshot-$(date +%F-%H%M).db \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key
  ```
- **Restore Procedure:**
  ```bash
  sudo ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd-snapshot-<timestamp>.db \
    --data-dir=/var/lib/etcd-restored
  sudo mv /var/lib/etcd /var/lib/etcd.bak && sudo mv /var/lib/etcd-restored /var/lib/etcd
  sudo systemctl restart kubelet
  ```

### 3.5 Rancher Server (`/var/lib/rancher`)
- **Backup Command:**
  ```bash
  sudo docker stop rancher
  sudo tar -czf /var/backups/rancher-data-$(date +%F).tar.gz -C /var/lib rancher
  sudo docker start rancher
  ```
- **Restore Procedure:**
  ```bash
  sudo systemctl stop rancher
  sudo rm -rf /var/lib/rancher && sudo tar -xzf /var/backups/rancher-data-<date>.tar.gz -C /var/lib
  sudo systemctl start rancher
  ```

### 3.6 Argo CD Configuration
- **Backup Command:**
  ```bash
  kubectl get applications,appprojects -n argocd -o yaml > /var/backups/argocd-apps-$(date +%F).yaml
  kubectl get configmap argocd-cm argocd-rbac-cm -n argocd -o yaml > /var/backups/argocd-cm-$(date +%F).yaml
  ```
- **Restore Procedure:**
  ```bash
  kubectl apply -f /var/backups/argocd-cm-<date>.yaml
  kubectl apply -f /var/backups/argocd-apps-<date>.yaml
  ```

### 3.7 MinIO, Prometheus, Grafana, Loki, and Ansible Vault
- **MinIO Mirror Backup:** `mc mirror local/ /mnt/offhost-backup/minio/`
- **Prometheus TSDB Snapshot:** `curl -XPOST http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot`
- **Grafana Database & Provisioning:** `sudo tar -czf /var/backups/grafana-$(date +%F).tar.gz /var/lib/grafana /etc/grafana`
- **Loki Storage:** `sudo tar -czf /var/backups/loki-$(date +%F).tar.gz /var/lib/loki /etc/loki`
- **Ansible Vault:** Back up encrypted `inventories/production/group_vars/vault.yml` to Git and store the `.vault_pass` passphrase in an offline enterprise password manager (1Password / Bitwarden / KeePassXC).

