# Platform Security Architecture & Hardening Guide

This document details the security controls implemented across the On-Premises DevOps Platform in accordance with **Section 12**.

---

## 1. Defense-in-Depth Control Matrix

| Control Domain | Implementation Mechanism | Verification Command |
| :--- | :--- | :--- |
| **SSH Hardening** | Ed25519 key auth only, `PasswordAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 4`, Fail2Ban `sshd` jail (`maxretry = 5`, `bantime = 1h`) | `sudo sshd -T \| grep -E 'permitrootlogin\|passwordauthentication'` |
| **Host Firewall (UFW)** | Default incoming `deny`, default outgoing `allow`, explicit per-role TCP/UDP rules (`roles/*/tasks/`) | `sudo ufw status verbose` |
| **TLS Everywhere** | HTTPS on GitLab (`443`), Rancher (`443`), Argo CD (`443` / `30443`), SAN X.509 certificates | `openssl s_client -connect gitlab.devops.local:443 </dev/null` |
| **Kubernetes RBAC** | Least-privilege `Role`/`RoleBinding` in `kubernetes/namespaces/rbac.yaml`; `restricted` PodSecurity Admission on `production` | `kubectl auth can-i --as=system:serviceaccount:production:devops-readonly-auditor delete pods -n production` (Returns `no`) |
| **Calico NetworkPolicies** | Default-deny all ingress/egress in `production` (`kubernetes/namespaces/network-policies.yaml`) with explicit allow rules for CoreDNS, Ingress, and Prometheus | `kubectl get networkpolicy -n production` |
| **CI Container Isolation** | Jenkins runs **rootless Buildah/Podman** (`/etc/subuid` `100000:65536`); **host `/var/run/docker.sock` is never mounted or exposed** | `ls -l /var/run/docker.sock` (Not accessible to `jenkins` user) |
| **GitOps Separation of Duties** | Jenkins cannot run `kubectl` against Kubernetes; Argo CD `production-project` requires manual sync approval by `devops:release-managers` | `kubectl get appproject production-project -n argocd -o yaml` |
| **Vulnerability Scanning** | Trivy (`0.58.1`) scans source filesystem (`trivy fs`) and built OCI image (`trivy image --severity CRITICAL --exit-code 1`) before registry push | `trivy --version` |
| **Secrets Management** | Infrastructure credentials encrypted via **Ansible Vault** (`vault.yml`); runtime secrets managed via **HashiCorp Vault** (`1.18.3`) | `ansible-vault view inventories/production/group_vars/vault.yml` |
| **Linux Audit Logging (`auditd`)** | Monitors `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, `/etc/ssh/sshd_config`, `/etc/kubernetes/`, `/etc/gitlab/` (`/etc/audit/rules.d/99-devops-security.rules`) | `sudo auditctl -l` |
| **OS Security Updates** | `unattended-upgrades` enabled across all Ubuntu 24.04 nodes | `systemctl is-active unattended-upgrades` |

---

## 2. Secret Rotation Procedures

### 2.1 Rotating Ansible Vault Passwords & Service Credentials
1. Re-key the Ansible Vault file:
   ```bash
   ansible-vault rekey inventories/production/group_vars/vault.yml
   ```
2. Update individual service credentials (`vault_gitlab_root_password`, `vault_nexus_admin_password`, `vault_argocd_admin_password`, `vault_grafana_admin_password`) inside `vault.yml`:
   ```bash
   ansible-vault edit inventories/production/group_vars/vault.yml
   ```
3. Re-run the corresponding playbook (`playbooks/argocd.yml`, `playbooks/monitoring.yml`, etc.) to apply the rotated secret idempotently.

### 2.2 Rotating Kubernetes Control Plane Certificates
Check certificate expiration dates and rotate before the 1-year expiry:
```bash
sudo kubeadm certs check-expiration
sudo kubeadm certs renew all
sudo systemctl restart kubelet
```

