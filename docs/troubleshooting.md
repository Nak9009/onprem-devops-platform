# Platform Troubleshooting Guide

This guide provides diagnostic commands, root-cause analysis, and resolution steps across all layers of the On-Premises DevOps Platform (**Section 15, Topic 22**).

---

## 1. Multipass & Local Environment Issues

### Issue 1.1: `create-vms.sh` Refuses to Launch Due to Memory or Disk Guardrails
- **Symptom:** `[ERROR] Host root filesystem (/) only has 10 GB free space` or `[ERROR] Selected VMs require 32768 MB RAM, which exceeds the safe ceiling`.
- **Cause:** Safety guardrails in `multipass/create-vms.sh` prevent host swap thrashing or root filesystem exhaustion.
- **Resolution:**
  1. Use the `compact` profile on 24 GB RAM hosts: `./multipass/create-vms.sh --profile compact`.
  2. When free disk space is low (< 17 GB), launch a single VM at a time: `./multipass/create-vms.sh --profile compact --vm k8s-cp01`.
  3. Purge deleted Multipass instances: `multipass purge`.

### Issue 1.2: Ansible Cannot Connect to Local Multipass VMs After Reboot
- **Symptom:** `UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}`.
- **Cause:** Multipass DHCP assigned new IPv4 addresses on reboot.
- **Resolution:**
  ```bash
  ./multipass/generate-inventory.sh --profile compact
  ansible all -i inventories/local/hosts.yml -m ping
  ```

---

## 2. Kubernetes, containerd & Calico CNI Issues

### Issue 2.1: Kubernetes Nodes Remain in `NotReady` State After `kubeadm init`
- **Diagnosis:**
  ```bash
  kubectl describe node <node-name> | grep -A 10 Conditions
  kubectl get pods -n kube-system -o wide
  sudo journalctl -u kubelet -u containerd -n 50 --no-pager
  ```
- **Common Causes & Fixes:**
  1. **Swap is active:** Run `sudo swapoff -a` and re-run `playbooks/common.yml`.
  2. **Calico VXLAN/BGP blocked by UFW:** Ensure TCP `179` and UDP `4789` are allowed (`ansible-playbook playbooks/calico.yml --tags firewall`).
  3. **`SystemdCgroup` mismatch:** Verify `/etc/containerd/config.toml` has `SystemdCgroup = true` (`ansible-playbook playbooks/kubernetes.yml --tags containerd`).

### Issue 2.2: `ImagePullBackOff` From Private Nexus Registry (`registry.devops.local:5000`)
- **Diagnosis:**
  ```bash
  kubectl describe pod <pod-name> -n <namespace>
  sudo crictl pull registry.devops.local:5000/api:1.0.0-a1b2c3d4
  ```
- **Resolution:**
  1. Verify `/etc/hosts` resolves `registry.devops.local` to the Nexus node IP (`getent hosts registry.devops.local`).
  2. Verify `/etc/containerd/certs.d/registry.devops.local:5000/hosts.toml` exists and `containerd` was restarted.
  3. Confirm the `nexus-registry-secret` `imagePullSecret` exists in the target namespace.

---

## 3. GitLab, Jenkins & Nexus CI Pipeline Issues

### Issue 3.1: GitLab Webhook Returns `Url is blocked: Requests to the local network are not allowed`
- **Cause:** GitLab blocks webhooks to RFC1918 private IPs by default unless explicitly permitted.
- **Resolution:** Ensure `gitlab_rails['allow_local_requests_from_web_hooks_and_services'] = true` is set in `/etc/gitlab/gitlab.rb` (handled automatically by `roles/gitlab`) and run `sudo gitlab-ctl reconfigure`.

### Issue 3.2: Rootless Buildah Fails with `cannot setup namespace` on Jenkins
- **Diagnosis:**
  ```bash
  grep jenkins /etc/subuid /etc/subgid
  ```
- **Resolution:** Re-run `ansible-playbook playbooks/jenkins.yml --tags config` to configure `/etc/subuid` and `/etc/subgid` (`jenkins:100000:65536`).

---

## 4. Argo CD & GitOps Synchronization Issues

### Issue 4.1: `api-production` Stays `OutOfSync` After Jenkins Pipeline Succeeds
- **Explanation:** By design! Production applications in `gitops/clusters/production/applications.yaml` have **manual sync approval** enforced (no `automated` sync block).
- **Resolution (for Authorized Release Managers):**
  ```bash
  argocd app diff api-production
  argocd app sync api-production
  ```

