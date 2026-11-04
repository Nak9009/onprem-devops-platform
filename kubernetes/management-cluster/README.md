# Layer 2: Management Kubernetes Cluster Manifests (`kubernetes/management-cluster/`)

This directory contains manifests deployed **exclusively to the Layer 2 Management Kubernetes Cluster (`k8s_mgmt_cluster`)**, which hosts:
- **Rancher (`v2.10.1`):** Multi-cluster Kubernetes management
- **Argo CD (`v2.13.2`):** GitOps continuous delivery controller

## Registering the Downstream Application Cluster in Argo CD

After initializing the **Layer 3 Application Kubernetes Cluster (`k8s_app_cluster`)**, register its API endpoint (`https://10.20.40.10:8443` or local `https://192.168.252.24:6443`) in Argo CD running on the Management Cluster:

```bash
# On the Management Cluster node (using argocd CLI):
argocd login 127.0.0.1:30443 --username admin --password "<ARGOCD_ADMIN_PASS>" --insecure
argocd cluster add kubernetes-admin@onprem-prod-app-k8s --name app-cluster-prod --yes
argocd cluster list
```

