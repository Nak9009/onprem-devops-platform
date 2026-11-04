# Prerequisites & Workstation Requirements

## 1. Local Development Workstation Requirements (Multipass Mode)

| Resource | `compact` Profile (6 VMs) | `minimal` Profile (7 VMs) | `ha` Simulation Profile (11 VMs) |
| :--- | :--- | :--- | :--- |
| **Host CPU** | >= 8 cores (12 recommended) | >= 12 cores | >= 16 cores |
| **Host RAM** | **24 GB** (allocates 16.5 GB) | **>= 40 GB** (allocates 32 GB) | **>= 64 GB** (allocates 48 GB) |
| **Free Host Disk** | **>= 25 GB free** (310 GB thin) | **>= 40 GB free** (430 GB thin) | **>= 60 GB free** (610 GB thin) |
| **Host OS** | macOS 13+ / Ubuntu 22.04+ | macOS 13+ / Ubuntu 22.04+ | macOS 13+ / Ubuntu 22.04+ |

### Required Local Tools
- **Multipass** `>= 1.14` (`1.16.4` verified)
- **Ansible Core** `>= 2.16` (`2.21.0` verified)
- **OpenSSH Client** (`ssh`, `ssh-keygen`)
- **Git** `>= 2.39`

### Verification Commands
```bash
multipass version
ansible --version
ansible-galaxy collection install -r requirements.yml
df -h /
```

---

## 2. Production VMware vSphere Requirements

### Hypervisor & Infrastructure Prerequisites
- **VMware vSphere / ESXi:** 7.0 U3 or 8.0+
- **Guest OS Template:** Ubuntu Server 24.04 LTS (`noble`) minimal cloud-init or ISO template
- **Storage:** Enterprise SSD/NVMe datastore (minimum 3,000 IOPS for etcd on Kubernetes control-plane nodes and GitLab/Nexus storage volumes)
- **Network:**
  - Dedicated VLAN/Subnet for DevOps Core (`10.20.10.0/24`)
  - Dedicated VLAN/Subnet for Kubernetes Nodes (`10.20.20.0/24`)
  - Non-overlapping Pod CIDR (`10.244.0.0/16`) and Service CIDR (`10.96.0.0/12`)
  - Internal Authoritative DNS (`internal.example.com`) and NTP servers (`ntp1.internal.example.com`, `ntp2.internal.example.com`)

