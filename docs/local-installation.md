# Local Environment Setup Guide (Multipass + Ansible)

This guide covers **Phase 2: Local Environment** provisioning, Ubuntu 24.04 baseline configuration, networking setup, and validation.

---

## 1. Choose a Local VM Profile

Three profiles are provided in `multipass/profiles/`:

1. **`compact` (Default for 24 GB RAM hosts):** 6 VMs (`devops-gitlab`, `devops-jenkins`, `devops-nexus`, `devops-rancher`, `k8s-cp01`, `devops-monitor`), 16.5 GB total RAM.
2. **`minimal` (Section 5.2 Spec):** 7 VMs (adds dedicated `k8s-worker01`), 32 GB total RAM.
3. **`ha` (HA Architecture Simulation):** 11 VMs (3 control-plane + 3 worker nodes + DevOps VMs), 48 GB total RAM.

---

## 2. Provision Multipass VMs

### Option A: Provision Full Profile
```bash
./multipass/create-vms.sh --profile compact
```

### Option B: Provision a Single VM (When Host Disk Space is Constrained)
If your workstation has limited free disk space (e.g., < 20 GB free on `/`), you can provision and test individual VMs on demand:
```bash
./multipass/create-vms.sh --profile compact --vm k8s-cp01
```

### Check VM Status and Regenerate Inventory
```bash
./multipass/status.sh --profile compact
./multipass/generate-inventory.sh --profile compact
```

---

## 3. Configure Ubuntu 24.04 Baseline with Ansible

Once the VMs are running and `inventories/local/hosts.yml` is populated:

```bash
# 1. Test Ansible SSH & Python connectivity
ansible all -i inventories/local/hosts.yml -m ping

# 2. Apply the common Ubuntu 24.04 baseline role
ansible-playbook -i inventories/local/hosts.yml playbooks/common.yml
```

---

## 4. Validate Local Infrastructure

Run the automated validation suite:
```bash
./scripts/validate-network.sh --env local
./scripts/health-check.sh --env local
./scripts/validate-services.sh --env local --phase 2
```

---

## 5. Destroy or Recreate the Testing Environment

The destroy script never deletes VMs without explicit interactive confirmation (`yes`):
```bash
./multipass/destroy-vms.sh --profile compact
```

