# Layer 3: Application Kubernetes Cluster Manifests (`kubernetes/application-cluster/`)

This directory contains manifests for the **Layer 3 Application Kubernetes Cluster (`k8s_app_cluster`)**, which hosts **business applications only** (Frontends, Backend APIs, Laravel, Node.js, Microservices, Background Workers, CronJobs, and Application Ingress).

## Enforced Production Policies
1. **No Infrastructure Services Allowed:** GitLab, Jenkins, Nexus, MinIO, PostgreSQL, Redis, Prometheus, Grafana, Loki, Rancher, and Argo CD never run in this cluster.
2. **PodDisruptionBudgets (PDBs), NetworkPolicies & Anti-Affinity:** All business workloads enforce `minAvailable: 1` PDBs, default-deny Calico `NetworkPolicy` with explicit egress to Layer 1 PostgreSQL (`:5432`), Redis (`:6379`), and MinIO (`:9000`), and `podAntiAffinity` across worker nodes.

