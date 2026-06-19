---
name: mjbl-k8s-platform
description: This skill should be used when the user asks about "the MJBL Kubernetes clusters", "the cluster topology / map", "which cluster is which", "which kubeconfig / how do I reach prod / facility / UAT / DR", "where does ArgoCD run", "which cluster runs X", "how do apps get deployed", or any high-level orientation about the MJBL multi-cluster Kubernetes estate (production rkek8s, the facility/ArgoCD cluster, UAT 192.168.1.65, and DR). It is the top-level cluster map + kubeconfig/access index + ArgoCD-topology front door that routes to the per-cluster sibling skills (mjbl-k8s-production, mjbl-k8s-facility, mjbl-k8s-dr).
version: 0.1.0
---

# MJBL Kubernetes Estate — Cluster Map & Access Index

> **Orientation / source-of-truth front door.** This host (`/home/mjbl`, `192.168.1.25` — the MJBL ops / remote runner, NOT a cluster node) holds the kubeconfigs and runbooks. This skill is the distilled live map; for hands-on work in one cluster, hand off to the focused sibling skill. **VERIFY a figure against the live cluster (or the referenced doc) before acting — never invent IPs/paths/contexts.**
>
> Related knowledge bases: `mjbl-mtls-platform` (what the mTLS platform runs *on* prod), `k8s-bare-metal` (how a bare-metal cluster is *provisioned*), and memory notes `reference_facility_cluster.md` / `reference_argocd_access.md`.

## When to use
- "What clusters are there / give me the topology."
- "Which kubeconfig / context do I use for prod (or facility / UAT / DR)?"
- "Where does ArgoCD live and which clusters does it manage?"
- "Which cluster runs <service>?" or "Where should I deploy <service>?"
- Sanity-checking a cluster IP / context / ArgoCD destination before acting.
- Onboarding before diving into one cluster (then hand off to the sibling skill).

## The estate — four clusters, one ArgoCD

| Cluster | Role | kubeconfig / context | Control-plane / key node | Deploy mechanism |
|---|---|---|---|---|
| **Production (`rkek8s`)** | live prod (mTLS platform, microloan, lapnet, gold-price prod…) | `~/.kube/mjbl-prod.config` | `mjbl-k8s-n01..n04` (`10.88.101.32/.31` + `10.88.1.27/.26`) | **ArgoCD** (from facility) → `https://rkek8s.vte.mjblao.local:6443` |
| **Facility** | **runs ArgoCD** (`argocd.vte.mjblao.local`) + facility apps | `~/.kube/mjbl-facility.config` ⚠ needs `--tls-server-name=registry.k8sapi.local` | k8s 1.31 | self / Helm |
| **UAT** | UAT apps (approval-form, partner-payment, gold-price uat, itprofiler-alert) | `~/.kube/config` (**default** ctx `kubernetes-admin@kubernetes`) | `mjbl-graphql-api` `192.168.1.65` (+ `mb2-uat` `.66`, `appgateway` `.61`) | **ArgoCD** (from facility) → `https://192.168.1.65:6443` |
| **DR** | DR site — single-node **v1.31**, **standalone** (NOT a prod mirror; lean kubeadm+Calico+local-path, no Rancher/ArgoCD/Harbor) | `~/.kube/dr-config` (**on the Mac**, not the ops box) | `dr-k8s-n1` `10.99.1.160` | **`kubectl apply`** (NO GitOps) via `tools/dr/dr-deploy.sh` |

**Networks:** prod = `10.88.101.x` (DMZ/MetalLB) + `10.88.1.x` (internal). UAT/facility/ops = `192.168.1.x`. DR = `10.99.1.x`. **The office/UAT LAN (`192.168.1.x`) is segmented from prod (`10.88.x`)** — you cannot reach prod IPs from `192.168.1.25` ("No route to host"); test prod from a prod-network host (see access below).

## ArgoCD topology (the one thing people get wrong)
ArgoCD runs on the **facility** cluster and manages **prod** and **UAT** as **registered external clusters** — so an Application's `destination.server` is the *target* cluster's API URL, **NOT** `https://kubernetes.default.svc` (that would target facility itself):
- prod apps → `https://rkek8s.vte.mjblao.local:6443`
- UAT apps → `https://192.168.1.65:6443`
- DR is **outside ArgoCD** (plain `kubectl apply`).

Details + how to register/sync apps live in **`mjbl-k8s-facility`**.

## Access cheat-sheet
```bash
# UAT (default context — what bare `kubectl` hits)
kubectl get nodes

# PROD (rkek8s)
KUBECONFIG=~/.kube/mjbl-prod.config kubectl -n <ns> get all

# FACILITY (ArgoCD lives here) — TLS SNI fix is mandatory
KUBECONFIG=~/.kube/mjbl-facility.config kubectl --tls-server-name=registry.k8sapi.local -n argocd get applications.argoproj.io

# DR — runs from the Mac (this ops box has no dr-config; DR net is firewalled from the DC net)
ssh khemphet-mac    # → KUBECONFIG=~/.kube/dr-config kubectl get nodes   (must show node dr-k8s-n1)

# Reach a PROD-NETWORK host from the office LAN (prod IPs aren't routable from 192.168.1.25):
ssh khemphet-mac          # → your Mac jump
  ssh k8s-cp-01           # → prod cp node mjbl-k8s-n01 (10.88.101.32), READ-ONLY
```

## "Which cluster?" decision
- Real production traffic / the mTLS platform / MetalLB L4 IPs → **prod** (`mjbl-k8s-production`).
- ArgoCD Application objects, sync/registering apps, the ArgoCD UI → **facility** (`mjbl-k8s-facility`).
- Anything proxying to `192.168.1.61/.65/.66` or a UAT/pentest target → **UAT** (default ctx).
- Disaster-recovery standby, `*.dr.vte.mjblao.local`, `kubectl apply` flows → **DR** (`mjbl-k8s-dr`).

## Related skills & docs
- `mjbl-k8s-production` · `mjbl-k8s-facility` · `mjbl-k8s-dr` — the per-cluster operational skills.
- `mjbl-mtls-platform` — the mTLS device-auth platform that runs on prod.
- `k8s-bare-metal` — provisioning a new bare-metal cluster from scratch.
- DR plan: `k8s-config/tools/dr/` (scripts) + `DR-MIGRATION-PLAN.md`. Memory: `reference_facility_cluster.md`, `reference_argocd_access.md`.

**Prod gates:** k8s-config merges are user-gated; ArgoCD prod writes (app create / sync) are user-authorized (reads OK); CA-host changes via `! ssh ca`. This skill is orientation — route to the sibling skill for the actual operation.
