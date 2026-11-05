# Docker Lab Environment (3-Layer DevOps Architecture)

This directory provides a lightweight, local testing environment using **Docker Compose** and **KinD (Kubernetes-in-Docker)**.

All services are configured to use **latest multi-architecture images** (native `arm64` on Apple Silicon Macs and `amd64` on Linux/Intel), preventing emulation overhead while **strictly honoring the core architecture principle**:

> **Rule:** The Kubernetes application cluster runs business applications only. All DevOps tools, stateful databases, object storage, and observability stacks run independently outside the application cluster.

---

## 1. Architectural Topology

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      DOCKER BRIDGE NETWORK (devops-net)               │
 │                                                                        │
 │  [Layer 1: External Services via Docker Compose]                       │
 │  ├── gitlab          (latest)           ─ Source Control & Webhooks    │
 │  ├── jenkins         (lts-jdk21)        ─ CI Engine (DinD / Agent)     │
 │  ├── nexus           (latest)           ─ Docker Registry & Artifacts  │
 │  ├── sonarqube       (community)        ─ Static Code Analysis         │
 │  ├── garage          (v1.1.0)           ─ S3-Compatible Object Storage │
 │  ├── postgres + redis (17 & latest)     ─ Database & Caching           │
 │  └── prometheus + grafana + loki (latest) Observability Stack          │
 │                                                                        │
 │  [Layer 2: KinD Management Cluster]                                    │
 │  └── k8s-mgmt-control-plane (Rancher v2.10.1 + Argo CD v2.13.2)       │
 │                                                                        │
 │  [Layer 3: KinD Application Cluster]                                   │
 │  ├── k8s-app-control-plane                                             │
 │  └── k8s-app-worker (Business applications only, synced by Argo CD)   │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Resource Profiles

To accommodate different developer workstation capabilities, services are divided into Compose profiles:

| Profile | Included Services | Est. RAM | Best For |
| :--- | :--- | :--- | :--- |
| `core` *(Default)* | PostgreSQL, Redis, GitLab, Jenkins, Nexus, Garage | ~6–8 GB | CI/CD build & push workflows |
| `quality` | `core` + SonarQube | ~8–10 GB | Adding static analysis scanning |
| `monitoring` | `core` + Prometheus, Grafana, Loki, Promtail | ~8–10 GB | Observability and log testing |
| `all` | Full Layer 1 external stack | ~10–12 GB | Full local integration testing |

---

## 3. Quickstart

### Prerequisites
- Docker Engine & Docker Compose v2 (`docker compose version`)
- *(Optional, for K8s layers)* KinD (`brew install kind`) & `kubectl` (`brew install kubectl`)

### 3.1 Start Layer 1 Services
```bash
# Run Core profile (GitLab, Jenkins, Nexus, Garage, DBs)
./setup-lab.sh --profile core

# Or run the full stack
./setup-lab.sh --profile all
```

### 3.2 Start with Kubernetes Management & Application Clusters (KinD)
```bash
./setup-lab.sh --profile core --with-k8s
```

### 3.3 Validate Configuration without Starting (Dry Run)
```bash
./setup-lab.sh --profile all --dry-run
```

---

## 4. Endpoints & Default Credentials

> **Note on Port Allocations:** Non-standard host ports are mapped to avoid collisions with local web servers (nginx on port 80), local database services (gvproxy/postgres on 5432-5434), and macOS AirPlay Receiver (port 5000). Inside the internal `devops-net` network, standard ports (`5432`, `6379`, `8081`, `3900`) are maintained.

| Service | Container Image Tag | Host Port | Internal Docker URL | Default Credentials |
| :--- | :--- | :--- | :--- | :--- |
| **GitLab CE** | `gitlab/gitlab-ce:latest` | `http://localhost:8082` | `http://gitlab:80` | `root` / `ChangeMeGitlab123!` |
| **GitLab SSH** | `gitlab/gitlab-ce:latest` | `localhost:2222` | `gitlab:22` | Configured per user SSH key |
| **Jenkins** | `jenkins/jenkins:lts-jdk21` | `http://localhost:8080` | `http://jenkins:8080` | `docker exec devops-jenkins cat /var/jenkins_home/secrets/initialAdminPassword` |
| **Nexus OSS** | `sonatype/nexus3:latest` | `http://localhost:8085` | `http://nexus:8081` | `admin` / `docker exec devops-nexus cat /nexus-data/admin.password` |
| **Nexus Hosted Registry** | `sonatype/nexus3:latest` | `localhost:5002` | `nexus:5000` | Same as Nexus admin |
| **Nexus Group Registry** | `sonatype/nexus3:latest` | `localhost:5003` | `nexus:5001` | Pull-through caching |
| **Garage S3 API** | `dxflrs/garage:v1.1.0` | `http://localhost:3900` | `http://garage:3900` | Key: `devops-key` (Bucket: `devops-artifacts`) |
| **Garage Admin API** | `dxflrs/garage:v1.1.0` | `http://localhost:3903` | `http://garage:3903` | Token: `ChangeMeAdminToken1234567890` |
| **Garage S3 Web** | `dxflrs/garage:v1.1.0` | `http://localhost:3902` | `http://garage:3902` | Static web serving for buckets |
| **SonarQube** | `sonarqube:community` | `http://localhost:9002` | `http://sonarqube:9000` | `admin` / `admin` |
| **PostgreSQL 17** | `postgres:17-alpine` | `localhost:5435` | `postgres:5432` | `postgres` / `ChangeMePostgres123!` |
| **Redis** | `redis:alpine` | `localhost:6381` | `redis:6379` | *(No password)* |
| **Prometheus** | `prom/prometheus:latest` | `http://localhost:9090` | `http://prometheus:9090` | *(Open)* |
| **Grafana** | `grafana/grafana-oss:latest` | `http://localhost:3000` | `http://grafana:3000` | `admin` / `ChangeMeGrafana123!` |
| **Argo CD (KinD)** | *(via KinD)* | `https://localhost:30443` | `https://127.0.0.1:30443` | `admin` / (Initial K8s secret) |
| **App Ingress (KinD)** | *(via KinD)* | `http://localhost:8088` | `http://127.0.0.1:8088` | Route based on Host header |

---

## 5. Teardown

```bash
# Stop all containers, keep persistent volumes
./destroy-lab.sh

# Complete reset (wipes all database and storage volumes)
./destroy-lab.sh --volumes
```
