# Production VMware vSphere Manual Installation Guide (`PRODUCTION-VMWARE-GUIDE.md`)

This guide walks through deploying the **3-Layer On-Premises DevOps Platform** onto manually provisioned **Ubuntu Server 24.04 LTS** virtual machines in **VMware vSphere / ESXi** across **VLANs 10–80** using [`manual-install/production.env`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/production.env) and [`manual-install/devops-cli.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/devops-cli.sh).

---

## 1. Production 3-Layer Server & VLAN Matrix (`production.env`)

| Layer | VLAN | Hostname(s) | Static IP(s) | vCPU / RAM / Disk | Target Module(s) in `manual-install/` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Layer 1** | `VLAN 10` (`Mgmt`) | `prod-secops-01` | `10.20.10.16` | `4 vCPU / 8 GB / 160 GB` | `common`, `vault` |
| **Layer 1** | `VLAN 20` (`DevOps`) | `prod-gitlab-01` | `10.20.20.10` | `8 vCPU / 16 GB / 330 GB` | `common`, `gitlab` |
| **Layer 1** | `VLAN 20` (`DevOps`) | `prod-jenkins-01` | `10.20.20.11` | `4 vCPU / 8 GB / 160 GB` | `common`, `jenkins` |
| **Layer 1** | `VLAN 20` (`DevOps`) | `prod-jenkins-agent01..02` | `10.20.20.12..13` | `8 vCPU / 16 GB / 180 GB` ea | `common`, `jenkins-agent` |
| **Layer 1** | `VLAN 20` (`DevOps`) | `prod-nexus-01` | `10.20.20.14` | `8 vCPU / 16 GB / 560 GB` | `common`, `nexus` |
| **Layer 1** | `VLAN 50` (`Database`) | `pg-lb1`, `pg-lb2` | `10.20.50.8..9` (VIP `.10`) | `2 vCPU / 4 GB / 60 GB` ea | `common`, `postgresql-ha` (HAProxy + Keepalived) |
| **Layer 1** | `VLAN 50` (`Database`) | `pg-db1`, `pg-db2`, `pg-db3` | `10.20.50.11..13` | `8 vCPU / 32 GB / 460 GB` ea | `common`, `postgresql-ha` (Patroni + etcd + PG 16 + `pgBackRest`) |
| **Layer 1** | `VLAN 50` (`Database`) | `prod-redis-01..03` | `10.20.50.21..23` | `4 vCPU / 8 GB / 100 GB` ea | `common`, `redis` |
| **Layer 1** | `VLAN 60` (`Storage`) | `prod-minio-01..04` | `10.20.60.11..14` (VIP `.10`) | `8 vCPU / 16 GB / 2×500 GB` ea | `common`, `minio` |
| **Layer 1** | `VLAN 70` (`Monitoring`) | `prod-monitor-01` | `10.20.70.10` | `8 vCPU / 16 GB / 360 GB` | `common`, `monitoring`, `logging` |
| **Layer 1** | `VLAN 80` (`Backup`) | `prod-backup-01` | `10.20.80.10` | `4 vCPU / 8 GB / 1060 GB` | `common` + `pgBackRest` repository |
| **Layer 2** | `VLAN 30` (`K8s-Mgmt`) | `prod-k8s-mgmt-cp01..03` | `10.20.30.11..13` (VIP `.10`) | `4 vCPU / 8 GB / 140 GB` ea | `common`, `kubernetes-mgmt` (**Argo CD**), `rancher` |
| **Layer 3** | `VLAN 40` (`K8s-App`) | `prod-k8s-cp01..03` | `10.20.40.11..13` (VIP `.10`) | `4 vCPU / 8 GB / 140 GB` ea | `common`, `kubernetes-cp` (App Cluster Control Plane) |
| **Layer 3** | `VLAN 40` (`K8s-App`) | `prod-k8s-worker01..03` | `10.20.40.21..23` (VIP `.20`) | `8 vCPU / 32 GB / 280 GB` ea | `common`, `kubernetes-worker` (App Cluster Workers) |

---

## 2. Step 1: Prepare Production Bastion & Configure `production.env`

1. On your **Ansible / Operations Bastion (`10.20.10.5` in `VLAN 10`)**, clone this repository and install all operator client CLIs (`kubectl`, `helm`, `argocd`, `rancher`, `calicoctl`, `glab`, `mc`, `logcli`, `trivy`, `vault`, `psql`, `redis-cli`):
   ```bash
   ./manual-install/devops-cli.sh --env production install-clis
   ```
2. Edit [`manual-install/production.env`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/production.env) to set your corporate domain, VLAN IP addresses, and strong production passwords, then verify:
   ```bash
   ./manual-install/devops-cli.sh --env production list
   ```

---

## 3. Step 2: Run Common Baseline on All Production VMs

```bash
for ip in \
  10.20.10.16 \
  10.20.20.{10..14} \
  10.20.30.{11..13} \
  10.20.40.{11..13} 10.20.40.{21..23} \
  10.20.50.{8..9} 10.20.50.{11..13} 10.20.50.{21..23} \
  10.20.60.{11..14} \
  10.20.70.10 10.20.80.10; do
  ./manual-install/devops-cli.sh --env production remote-install common "ansible@${ip}"
done
```

---

## 4. Step 3: Deploy Layer 1 Infrastructure Services (Outside Kubernetes)

### 4.1 Deploy GitLab, Jenkins Controller, Jenkins Agents & Nexus (`VLAN 20`)
```bash
./manual-install/devops-cli.sh --env production remote-install gitlab        ansible@10.20.20.10
./manual-install/devops-cli.sh --env production remote-install jenkins       ansible@10.20.20.11
./manual-install/devops-cli.sh --env production remote-install jenkins-agent ansible@10.20.20.12
./manual-install/devops-cli.sh --env production remote-install jenkins-agent ansible@10.20.20.13
./manual-install/devops-cli.sh --env production remote-install nexus         ansible@10.20.20.14
```

### 4.2 Deploy 5-VM PostgreSQL 16 HA Cluster & Redis (`VLAN 50`)
> See [`manual-install/postgresql-ha/README.md`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/postgresql-ha/README.md) for the full `pg-lb1..2` (HAProxy + Keepalived VIP `10.20.50.10`) and `pg-db1..3` (Patroni + etcd + `pgBackRest`) configuration.

```bash
# Install HA Load Balancers (pg-lb1 MASTER, pg-lb2 BACKUP for VIP 10.20.50.10)
./manual-install/devops-cli.sh --env production remote-install postgresql-ha ansible@10.20.50.8
./manual-install/devops-cli.sh --env production remote-install postgresql-ha ansible@10.20.50.9

# Install 3-Node PostgreSQL 16 HA Cluster (pg-db1 Leader, pg-db2 Sync Standby, pg-db3 Async Replica)
./manual-install/devops-cli.sh --env production remote-install postgresql-ha ansible@10.20.50.11
./manual-install/devops-cli.sh --env production remote-install postgresql-ha ansible@10.20.50.12
./manual-install/devops-cli.sh --env production remote-install postgresql-ha ansible@10.20.50.13

# Install Redis Cache & Sentinel Cluster (prod-redis-01..03)
for ip in 10.20.50.{21..23}; do
  ./manual-install/devops-cli.sh --env production remote-install redis "ansible@${ip}"
done
```

### 4.3 Deploy Distributed MinIO S3 (`VLAN 60`), Monitoring (`VLAN 70`) & Vault (`VLAN 10`)
```bash
# 4-Node Distributed MinIO S3 Cluster
for ip in 10.20.60.{11..14}; do
  ./manual-install/devops-cli.sh --env production remote-install minio "ansible@${ip}"
done

# Independent Monitoring & Logging Server (Prometheus + Grafana + Loki)
./manual-install/devops-cli.sh --env production remote-install monitoring ansible@10.20.70.10
./manual-install/devops-cli.sh --env production remote-install logging    ansible@10.20.70.10

# HashiCorp Vault Server
./manual-install/devops-cli.sh --env production remote-install vault      ansible@10.20.10.16
```

---

## 5. Step 4: Deploy Layer 2 Dedicated Management Kubernetes Cluster (`VLAN 30`)

Hosts **Rancher (`v2.10.1`)** and **Argo CD (`v2.13.2`)** only — completely independent of the Application Cluster:
```bash
# Initialize Primary Management Control Plane (with Calico + Argo CD) and Rancher
./manual-install/devops-cli.sh --env production remote-install kubernetes-mgmt ansible@10.20.30.11
./manual-install/devops-cli.sh --env production remote-install rancher         ansible@10.20.30.11

# Join prod-k8s-mgmt-cp02 and prod-k8s-mgmt-cp03 (see manual-install/kubernetes-mgmt/README.md)
```

---

## 6. Step 5: Deploy Layer 3 Application Kubernetes Cluster (`VLAN 40`)

Hosts **business applications only**:
```bash
# 1. Initialize Primary Application Control Plane (prod-k8s-cp01)
./manual-install/devops-cli.sh --env production remote-install kubernetes-cp     ansible@10.20.40.11

# 2. Install Worker Node prerequisites on prod-k8s-worker01..03 and join them via 'kubeadm join'
for ip in 10.20.40.{21..23}; do
  ./manual-install/devops-cli.sh --env production remote-install kubernetes-worker "ansible@${ip}"
done

# 3. Register the Layer 3 Application Cluster in Layer 2 Argo CD (on prod-k8s-mgmt-cp01):
# argocd cluster add kubernetes-admin@onprem-prod-app-k8s --name app-cluster-production --yes
```

---

## 7. Step 6: End-to-End Production Verification

From your Bastion host, verify all Layer 1, Layer 2, and Layer 3 endpoints:
```bash
./manual-install/devops-cli.sh --env production status
```

