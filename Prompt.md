# AI Prompt

# AI Prompt: Build an On-Premises DevOps Platform with Ansible, Multipass and Manual Production Installation

## 1. Role

Act as a Senior DevOps Engineer, Infrastructure Architect and Automation Specialist with extensive experience in:

- Ubuntu Server 24.04 LTS
- VMware vSphere / ESXi
- Multipass
- Ansible
- GitLab
- Jenkins
- Nexus Repository
- Kubernetes
- Rancher
- Calico
- Argo CD
- MinIO
- Prometheus
- Grafana
- Loki
- Linux networking and security
- CI/CD and GitOps architecture

Your task is to design and implement a complete on-premises DevOps platform.

The platform must support two deployment approaches:

1. **Local Testing Environment:** Use Multipass and Ansible to create and configure virtual machines on a local workstation.
2. **Production Environment:** Use manually provisioned Ubuntu VMs on VMware and deploy services through documented installation procedures.

Both environments must use the same architecture, software versions, configuration conventions and deployment logic wherever possible.

Do not create two different architectures.

---

# 2. Project Objectives

Build a reusable DevOps infrastructure that allows an organization to:

1. Manage source code using GitLab.
2. Automate application builds and testing using Jenkins.
3. Store Docker images and application artifacts in Nexus.
4. Deploy applications using Argo CD and GitOps.
5. Manage Kubernetes clusters using Rancher.
6. Run containerized applications using Kubernetes.
7. Implement Kubernetes networking using Calico.
8. Provide S3-compatible object storage using MinIO.
9. Monitor infrastructure and applications using Prometheus.
10. Visualize metrics using Grafana.
11. Centralize logs using Loki.
12. Secure infrastructure using proper access control and network policies.

The implementation must be modular, repeatable, maintainable and suitable for production.

---

# 3. Technology Stack

Use the following technology stack.

| Layer | Technology | Purpose |
| --- | --- | --- |
| Virtualization | VMware / Multipass | Virtual machines |
| OS | Ubuntu Server 24.04 LTS | Server operating system |
| Configuration Management | Ansible | Automated configuration |
| Source Control | GitLab | Git repositories |
| CI | Jenkins | Build and test automation |
| Artifact Repository | Nexus Repository | Docker registry and artifacts |
| Container Runtime | containerd | Kubernetes container runtime |
| Orchestration | Kubernetes | Container orchestration |
| Cluster Management | Rancher | Kubernetes administration |
| CNI | Calico | Pod networking |
| CD / GitOps | Argo CD | Kubernetes deployment |
| Object Storage | MinIO | S3-compatible storage |
| Monitoring | Prometheus | Metrics collection |
| Dashboard | Grafana | Visualization |
| Logging | Loki | Centralized logs |
| Image Scanning | Trivy | Container vulnerability scanning |
| Code Quality | SonarQube | Code quality analysis |
| Secrets Management | HashiCorp Vault | Secret management |

Before implementation, verify supported software versions and compatibility. Pin versions instead of installing unspecified latest releases.

---

# 4. Architecture

Implement the following logical architecture:

```
Developer Workstation
        |
        v
      GitLab
        |
        v
      Jenkins
        |
        +---- Build
        |
        +---- Test
        |
        +---- Security Scan
        |
        +---- Docker Build
        |
        v
    Nexus Registry
        |
        v
 Jenkins updates GitOps Repository
        |
        v
      GitLab
        |
        v
      Argo CD
        |
        v
    Kubernetes Cluster
        |
        +---- Rancher
        |
        +---- Calico
        |
        +---- Applications
        |
        +---- MinIO
        |
        +---- Monitoring
        |
        +---- Logging
```

Important design decisions:

- GitLab is the source code management platform.
- Jenkins is responsible for CI, not the primary Kubernetes deployment controller.
- Nexus stores container images and artifacts.
- Jenkins updates the GitOps repository after a successful build.
- Argo CD detects changes and synchronizes Kubernetes resources.
- Rancher manages Kubernetes clusters.
- Argo CD must not be replaced by Jenkins deployment scripts.
- PostgreSQL production databases should initially remain outside Kubernetes on dedicated database infrastructure.

---

# 5. Deployment Method A: Local Testing Using Multipass

## 5.1 Local Environment

Use Multipass to create Ubuntu virtual machines on the local development workstation.

The local environment must be lightweight enough to run on a developer workstation.

Provide two local testing profiles:

**Profile 1: Minimal DevOps Testing**

- GitLab
- Jenkins
- Nexus
- Single-node Kubernetes
- Rancher
- Argo CD
- Basic Prometheus and Grafana

**Profile 2: HA Architecture Simulation**

- Three Kubernetes control-plane nodes
- Three Kubernetes worker nodes
- Dedicated DevOps VMs
- Rancher
- Argo CD
- Monitoring and logging

Explain the resource requirements and limitations of running an HA simulation on one physical workstation. Do not claim it provides physical host-level HA.

## 5.2 Example Multipass VM Plan

Create a configurable VM inventory.

| VM | CPU | RAM | Disk | Purpose |
| --- | --- | --- | --- | --- |
| devops-gitlab | 4 | 8 GB | 100 GB | GitLab |
| devops-jenkins | 2 | 4 GB | 40 GB | Jenkins |
| devops-nexus | 2 | 4 GB | 100 GB | Nexus |
| devops-rancher | 2 | 4 GB | 40 GB | Rancher |
| k8s-cp01 | 2 | 4 GB | 40 GB | Control Plane |
| k8s-worker01 | 2 | 4 GB | 50 GB | Worker |
| devops-monitor | 2 | 4 GB | 60 GB | Monitoring |

These are illustrative local testing allocations. Make the VM profile configurable because resource availability differs between workstations.

Do not allocate more memory than the workstation can safely provide.

## 5.3 Multipass Automation

Create scripts to:

- Check Multipass installation.
- Check available workstation resources.
- Create VMs.
- Configure CPU, RAM and disk.
- Configure VM networking.
- Generate an inventory file.
- Display VM status and IP addresses.
- Destroy the testing environment.
- Recreate the environment.

Example commands:

```
multipass launch 24.04 \
  --name devops-jenkins \
  --cpus 2 \
  --memory 4G \
  --disk 40G

multipass list
multipass info devops-jenkins
```

The scripts must be idempotent and must not destroy existing VMs without explicit confirmation.

---

# 6. Deployment Method B: Production Using VMware and Manual Installation

Production VMs will be created manually by the infrastructure team through VMware vSphere.

The deployment process must not require Multipass.

Production preparation:

1. Create Ubuntu Server 24.04 VMs.
2. Configure CPU, memory and disks.
3. Configure static IP addresses.
4. Configure DNS and hostname.
5. Configure NTP.
6. Configure SSH access.
7. Apply OS updates.
8. Configure firewall rules.
9. Validate network connectivity.
10. Provide the Ansible inventory to deploy the services.

Create detailed manual installation documentation for every service.

The documentation must include:

- Prerequisites.
- Required resources.
- Installation commands.
- Configuration files.
- Environment variables.
- Firewall requirements.
- TLS configuration.
- Service startup.
- Verification commands.
- Backup procedures.
- Upgrade procedures.
- Troubleshooting.

Manual production installation means manually provisioning the VMs and executing the documented installation workflow. It does not mean manually configuring every service without automation.

Ansible should still be used for repeatable production configuration where possible.

---

# 7. Ansible Architecture

Use Ansible as the main configuration management system.

Ansible must support both local Multipass VMs and production VMware VMs.

Use separate inventories for each environment.

## 7.1 Project Directory Structure

Create the following project:

```
onprem-devops-platform/
│
├── README.md
├── ansible.cfg
├── requirements.yml
│
├── inventories/
│   ├── local/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   │
│   └── production/
│       ├── hosts.yml
│       └── group_vars/
│
├── playbooks/
│   ├── site.yml
│   ├── common.yml
│   ├── gitlab.yml
│   ├── jenkins.yml
│   ├── nexus.yml
│   ├── rancher.yml
│   ├── kubernetes.yml
│   ├── calico.yml
│   ├── argocd.yml
│   ├── minio.yml
│   ├── monitoring.yml
│   ├── logging.yml
│   └── security.yml
│
├── roles/
│   ├── common/
│   ├── docker/
│   ├── containerd/
│   ├── gitlab/
│   ├── jenkins/
│   ├── nexus/
│   ├── kubernetes/
│   ├── rancher/
│   ├── calico/
│   ├── argocd/
│   ├── minio/
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   └── security/
│
├── multipass/
│   ├── create-vms.sh
│   ├── destroy-vms.sh
│   ├── generate-inventory.sh
│   └── status.sh
│
├── kubernetes/
│   ├── namespaces/
│   ├── ingress/
│   ├── storage/
│   ├── monitoring/
│   ├── argocd/
│   └── applications/
│
├── gitops/
│   ├── applications/
│   ├── infrastructure/
│   └── clusters/
│
├── jenkins/
│   ├── Jenkinsfile.example
│   └── shared-library/
│
├── docs/
│   ├── architecture.md
│   ├── prerequisites.md
│   ├── local-installation.md
│   ├── production-installation.md
│   ├── networking.md
│   ├── security.md
│   ├── backup-restore.md
│   ├── troubleshooting.md
│   └── operations.md
│
├── scripts/
│   ├── health-check.sh
│   ├── validate-network.sh
│   └── validate-services.sh
│
└── .gitignore
```

You may improve the structure if there is a clear technical reason.

## 7.2 Ansible Requirements

All Ansible roles must:

- Be idempotent.
- Support Ubuntu Server 24.04.
- Use variables instead of hardcoded IPs.
- Support local and production inventories.
- Validate prerequisites.
- Use handlers for service restarts.
- Include error handling.
- Avoid exposing secrets.
- Include service health checks.
- Support safe re-execution.
- Provide clear execution output.

Use Ansible Vault for passwords, tokens and other sensitive values.

Do not store production credentials in Git.

---

# 8. Environment Configuration

Separate environment-specific configuration from reusable roles.

Example:

```
# inventories/local/group_vars/all.yml

environment: local

domain: devops.local

timezone: Asia/Phnom_Penh

kubernetes_version: "<pinned-supported-version>"

pod_cidr: "10.244.0.0/16"
service_cidr: "10.96.0.0/12"

gitlab_domain: gitlab.devops.local
jenkins_domain: jenkins.devops.local
nexus_domain: nexus.devops.local
rancher_domain: rancher.devops.local
```

Production configuration:

```
# inventories/production/group_vars/all.yml

environment: production

domain: internal.example.com

timezone: Asia/Phnom_Penh

kubernetes_version: "<pinned-supported-version>"

pod_cidr: "10.244.0.0/16"
service_cidr: "10.96.0.0/12"

gitlab_domain: gitlab.internal.example.com
jenkins_domain: jenkins.internal.example.com
nexus_domain: nexus.internal.example.com
rancher_domain: rancher.internal.example.com
```

These are examples. Confirm that the Kubernetes CIDRs do not overlap with existing VLANs or VPN networks.

---

# 9. Kubernetes Deployment

Use a supported Kubernetes distribution and pin its version.

Implement:

1. Three-node control plane for production.
2. Three worker nodes for production.
3. containerd runtime.
4. Calico CNI.
5. API server high availability.
6. Kubernetes RBAC.
7. Namespace separation.
8. Resource quotas.
9. Network policies.
10. Persistent volume integration.
11. Ingress controller.
12. Internal DNS integration.

For local testing, allow a single-node Kubernetes profile.

For production, provide a separate HA installation guide.

Do not assume a Multipass single-node cluster is equivalent to production HA.

---

# 10. Jenkins CI Pipeline

Create a reusable Jenkins pipeline.

Expected workflow:

```
GitLab Push
    |
    v
Jenkins Webhook
    |
    v
Checkout Source Code
    |
    v
Install Dependencies
    |
    v
Unit Tests
    |
    v
Code Quality Scan
    |
    v
Security Scan
    |
    v
Docker Build
    |
    v
Docker Image Scan
    |
    v
Push Image to Nexus
    |
    v
Update GitOps Repository
    |
    v
Argo CD Synchronization
    |
    v
Kubernetes Deployment
```

Use immutable image tags.

Recommended tagging:

```
application:1.0.0
application:git-commit-sha
application:build-number
```

Never rely on the `latest` tag for production deployments.

Implement:

- Build failure handling.
- Test reports.
- Security scan reports.
- Image tagging.
- Nexus authentication.
- GitOps repository updates.
- Deployment notifications.
- Build artifact cleanup.

Jenkins must not directly perform unrestricted production deployments using cluster administrator credentials.

---

# 11. Argo CD GitOps Configuration

Create GitOps repositories with environment separation.

Example:

```
gitops/
│
├── applications/
│   ├── api/
│   │   ├── base/
│   │   └── overlays/
│   │       ├── dev/
│   │       ├── staging/
│   │       └── production/
│   │
│   └── frontend/
│
├── infrastructure/
│   ├── ingress/
│   ├── monitoring/
│   └── storage/
│
└── clusters/
    ├── local/
    └── production/
```

Implement:

- Automated synchronization for development.
- Manual approval for production.
- Git-based rollback.
- Health checks.
- Drift detection.
- Secure repository credentials.

Production changes must follow an approval process.

---

# 12. Security Requirements

Implement security best practices.

- SSH key authentication.
- Disable password-based SSH where appropriate.
- Configure UFW or approved host firewall policies.
- TLS for all web interfaces.
- Kubernetes RBAC.
- Calico network policies.
- Jenkins credential management.
- Ansible Vault.
- Nexus access control.
- Argo CD scoped permissions.
- Container image scanning.
- OS security updates.
- Audit logging.
- Secret rotation.

Never expose the Docker socket or unrestricted Kubernetes administrator credentials to Jenkins jobs.

Use dedicated service accounts and least-privilege permissions.

---

# 13. Testing and Validation

Create automated tests for both deployment methods.

## Local Testing

Verify:

- Multipass VM creation.
- Ansible connectivity.
- OS configuration.
- GitLab accessibility.
- Jenkins accessibility.
- Nexus registry access.
- Kubernetes node health.
- Rancher accessibility.
- Argo CD accessibility.
- Container image push and pull.
- Successful application deployment.
- Prometheus metrics.
- Grafana dashboards.
- Loki log ingestion.

## Production Testing

Verify:

- VM connectivity.
- Static IP and DNS resolution.
- Firewall rules.
- Kubernetes control-plane health.
- Worker node readiness.
- API endpoint availability.
- Application deployment.
- Argo CD synchronization.
- Image registry authentication.
- Monitoring alerts.
- Backup and restore.
- Node failure recovery.
- Deployment rollback.

Provide automated validation scripts and expected outputs.

---

# 14. Backup and Disaster Recovery

Design backup procedures for:

- GitLab repositories and configuration.
- Jenkins configuration and jobs.
- Nexus repositories and metadata.
- Kubernetes manifests.
- Rancher configuration.
- Argo CD configuration.
- MinIO data.
- Prometheus configuration.
- Grafana dashboards.
- Loki data.
- Ansible Vault files.

Separate backups from primary infrastructure.

Document:

- Backup frequency.
- Retention.
- Backup location.
- Encryption.
- Recovery procedures.
- Recovery Point Objective (RPO).
- Recovery Time Objective (RTO).

Provide practical restoration commands and verification steps.

---

# 15. Documentation Requirements

Generate complete Markdown documentation.

Required documents:

1. Architecture overview.
2. Infrastructure requirements.
3. VMware VM preparation.
4. Multipass local environment setup.
5. Ansible installation.
6. Ansible inventory configuration.
7. Local deployment guide.
8. Production manual installation guide.
9. Kubernetes HA installation.
10. Calico installation.
11. Rancher installation.
12. Jenkins installation and configuration.
13. Nexus installation and configuration.
14. Argo CD installation and configuration.
15. GitLab integration.
16. CI/CD pipeline setup.
17. GitOps repository setup.
18. Monitoring installation.
19. Logging installation.
20. Security hardening.
21. Backup and recovery.
22. Troubleshooting.
23. Operational maintenance.

Each document must include commands, configuration examples, prerequisites, verification procedures and expected results.

---

# 16. Implementation Rules

Follow these rules strictly:

1. Do not generate the entire project as one large script.
2. Build the project in logical phases.
3. Create reusable Ansible roles.
4. Keep configuration separate from code.
5. Do not hardcode IP addresses.
6. Do not hardcode credentials.
7. Use supported and pinned software versions.
8. Verify official installation procedures.
9. Do not use deprecated installation commands.
10. Do not assume all services require separate physical hosts.
11. Do not destroy existing Multipass VMs without confirmation.
12. Do not run destructive production commands automatically.
13. Provide a validation step after each installation.
14. Include rollback and recovery procedures.
15. Explain architectural decisions.
16. Keep local and production configuration consistent.
17. Make production deployment safe and repeatable.

When a version, installation method or compatibility detail is uncertain, verify it using official documentation before generating implementation commands.

---

# 17. Development Execution Plan

Implement the project in the following order.

**Phase 1: Project Foundation**

- Create directory structure.
- Create README.
- Configure Ansible.
- Create local and production inventories.
- Create common Ansible role.
- Create Multipass scripts.

**Phase 2: Local Environment**

- Create Multipass VMs.
- Configure Ubuntu.
- Configure networking.
- Test Ansible connectivity.
- Validate infrastructure.

**Phase 3: DevOps Services**

- Install GitLab.
- Install Jenkins.
- Install Nexus.
- Integrate GitLab with Jenkins.
- Test CI pipeline.

**Phase 4: Kubernetes**

- Install Kubernetes.
- Configure containerd.
- Install Calico.
- Configure Rancher.
- Configure Argo CD.

**Phase 5: GitOps**

- Create GitOps repository.
- Configure Argo CD.
- Integrate Jenkins.
- Deploy a sample application.
- Test rollback.

**Phase 6: Monitoring and Logging**

- Install Prometheus.
- Install Grafana.
- Install Loki.
- Configure dashboards and alerts.

**Phase 7: Production Documentation**

- Prepare VMware VM deployment guide.
- Prepare manual production installation.
- Reuse Ansible roles and configuration.
- Implement production security controls.
- Test backup and recovery.

---

# 18. First Task: Start Implementation

Do not immediately generate the entire project.

Start by providing:

1. Proposed architecture.
2. Architecture diagram.
3. VM sizing for local and production environments.
4. Network and IP plan.
5. Project directory structure.
6. Ansible execution strategy.
7. Software version compatibility plan.
8. Implementation roadmap.

After presenting the design, start implementing Phase 1.

Generate actual files, scripts and Ansible roles where possible.

For each phase:

- Explain what will be created.
- Generate the complete files.
- Explain how to execute them.
- Provide expected output.
- Provide validation commands.
- Identify known limitations.
- Wait for validation before proceeding to the next phase.

The final deliverable must be a working, documented DevOps platform that can be tested locally with Multipass and deployed to production VMware infrastructure using manually provisioned Ubuntu VMs and Ansible.

**Primary goal: Build once, test locally, deploy consistently to production.**