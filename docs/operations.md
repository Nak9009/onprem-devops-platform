# Operational Maintenance & Upgrade Runbook

This runbook covers routine day-2 operations, node failure recovery, and zero-downtime upgrade procedures (**Section 15, Topic 23**).

---

## 1. Routine Operational Health Checks

### Daily Automated Checks
```bash
# 1. Verify network, NTP, DNS, and firewall across all nodes
./scripts/validate-network.sh --env production

# 2. Check node CPU, RAM, Disk, Swap, and core daemons
./scripts/health-check.sh --env production

# 3. Validate all service HTTP/API health endpoints (Phases 2-6)
./scripts/validate-services.sh --env production --phase all
```

---

## 2. Node Failure Recovery Procedures

### 2.1 Recovering a Failed Kubernetes Worker Node
1. Drain and cordon the degraded node (if still reachable via API):
   ```bash
   kubectl drain prod-k8s-worker02 --ignore-daemonsets --delete-emptydir-data --force
   ```
2. Provision a replacement Ubuntu 24.04 VM in VMware vSphere with the same IP (`10.20.20.32`) and hostname (`prod-k8s-worker02`).
3. Run the Ansible baseline and Kubernetes playbooks limited to the replacement node:
   ```bash
   ansible-playbook -i inventories/production/hosts.yml playbooks/common.yml --limit prod-k8s-worker02 --ask-vault-pass
   ansible-playbook -i inventories/production/hosts.yml playbooks/kubernetes.yml --limit prod-k8s-plane,prod-k8s-worker02 --ask-vault-pass
   ```
4. Uncordon and verify:
   ```bash
   kubectl uncordon prod-k8s-worker02
   kubectl get nodes -o wide
   ```

### 2.2 Recovering a Failed HA Kubernetes Control Plane Node
1. Remove the failed etcd member from a healthy control-plane node (`prod-k8s-cp01`):
   ```bash
   kubectl exec -n kube-system etcd-prod-k8s-cp01 -- etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     member list
   ```
2. Provision replacement VM and re-run `playbooks/kubernetes.yml` to rejoin it as a control-plane member.

---

## 3. Controlled Version Upgrade Workflow

Never upgrade production directly without validating in the local Multipass environment first:

1. Update the pinned version variable (`gitlab_version`, `jenkins_version`, `kubernetes_version`, etc.) in `inventories/local/group_vars/all.yml`.
2. Execute the playbook against the local Multipass environment and run `./scripts/validate-services.sh --env local --phase all`.
3. Take a full production backup using `./scripts/backup-platform.sh --env production`.
4. Promote the verified version pin to `inventories/production/group_vars/all.yml` and run the corresponding playbook during a scheduled maintenance window.

