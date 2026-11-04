# Platform Networking & Firewall Architecture

## 1. IP Addressing & CIDR Allocation

| Network Layer | Local Multipass | Production VMware | Protocol / Purpose |
| :--- | :--- | :--- | :--- |
| **Management Network** | `192.168.0.0/16` (Dynamic DHCP bridge, e.g. `192.168.252.0/24` or `192.168.64.0/24`) | `10.20.10.0/24` (DevOps) / `10.20.20.0/24` (K8s) | Host-to-host SSH, HTTP/HTTPS, API traffic |
| **Kubernetes Pod CIDR** | `10.244.0.0/16` | `10.244.0.0/16` | Calico pod overlay network |
| **Kubernetes Service CIDR** | `10.96.0.0/12` | `10.96.0.0/12` | Kubernetes `ClusterIP` virtual network |
| **CoreDNS Service IP** | `10.96.0.10` | `10.96.0.10` | Internal cluster service discovery |

---

## 2. Firewall Matrix (UFW + Calico)

| Target Node Group | TCP Ports | UDP Ports | Source | Description |
| :--- | :--- | :--- | :--- | :--- |
| **All Nodes (`common`)** | `22` | `123` (outbound) | Management Subnet | OpenSSH & Chrony NTP |
| **GitLab (`gitlab`)** | `80, 443, 2222` | - | Workstation / CI / K8s | Web UI, HTTPS, Git SSH |
| **Jenkins (`jenkins`)** | `8080, 443, 50000` | - | GitLab / Agents | Web UI, Webhook receiver, JNLP agents |
| **Nexus (`nexus`)** | `8081, 5000, 5001` | - | Jenkins / K8s Nodes | Nexus UI, Docker Hosted (`5000`), Docker Group (`5001`) |
| **MinIO (`minio`)** | `9000, 9001` | - | Loki / Backup hosts | S3 API (`9000`) & Console (`9001`) |
| **Rancher (`rancher`)** | `80, 443` | - | Admin / K8s Nodes | Rancher UI & cluster agent tunnel |
| **K8s Control Plane** | `6443, 2379-2380, 10250, 10257, 10259, 179` | `4789` | K8s Cluster / Rancher | API Server, etcd, kubelet, Calico BGP/VXLAN |
| **K8s Workers** | `80, 443, 10250, 179, 30000-32767` | `4789` | Ingress / Control Plane | Ingress HTTP/S, kubelet, Calico, NodePort |
| **Monitoring (`monitoring`)** | `9090, 9093, 3000, 3100` | - | All Nodes / Admins | Prometheus, Alertmanager, Grafana, Loki |

---

## 3. Kernel Networking Parameters (`99-devops-sysctl.conf`)

Applied automatically on all nodes via `roles/common`:
- `net.ipv4.ip_forward = 1` (Required for Kubernetes Service routing and Calico CNI)
- `net.bridge.bridge-nf-call-iptables = 1`
- `net.bridge.bridge-nf-call-ip6tables = 1`
- `fs.inotify.max_user_watches = 524288` (Required for Promtail/Loki and K8s kubelet log watchers)
- `vm.max_map_count = 262144` (Required for SonarQube / OpenSearch)

