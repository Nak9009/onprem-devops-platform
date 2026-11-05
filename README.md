# On-Premises DevOps Platform (Ansible + Multipass + Production VMware)

A modular, repeatable, production-grade On-Premises DevOps Platform built on **Ubuntu Server 24.04 LTS**, managed by **Ansible**, and designed around a single unified architecture across three deployment targets:

1. **Local VM Testing Environment:** Automated VM provisioning on a developer workstation using **Multipass** and **Ansible**.
2. **Local Lightweight Docker Lab:** Fast, containerized 3-layer lab testing using **Docker Compose** & **KinD** without full VM hypervisor overhead.
3. **Production Environment:** Manually provisioned **VMware vSphere / ESXi** virtual machines configured with the same **Ansible** roles, pinned software versions, and documented operational runbooks.

---

## 1. Platform Capabilities & Technology Stack

| Layer | Technology | Pinned Version | Purpose |
| :--- | :--- | :--- | :--- |
| **Virtualization** | VMware vSphere / Multipass | vSphere 8 / Multipass 1.16+ | Hypervisor & VM provisioning |
| **Operating System** | Ubuntu Server LTS | `24.04` (Noble Numbat) | Standardized Linux server OS |
| **Configuration Mgmt** | Ansible Core | `>= 2.16` (`2.21` verified) | Idempotent configuration & orchestration |
| **Source Control** | GitLab CE | `17.7.1-ce.0` | Git repository hosting & webhooks |
| **Continuous Integration** | Jenkins LTS | `2.479.3` (OpenJDK 21) | Build, test, scan & GitOps PR/commit automation |
| **Artifact & Image Registry** | Sonatype Nexus Repository OSS | `3.75.1-01` | Private Docker registry, Maven/NPM/PyPI/Raw artifacts |
| **Container Runtime** | containerd | `1.7.24` | CRI-compliant Kubernetes container runtime |
| **Container Orchestration** | Kubernetes (`kubeadm`) | `1.31.4` | Container orchestration |
| **CNI Plugin** | Calico | `v3.29.1` | Pod networking & Kubernetes NetworkPolicies |
| **Cluster Management** | Rancher | `v2.10.1` | Multi-cluster Kubernetes management & RBAC |
| **Continuous Delivery (GitOps)** | Argo CD | `v2.13.2` | Declarative GitOps synchronization |
| **Object Storage** | MinIO | `RELEASE.2024-12-18T13-15-44Z` | S3-compatible object storage (Loki chunks, backups, artifacts) |
| **Monitoring** | Prometheus + Alertmanager | `2.53.3` / `0.27.0` | Infrastructure & Kubernetes metrics collection |
| **Visualization** | Grafana OSS | `11.4.0` | Dashboards & observability visualization |
| **Centralized Logging** | Grafana Loki + Promtail | `3.3.2` | Log aggregation backed by MinIO S3 storage |
| **Vulnerability Scanning** | Trivy | `0.58.1` | Container image & filesystem security scanning |
| **Code Quality** | SonarQube Community | `10.8.1` | Static code analysis in CI |
| **Secrets Management** | HashiCorp Vault + Ansible Vault | `1.18.3` | Runtime secret management & encrypted IaC credentials |

---

## 2. Logical Architecture

```text
Developer Workstation
        |
        v (git push)
      GitLab (Source Control)
        |
        v (Webhook)
      Jenkins (CI Pipeline)
        |---- 1. Checkout & Dependency Install
        |---- 2. Unit Tests & SonarQube Code Quality Scan
        |---- 3. Trivy Filesystem & Container Vulnerability Scan
        |---- 4. Build Immutable Container Image (app:<semver>-<git-sha>)
        v
    Nexus Repository (Private Docker Registry & Artifact Store)
        |
        v
  Jenkins updates GitOps Repository (Kustomize image tag commit)
        |
        v
      GitLab (GitOps Repository)
        |
        v (Pull / Webhook Sync)
      Argo CD (GitOps Controller)
        |
        v
    Kubernetes Cluster (containerd + Calico CNI)
        |---- Managed via Rancher
        |---- Applications (dev: auto-sync / prod: manual approval)
        |---- MinIO S3 Object Storage
        |---- Prometheus & Grafana Monitoring
        +---- Loki & Promtail Centralized Logging
```

### Core Architectural Principles
- **Build Once, Deploy Consistently:** Local Multipass and Production VMware share identical Ansible roles, variable naming conventions, and pinned package versions.
- **Separation of CI and CD:** Jenkins builds, scans, pushes immutable images to Nexus, and commits manifest updates to the GitOps repository. Jenkins **never** holds cluster-admin credentials or runs `kubectl apply` directly against production.
- **GitOps Enforcement:** Argo CD is the single source of truth for Kubernetes deployments, with automated sync in `dev` and manual sync gates in `production`.
- **Externalized Stateful Databases:** Production PostgreSQL databases reside on dedicated VM infrastructure outside Kubernetes.

---

## 3. Repository Structure

```text
onprem-devops-platform/
├── README.md
├── ansible.cfg
├── requirements.yml
├── inventories/
│   ├── local/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   │       ├── all.yml
│   │       └── vault.yml.example
│   └── production/
│       ├── hosts.yml
│       └── group_vars/
│           ├── all.yml
│           └── vault.yml.example
├── playbooks/
│   ├── site.yml
│   ├── common.yml
│   └── ... (service playbooks per phase)
├── roles/
│   ├── common/
│   └── ... (modular service roles)
├── docker-lab/
│   ├── docker-compose.yml
│   ├── kind-mgmt-cluster.yaml
│   ├── kind-app-cluster.yaml
│   ├── setup-lab.sh
│   └── destroy-lab.sh
├── multipass/
│   ├── profiles/
│   │   ├── compact.conf
│   │   ├── minimal.conf
│   │   └── ha.conf
│   ├── create-vms.sh
│   ├── destroy-vms.sh
│   ├── generate-inventory.sh
│   └── status.sh
├── kubernetes/
├── gitops/
├── jenkins/
├── docs/
└── scripts/
```

---

## 4. Quickstart: Phase 1 Verification

### 4.1 Install Required Ansible Collections
```bash
ansible-galaxy collection install -r requirements.yml
```

### 4.2 Dry-Run Multipass Provisioning & Resource Check
```bash
./multipass/create-vms.sh --profile compact --dry-run
```

### 4.3 Validate Ansible Playbook Syntax
```bash
ansible-playbook -i inventories/local/hosts.yml playbooks/common.yml --syntax-check
ansible-playbook -i inventories/production/hosts.yml playbooks/common.yml --syntax-check
```

### 4.4 Launch Lightweight Docker Lab (Zero-VM Alternative)
```bash
# Start Core DevOps stack (GitLab, Jenkins, Nexus, MinIO, PostgreSQL, Redis)
./docker-lab/setup-lab.sh --profile core

# Or run with KinD Kubernetes Management & Application Clusters
./docker-lab/setup-lab.sh --profile core --with-k8s
```

