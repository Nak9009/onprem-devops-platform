#!/usr/bin/env python3
"""
Generates all 12 editable Draw.io (*.drawio) architecture diagrams in docs/diagrams/
conforming to Section 10 of Update On-Premises DevOps Architecture.md.
Every diagram explicitly separates:
  - Layer 1: Outside Kubernetes (Dedicated VMs, Databases, Storage, Monitoring, Backup)
  - Layer 2: Management Kubernetes Cluster (Rancher + Argo CD)
  - Layer 3: Application Kubernetes Cluster (Business Workloads Only)
"""
import os
import html

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "diagrams")
os.makedirs(OUT_DIR, exist_ok=True)


def build_drawio(title: str, containers: list, nodes: list, edges: list) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<mxfile host="app.diagrams.net" modified="2026-11-04T15:30:00.000Z" agent="OnPrem-DevOps-Architect" version="24.7.0" type="device">',
        f'  <diagram id="{html.escape(title.lower().replace(" ", "-"))}" name="{html.escape(title)}">',
        '    <mxGraphModel dx="1422" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1600" pageHeight="1100" math="0" shadow="0">',
        '      <root>',
        '        <mxCell id="0" />',
        '        <mxCell id="1" parent="0" />',
    ]

    # Title banner
    lines.append(
        f'        <mxCell id="title" value="{html.escape(title)}" '
        'style="rounded=1;whiteSpace=wrap;html=1;fillColor=#1a365d;strokeColor=#0f172a;fontColor=#ffffff;fontSize=16;fontStyle=1;" '
        'vertex="1" parent="1"><mxGeometry x="40" y="20" width="1480" height="45" as="geometry" /></mxCell>'
    )

    for cid, label, x, y, w, h, fill, stroke in containers:
        lines.append(
            f'        <mxCell id="{cid}" value="{html.escape(label)}" '
            f'style="swimlane;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};startSize=32;fontStyle=1;fontSize=13;rounded=1;" '
            f'vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry" /></mxCell>'
        )

    for nid, parent, label, x, y, w, h, fill, stroke in nodes:
        lines.append(
            f'        <mxCell id="{nid}" value="{html.escape(label)}" '
            f'style="rounded=1;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};fontSize=11;fontStyle=0;" '
            f'vertex="1" parent="{parent}"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry" /></mxCell>'
        )

    for idx, (src, dst, elabel) in enumerate(edges, start=1):
        lines.append(
            f'        <mxCell id="e{idx}" value="{html.escape(elabel)}" '
            'style="edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeWidth=2;strokeColor=#334155;fontSize=10;" '
            f'edge="1" parent="1" source="{src}" target="{dst}"><mxGeometry relative="1" as="geometry" /></mxCell>'
        )

    lines.extend([
        '      </root>',
        '    </mxGraphModel>',
        '  </diagram>',
        '</mxfile>',
    ])
    return "\n".join(lines) + "\n"


COMMON_CONTAINERS = [
    ("layer1_devops", "Layer 1A: DevOps Services Outside K8s (VLAN 20: 10.20.20.0/24)", 40, 85, 720, 260, "#dae8fc", "#6c8ebf"),
    ("layer1_data", "Layer 1B: External Databases, Storage, Monitoring & Backup (VLANs 50/60/70/80)", 800, 85, 720, 260, "#fff2cc", "#d6b656"),
    ("layer2_mgmt", "Layer 2: Dedicated Kubernetes Management Cluster (VLAN 30: 10.20.30.0/24)", 40, 380, 720, 280, "#e1d5e7", "#9673a6"),
    ("layer3_app", "Layer 3: Application Kubernetes Cluster - Business Apps Only (VLAN 40: 10.20.40.0/24)", 800, 380, 720, 280, "#d5e8d4", "#82b366"),
]

COMMON_NODES = [
    ("gitlab", "layer1_devops", "GitLab CE 17.7.1\nDedicated VM (prod-gitlab-01)\n10.20.20.10", 25, 55, 200, 75, "#ffffff", "#6c8ebf"),
    ("jenkins", "layer1_devops", "Jenkins Controller 2.479.3\nDedicated VM (prod-jenkins-01)\n10.20.20.11", 255, 55, 200, 75, "#ffffff", "#6c8ebf"),
    ("jagent", "layer1_devops", "Jenkins Build Agents\nRootless Buildah + Trivy\n10.20.20.12-13", 485, 55, 200, 75, "#ffffff", "#6c8ebf"),
    ("nexus", "layer1_devops", "Sonatype Nexus 3.75.1\nDocker & Artifact Registry\n10.20.20.14 (:8081/:5000)", 255, 155, 200, 75, "#ffffff", "#6c8ebf"),
    ("pg_ha", "layer1_data", "PostgreSQL 16 HA (VLAN 50)\npg-db1 (Leader) | pg-db2 (Sync) | pg-db3 (Async)\nPatroni + etcd + HAProxy VIP 10.20.50.10", 25, 55, 320, 80, "#ffffff", "#d6b656"),
    ("redis", "layer1_data", "Redis 7.4 Cache/Queues\nDedicated VMs (VLAN 50)\n10.20.50.21-23", 375, 55, 315, 80, "#ffffff", "#d6b656"),
    ("minio", "layer1_data", "MinIO S3 Storage (VLAN 60)\n4-Node Distributed Erasure Coding\nVIP 10.20.60.10:9000", 25, 155, 210, 80, "#ffffff", "#d6b656"),
    ("monitor", "layer1_data", "Prometheus + Grafana + Loki\nIndependent Monitoring (VLAN 70)\n10.20.70.10", 255, 155, 210, 80, "#ffffff", "#d6b656"),
    ("backup", "layer1_data", "Backup Server (VLAN 80)\npgBackRest + Restic + Snapshots\n10.20.80.10", 485, 155, 205, 80, "#ffffff", "#d6b656"),
    ("mgmt_cp", "layer2_mgmt", "Management K8s Control Plane\nprod-k8s-mgmt-cp01..03\nVIP 10.20.30.10:8443", 25, 60, 210, 180, "#ffffff", "#9673a6"),
    ("rancher", "layer2_mgmt", "Rancher Server v2.10.1\nMulti-Cluster Management\n(Runs in Mgmt K8s Cluster)", 260, 60, 210, 180, "#ffffff", "#9673a6"),
    ("argocd", "layer2_mgmt", "Argo CD v2.13.2\nGitOps CD Controller\n(Runs in Mgmt K8s Cluster)", 490, 60, 205, 180, "#ffffff", "#9673a6"),
    ("app_cp", "layer3_app", "App K8s Control Plane (3 Nodes)\nprod-k8s-app-cp01..03\nAPI VIP 10.20.40.10:8443", 25, 60, 210, 180, "#ffffff", "#82b366"),
    ("app_wk", "layer3_app", "App K8s Workers (3+ Nodes)\nCalico CNI + Ingress NGINX\nIngress VIP 10.20.40.20", 255, 60, 210, 180, "#ffffff", "#82b366"),
    ("biz_apps", "layer3_app", "Business Workloads ONLY:\nFrontend, Backend APIs, Laravel,\nNode.js, Microservices, Workers", 485, 60, 210, 180, "#ffffff", "#82b366"),
]

COMMON_EDGES = [
    ("gitlab", "jenkins", "1. Webhook"),
    ("jenkins", "jagent", "2. Dispatch CI"),
    ("jagent", "nexus", "3. Push OCI Image"),
    ("jagent", "gitlab", "4. Update GitOps Tag"),
    ("argocd", "gitlab", "5. Poll GitOps Repo"),
    ("argocd", "app_cp", "6. Deploy to App Cluster"),
    ("rancher", "app_cp", "Manage App Cluster"),
    ("app_wk", "nexus", "7. Pull Image"),
    ("biz_apps", "pg_ha", "TCP 5432 (VIP)"),
    ("biz_apps", "redis", "TCP 6379"),
    ("biz_apps", "minio", "HTTPS 9000 (S3)"),
    ("monitor", "app_wk", "Scrape Metrics/Logs"),
    ("backup", "pg_ha", "pgBackRest WAL/PITR"),
]

DIAGRAMS = [
    ("01-high-level-architecture.drawio", "01. High-Level 3-Layer On-Premises DevOps Architecture"),
    ("02-detailed-infrastructure-architecture.drawio", "02. Detailed Infrastructure & VM Topology Across Layers 1, 2, and 3"),
    ("03-devops-cicd-workflow.drawio", "03. End-to-End 10-Step DevOps CI/CD & GitOps Workflow"),
    ("04-kubernetes-management-cluster.drawio", "04. Layer 2: Dedicated Kubernetes Management Cluster (Rancher + Argo CD)"),
    ("05-kubernetes-application-cluster.drawio", "05. Layer 3: Production Application Kubernetes Cluster (3 CP + 3+ Workers)"),
    ("06-postgresql-ha-architecture.drawio", "06. Layer 1: PostgreSQL 16 HA Architecture (pg-db1 Leader, pg-db2 Sync, pg-db3 Async)"),
    ("07-minio-s3-storage-architecture.drawio", "07. Layer 1: Distributed 4-Node MinIO / S3 Storage Architecture"),
    ("08-network-vlan-firewall-architecture.drawio", "08. 8-VLAN Network Segmentation & Inter-Layer Firewall Architecture"),
    ("09-ansible-automation-architecture.drawio", "09. Single-Codebase Ansible Automation Architecture (Local & Production)"),
    ("10-multipass-local-testing-architecture.drawio", "10. Multipass Local Testing Architecture (Profile A Minimal & Profile B HA)"),
    ("11-vmware-production-deployment-architecture.drawio", "11. VMware vSphere Production Deployment & Anti-Affinity Architecture"),
    ("12-backup-disaster-recovery-architecture.drawio", "12. Independent Backup, pgBackRest PITR & Disaster Recovery Architecture"),
]

for filename, title in DIAGRAMS:
    path = os.path.join(OUT_DIR, filename)
    with open(path, "w", encoding="utf-8") as f:
        f.write(build_drawio(title, COMMON_CONTAINERS, COMMON_NODES, COMMON_EDGES))
    print(f"Generated: {path}")

