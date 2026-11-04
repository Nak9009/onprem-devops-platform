# Platform Architecture Overview

## 1. Executive Summary

The On-Premises DevOps Platform provides a unified, self-hosted software delivery and Kubernetes operations environment built on **Ubuntu Server 24.04 LTS** (`noble`). It supports two deployment targets from a single codebase:

1. **Local Testing Environment:** Automated VM provisioning on a developer workstation via **Multipass** (`multipass/create-vms.sh`) and **Ansible** (`inventories/local/hosts.yml`).
2. **Production Environment:** Manually provisioned **VMware vSphere / ESXi** virtual machines configured with the exact same **Ansible** roles (`inventories/production/hosts.yml`) and documented step-by-step runbooks.

---

## 2. End-to-End CI/CD & GitOps Data Flow

```mermaid
flowchart TD
    Dev["Developer Workstation"] -->|"1. git push"| GitLab["GitLab CE (17.7.1)"]
    GitLab -->|"2. Push/MR Webhook"| Jenkins["Jenkins LTS (2.479.3)"]
    subgraph CI["Jenkins Continuous Integration Pipeline"]
        S1["Checkout & Immutable Tagging"] --> S2["Unit Tests (JUnit)"]
        S2 --> S3["SonarQube Code Quality (10.8.1)"]
        S3 --> S4["Trivy FS Scan (0.58.1)"]
        S4 --> S5["Rootless Buildah Container Build"]
        S5 --> S6["Trivy Container Image Scan"]
    end
    Jenkins --> S1
    S6 -->|"3. Push Immutable Tags"| Nexus["Sonatype Nexus (3.75.1)<br/>Docker Registry :5000"]
    S6 -->|"4. Update Overlay newTag"| GitOpsRepo["GitLab GitOps Repository<br/>(dev / staging / production)"]
    GitOpsRepo -->|"5. Poll / Webhook"| ArgoCD["Argo CD (v2.13.2)"]
    subgraph K8s["Kubernetes Cluster (kubeadm v1.31.4 + containerd + Calico v3.29.1)"]
        ArgoCD -->|"Auto-Sync"| DevNS["Namespace: dev"]
        ArgoCD -->|"Auto-Sync"| StageNS["Namespace: staging"]
        ArgoCD -->|"Manual Approval Gate"| ProdNS["Namespace: production"]
    end
    Nexus -->|"6. Pull Verified Image"| K8s
    Rancher["Rancher Server (v2.10.1)"] -->|"Cluster Lifecycle & RBAC"| K8s
    K8s -->|"Metrics"| Prom["Prometheus (2.53.3) & Grafana (11.4.0)"]
    K8s -->|"Logs"| Loki["Promtail & Loki (3.3.2)"]
    Loki -->|"S3 Chunks"| MinIO["MinIO Object Storage"]
    ProdNS -->|"TCP 5432"| ExtDB["Dedicated External PostgreSQL VM"]
```

---

## 3. Key Architectural Decisions

1. **Strict Separation of CI and CD:**
   - **Jenkins** executes builds, tests, static analysis, vulnerability scans, image pushes to Nexus, and commits the new immutable image tag to the GitOps repository.
   - **Jenkins never holds Kubernetes cluster-admin credentials** and never executes `kubectl apply` against the cluster.
   - **Argo CD** reconciles cluster state from Git, ensuring full auditability and drift detection.
2. **Rootless Container Builds in CI:**
   - Exposing `/var/run/docker.sock` to CI jobs grants root-equivalent host privileges. Instead, `roles/jenkins` provisions rootless **Podman / Buildah** with user namespace UID/GID mappings (`/etc/subuid` and `/etc/subgid`).
3. **Immutable Image Tagging Policy:**
   - Every build generates three immutable tags (`<semver>-<git-sha>`, `sha-<git-sha>`, `build-<number>`). Both Jenkins (`updateGitOpsRepo.groovy`) and the rollback utility (`scripts/gitops-rollback.sh`) reject the mutable `latest` tag.
4. **Externalized Stateful Production Databases:**
   - Production PostgreSQL databases reside on dedicated VMware VMs (`prod-postgres-01`) outside Kubernetes to isolate disk I/O, simplify PITR (`pgBackRest`), and avoid CNI/CSI overhead on transactional workloads.
5. **Single Codebase Across Local and Production:**
   - Environment differences (domain names, replica counts, JVM heap sizes, VIP endpoints) are parameterized in `inventories/local/group_vars/all.yml` and `inventories/production/group_vars/all.yml`.

