# AI Prompt: Update On-Premises DevOps Architecture

Act as a Senior DevOps Architect, Kubernetes Architect, and Ansible Automation Engineer.

I already have an on-premises DevOps infrastructure project with architecture documentation, Ansible automation, Multipass local testing, and a production deployment plan using manually provisioned VMware VMs.

I want you to update the existing project to follow the new architecture described below.

Do not start a new project or discard the existing implementation. First inspect the existing repository, documentation, Ansible roles, inventories, Multipass configuration, Kubernetes manifests, and diagrams. Then propose and implement the necessary changes.

---

## 1. New Architecture Objective

The main architectural principle is:

**Kubernetes application clusters must run business applications only. All infrastructure services, databases, storage, and DevOps tools must operate independently of the application cluster.**

Separate the infrastructure into these layers.

### Layer 1: DevOps and Infrastructure Services (Outside Application Kubernetes)

These services must run on dedicated Ubuntu 24.04 VMware virtual machines or dedicated storage infrastructure.

| Service | Deployment | Responsibility |
|---|---|---|
| GitLab | Dedicated VM | Source code management and Git repositories |
| Jenkins | Dedicated VM | CI pipelines, building, testing, and scanning |
| Jenkins Agents | Separate VMs | Build and test workloads |
| Nexus Repository | Dedicated VM | Container image and artifact registry |
| MinIO / S3 | Dedicated storage infrastructure | Object storage |
| PostgreSQL | Dedicated database VMs | Operational databases and database HA |
| Redis | Dedicated VM or HA infrastructure | Cache, queues, and sessions |
| Prometheus | Monitoring infrastructure | Metrics collection |
| Grafana | Monitoring infrastructure | Dashboards and visualization |
| Loki | Monitoring infrastructure | Centralized logs |
| Backup Services | Independent infrastructure | VM, database, configuration, and object storage backup |

Important requirements:

- GitLab must not run inside the application Kubernetes cluster.
- Jenkins must not run inside the application Kubernetes cluster.
- Nexus must not run inside the application Kubernetes cluster.
- MinIO must not run inside the application Kubernetes cluster.
- PostgreSQL and Redis must not run inside the application Kubernetes cluster.
- Monitoring services should remain operational even if the application cluster is unavailable.
- All services must communicate through private network connections.

### Layer 2: Kubernetes Management Cluster

Run infrastructure management components in a separate, small management Kubernetes cluster.

| Component | Responsibility |
|---|---|
| Rancher | Kubernetes cluster management |
| Argo CD | GitOps-based application deployment |

Requirements:

- This cluster must be independent of the application Kubernetes cluster.
- Argo CD must not be deployed inside the application cluster.
- Rancher must manage the application cluster.
- Argo CD must deploy applications to the application cluster.
- The management cluster must not host business application workloads.
- Provide backup and recovery procedures for the management cluster.
- Use a separate management cluster inventory and Ansible configuration.

Important technical clarification:

Argo CD is Kubernetes-native and requires a Kubernetes environment to run. Do not incorrectly describe it as a native standalone Ubuntu service.

A small dedicated management Kubernetes cluster is the preferred solution. Document the additional infrastructure and resource requirements.

### Layer 3: Application Kubernetes Cluster

This cluster runs business applications only.

Example workloads:

- Frontend applications
- Backend APIs
- Laravel applications
- Node.js applications
- Microservices
- Background workers
- Scheduled jobs
- Application ingress controllers
- Application-related workloads

Kubernetes infrastructure components such as Calico, CoreDNS, CSI drivers, ingress controllers, and node-level agents are still required.

The application cluster must not host:

- GitLab
- Jenkins
- Nexus
- MinIO
- PostgreSQL
- Redis
- Prometheus
- Grafana
- Loki
- Rancher
- Argo CD

Use a production-ready topology with:

- 3 control-plane nodes
- 3 or more worker nodes
- Calico networking
- Highly available Kubernetes API endpoint
- Ingress and load balancing
- Persistent storage integration where required
- Resource requests and limits
- Pod disruption budgets
- Network policies
- Node affinity and anti-affinity

---

## 2. PostgreSQL Database Architecture

PostgreSQL must run outside Kubernetes on dedicated database infrastructure.

Use the following initial HA design:

| Hostname | Role |
|---|---|
| pg-db1 | PostgreSQL Leader |
| pg-db2 | Synchronous Standby |
| pg-db3 | Asynchronous Replica |

Requirements:

- Use a stable database endpoint through an appropriate HAProxy/VIP or equivalent solution.
- Design automatic failover using a suitable PostgreSQL HA manager.
- Explain synchronous and asynchronous replication.
- Define quorum, split-brain prevention, and failover behavior.
- Configure database backups and point-in-time recovery.
- Use pgBackRest or another suitable backup solution.
- Separate WAL storage and backup storage where practical.
- Monitor replication lag and database health.
- Define recovery time and recovery point objectives.
- Document how application workloads securely connect to PostgreSQL.
- Do not place PostgreSQL data volumes inside the application Kubernetes cluster.

Do not assume that PostgreSQL replication alone provides automatic failover. Include a complete HA control-plane design.

---

## 3. S3 / MinIO Architecture

MinIO must operate outside Kubernetes.

Requirements:

- Deploy MinIO on dedicated storage infrastructure.
- Use persistent storage with appropriate redundancy.
- Define a production storage topology based on available VMware hosts and disks.
- Explain distributed storage and failure-domain requirements.
- Configure TLS and access credentials.
- Use separate buckets and access policies for different applications.
- Configure versioning and lifecycle policies where appropriate.
- Design independent backup or replication.
- Monitor storage capacity, availability, and performance.
- Applications inside Kubernetes access S3 through private network endpoints.

Do not assume that a single MinIO VM provides high availability.

Check the current MinIO product documentation and supported deployment architecture before recommending a production topology.

---

## 4. Updated CI/CD Workflow

Implement this workflow:

1. Developer pushes code to GitLab.
2. GitLab triggers Jenkins using a webhook.
3. Jenkins checks out the source code.
4. Jenkins executes tests, code quality checks, and security scans.
5. Jenkins builds the Docker image.
6. Jenkins pushes the image to Nexus Repository.
7. Jenkins updates the GitOps repository with the new image tag.
8. Argo CD detects the GitOps repository change.
9. Argo CD deploys the updated application to the application Kubernetes cluster.
10. Prometheus, Grafana, and Loki monitor the application.

Architecture principles:

- GitLab is the source code management platform.
- Jenkins is responsible for CI and image builds.
- Nexus stores container images and build artifacts.
- The GitOps repository defines the desired application state.
- Argo CD is responsible for continuous delivery.
- Rancher manages the Kubernetes clusters.
- Ansible manages OS configuration and infrastructure service installation.

Jenkins must not have unrestricted Kubernetes administrator credentials.

Use secure credentials, least-privilege service accounts, and protected GitOps repositories.

---

## 5. Updated Ansible Architecture

I want one reusable Ansible automation project for both local testing and production.

Use the same Ansible roles and application configuration wherever possible.

The differences must be isolated in inventories and environment-specific variables.

Suggested project structure:

```text
onprem-devops-platform/
├── README.md
├── ansible.cfg
├── requirements.yml
│
├── inventories/
│   ├── local/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   └── production/
│       ├── hosts.yml
│       └── group_vars/
│
├── playbooks/
│   ├── site.yml
│   ├── infrastructure.yml
│   ├── devops-services.yml
│   ├── database.yml
│   ├── storage.yml
│   ├── monitoring.yml
│   ├── management-cluster.yml
│   └── application-cluster.yml
│
├── roles/
│   ├── common/
│   ├── security/
│   ├── docker/
│   ├── gitlab/
│   ├── jenkins/
│   ├── jenkins-agent/
│   ├── nexus/
│   ├── minio/
│   ├── postgresql/
│   ├── postgresql-ha/
│   ├── redis/
│   ├── kubernetes/
│   ├── containerd/
│   ├── calico/
│   ├── rancher/
│   ├── argocd/
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   └── backup/
│
├── multipass/
│   ├── profiles/
│   ├── cloud-init/
│   └── scripts/
│
├── kubernetes/
│   ├── management-cluster/
│   └── application-cluster/
│
├── gitops/
│   ├── base/
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── production/
│
├── jenkins/
│   ├── pipelines/
│   └── shared-library/
│
├── docs/
│   ├── architecture/
│   ├── network/
│   ├── deployment/
│   ├── database/
│   ├── storage/
│   ├── security/
│   ├── backup/
│   └── operations/
│
└── scripts/
```

You may adjust this structure if the existing repository has a better organization. Do not create duplicate roles or unnecessary directories.

### Ansible requirements

- Use Ansible roles with clear responsibilities.
- Ensure playbooks are idempotent.
- Use handlers and templates appropriately.
- Pin supported software versions.
- Use Ansible Vault for secrets.
- Never hardcode passwords, tokens, or private keys.
- Separate local and production inventories.
- Validate the inventory before deployment.
- Add pre-checks and post-deployment validation.
- Make roles reusable across environments.
- Avoid destructive changes without explicit confirmation.

---

## 6. Multipass Local Testing

I want to test the architecture locally on my workstation using Multipass.

Use Ubuntu 24.04 images.

Create two local deployment profiles.

**Profile A: Minimal testing**

Deploy a small environment that validates:

- GitLab
- Jenkins
- Nexus
- PostgreSQL
- MinIO
- Redis
- A management Kubernetes cluster
- Argo CD
- Rancher where resources allow
- A single-node application Kubernetes cluster
- Basic monitoring

Use reduced resource allocations for local testing.

**Profile B: HA architecture simulation**

Simulate:

- 3 Kubernetes management nodes where practical
- 3 application control-plane nodes
- 3 or more application worker nodes
- 3 PostgreSQL nodes
- Separate DevOps service VMs
- Separate monitoring and storage services

Multipass resource consumption must be considered. Provide a minimum and recommended workstation resource plan.

Important: A multi-VM local simulation does not prove physical high availability. Explain the difference between logical HA testing and production HA across separate VMware hosts.

Do not require all VMs to run simultaneously if workstation resources are insufficient.

---

## 7. Production Deployment

Production infrastructure is provisioned manually by the VMware infrastructure team.

The process should be:

1. Infrastructure team creates Ubuntu 24.04 VMs in VMware.
2. Assigns CPU, RAM, disks, VLANs, and static IP addresses.
3. Configures DNS and firewall rules.
4. Provides SSH access for Ansible.
5. Ansible configures operating systems and installs services.
6. Ansible deploys the management Kubernetes cluster.
7. Rancher registers and manages the application cluster.
8. Argo CD connects to the GitOps repository.
9. Jenkins pipelines build and publish applications.
10. Applications are deployed through Argo CD.

Do not create or provision production VMware VMs through Multipass.

Do not make production deployment depend on local testing infrastructure.

The production process must be repeatable using Ansible.

---

## 8. Network and Security Architecture

Create a complete network architecture with separate VLANs or equivalent network segmentation.

Propose a VLAN plan for:

- Management
- DevOps services
- Kubernetes management cluster
- Kubernetes application cluster
- Database
- Storage
- Monitoring
- Backup

Use example IP ranges only and clearly mark them as placeholders.

Define:

- Network access rules between each layer
- Firewall ports and traffic direction
- DNS requirements
- TLS certificates
- SSH access restrictions
- Database access restrictions
- S3 access restrictions
- Kubernetes API access
- Jenkins-to-Nexus communication
- Jenkins-to-GitLab communication
- Argo CD-to-GitOps communication
- Argo CD-to-application cluster communication
- Monitoring access to all infrastructure

Do not expose internal databases, Nexus, MinIO, Kubernetes APIs, or management interfaces directly to the public Internet.

Use private networking, TLS, secrets management, and least-privilege access.

---

## 9. Monitoring, Logging, and Backup

Monitoring must be independent of the application cluster.

Use:

- Prometheus for metrics
- Grafana for dashboards
- Loki for logs
- Node Exporter for Linux metrics
- Suitable database exporters
- Suitable Kubernetes monitoring components

Monitor:

- VMware VM health where available
- CPU, memory, disk, and network
- Kubernetes node and pod health
- PostgreSQL replication and failover
- MinIO availability and storage capacity
- GitLab and Jenkins health
- Nexus availability
- Redis availability
- Application health and response time
- Backup status

Design separate backup strategies for:

- GitLab
- Jenkins
- Nexus
- PostgreSQL
- MinIO
- Kubernetes configuration
- Rancher
- Argo CD
- Ansible repository
- GitOps repository

Keep backups independent from the systems being backed up.

Document backup retention, restore procedures, and recovery testing.

---

## 10. Architecture Documents and Diagrams to Update

Review and update all existing documentation to reflect the new architecture.

Create or revise:

1. High-Level Architecture Diagram
2. Detailed Infrastructure Architecture Diagram
3. DevOps CI/CD Workflow Diagram
4. Kubernetes Management Cluster Diagram
5. Kubernetes Application Cluster Diagram
6. PostgreSQL HA Diagram
7. MinIO / S3 Storage Diagram
8. Network VLAN and Firewall Diagram
9. Ansible Automation Architecture Diagram
10. Multipass Local Testing Architecture
11. VMware Production Deployment Architecture
12. Backup and Disaster Recovery Diagram

Draw.io files must be editable using diagrams.net.

Every diagram must clearly show which services run:

- Outside Kubernetes
- Inside the management Kubernetes cluster
- Inside the application Kubernetes cluster

Do not group everything into one Kubernetes box.

Show network boundaries and communication paths.

---

## 11. Resource Planning

Produce a VM sizing proposal with:

- Hostname
- Purpose
- CPU
- RAM
- OS disk
- Data disk
- VLAN
- Example IP address
- HA requirements
- Backup requirements

Separate resource planning for:

- DevOps services
- Management Kubernetes cluster
- Application Kubernetes cluster
- Database HA
- S3 / MinIO
- Monitoring and logging
- Backup infrastructure

Provide minimum and recommended sizing.

Clearly state that the sizing is an initial proposal and must be validated against actual application load, retention, storage capacity, VMware resources, and expected growth.

---

## 12. Implementation and Validation

Work in phases.

**Phase 1: Architecture review**

- Inspect the existing repository.
- Review existing architecture and diagrams.
- Identify components that must be moved outside the application cluster.
- Identify missing services and dependencies.
- Produce the updated architecture.
- Produce the updated VM and network plans.

**Phase 2: Ansible foundation**

- Update directory structure.
- Update inventories.
- Build common roles.
- Validate local and production inventory separation.

**Phase 3: Infrastructure services**

- Deploy GitLab.
- Deploy Jenkins and agents.
- Deploy Nexus.
- Deploy PostgreSQL HA.
- Deploy MinIO.
- Deploy Redis.
- Deploy monitoring.

**Phase 4: Kubernetes**

- Deploy the management cluster.
- Install Rancher and Argo CD.
- Deploy the application cluster.
- Configure cluster networking and ingress.
- Register and connect the application cluster.

**Phase 5: CI/CD and GitOps**

- Configure GitLab webhooks.
- Configure Jenkins pipelines.
- Build and push images to Nexus.
- Update GitOps repositories.
- Configure Argo CD deployment.
- Validate application deployment and rollback.

**Phase 6: Security and operations**

- Configure firewall rules.
- Configure TLS and secrets.
- Configure backup and recovery.
- Configure monitoring and alerts.
- Perform failure and recovery tests.
- Document operational procedures.

For every phase, provide:

- Objective
- Files to create or update
- Ansible playbooks to execute
- Commands to run
- Expected results
- Validation checks
- Rollback procedure

---

## 13. Strict Technical Rules

1. Do not put business databases or storage inside the application Kubernetes cluster.
2. Do not put DevOps tools inside the application Kubernetes cluster.
3. Do not deploy Argo CD or Rancher in the application Kubernetes cluster.
4. Use a dedicated management Kubernetes cluster for Argo CD and Rancher.
5. Keep monitoring and backup infrastructure independent.
6. Do not assume that a single VM provides HA.
7. Do not assume that Kubernetes replicas provide database HA.
8. Do not expose internal infrastructure services to the public Internet.
9. Do not hardcode production IP addresses or passwords.
10. Do not introduce unnecessary technologies.
11. Use official documentation to verify current installation methods and compatibility.
12. Pin software versions and document upgrade procedures.
13. Reuse existing Ansible roles where possible.
14. Preserve working existing configuration unless a change is required.
15. Clearly identify any architectural trade-offs or unsupported configurations.

## 14. First Task

Before modifying files, inspect the existing project and provide:

1. Updated high-level architecture.
2. Updated infrastructure topology.
3. Updated component deployment location.
4. Proposed VM sizing.
5. Proposed VLAN and IP plan.
6. Updated Ansible project structure.
7. Updated Multipass testing strategy.
8. Production deployment strategy.
9. Migration plan from the old architecture to the new architecture.
10. Risks, dependencies, and missing information.

After presenting the architecture and migration plan, proceed with implementation in phases. Preserve existing work, explain every important change, and validate the result.

The final goal is a production-ready, maintainable, secure, and repeatable on-premises DevOps platform using VMware, Ubuntu 24.04, Ansible, Multipass, GitLab, Jenkins, Nexus, Rancher, Argo CD, Kubernetes, PostgreSQL HA, MinIO, Redis, Prometheus, Grafana, and Loki.