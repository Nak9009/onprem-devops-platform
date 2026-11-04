# Layer 2: Dedicated Kubernetes Management Cluster (`kubernetes-mgmt`)

- **Target Host(s):** `k8s-mgmt-cp01` (local) or `prod-k8s-mgmt-cp01..03` (`10.20.30.11..13`, VIP `10.20.30.10`, `VLAN 30`)
- **Responsibility:** Hosts **Rancher (`v2.10.1`)** and **Argo CD (`v2.13.2`)** in a dedicated Management Kubernetes Cluster completely independent of the Layer 3 Application Cluster.
- **Installed CLIs:** `kubeadm`, `kubectl`, `calicoctl`, `argocd`, `rancher`
- **Automated Script:** [`manual-install/kubernetes-mgmt/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-mgmt/install.sh)

---

## 1. Initialize Layer 2 Management Cluster (`Pod CIDR 10.243.0.0/16`)

Run [`manual-install/kubernetes-mgmt/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/kubernetes-mgmt/install.sh) to deploy `containerd`, `kubeadm` (`1.31.4-1.1`), Calico (`v3.29.1`), and **Argo CD (`v2.13.2`)** with non-overlapping Management Cluster CIDRs (`10.243.0.0/16` Pod CIDR and `10.95.0.0/12` Service CIDR).

---

## 2. Connect Management Cluster Argo CD to Layer 3 Application Cluster

Once both the **Layer 2 Management Cluster** (`VLAN 30`) and **Layer 3 Application Cluster** (`VLAN 40`) are running:

```bash
# 1. Copy the Application Cluster's kubeconfig context onto k8s-mgmt-cp01
scp ansible@10.20.40.11:/etc/kubernetes/admin.conf /tmp/app-cluster.kubeconfig

# 2. Log into Argo CD running on the Management Cluster
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd login 127.0.0.1:30443 --username admin --password "${ARGOCD_PASS}" --insecure

# 3. Register the Layer 3 Application Cluster as a deployment target
KUBECONFIG=/tmp/app-cluster.kubeconfig argocd cluster add kubernetes-admin@onprem-prod-app-k8s \
  --name app-cluster-production --yes

# 4. Verify registered clusters in Argo CD
argocd cluster list
```

