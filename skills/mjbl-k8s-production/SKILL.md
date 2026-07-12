---
name: mjbl-k8s-production
description: This skill should be used when the user asks to operate, inspect, or deploy on the MJBL PRODUCTION Kubernetes cluster (rkek8s) — "check prod pods/services", "what's on the prod cluster", "the prod MetalLB pool / LoadBalancer IPs", "expose a service on prod via MetalLB", "reach prod from the office network / jump to a prod node", "prod nodes / control plane", "which prod IP is free", or any production-cluster (10.88.x) operation. Covers the rkek8s node/network/MetalLB/ingress layout, the kubeconfig + jump access, and how workloads land on prod (ArgoCD from the facility cluster).
version: 0.1.1
---

# MJBL Production Cluster (`rkek8s`)

> The live production cluster. **Reads are fine; writes are user-gated** (k8s-config merges + ArgoCD app create/sync are user-authorized — the agent does not self-merge or force-sync prod). Verify against the live cluster before asserting. Orientation: `mjbl-k8s-platform`. What runs here: `mjbl-mtls-platform`.

## Access
```bash
export KUBECONFIG=~/.kube/mjbl-prod.config      # this is rkek8s, NOT the default ctx
kubectl get nodes -o wide
```
- The **default** `kubectl` context (`kubernetes-admin@kubernetes`) is **UAT**, not prod — a very common mix-up. If a prod resource shows `NotFound`, you're almost certainly on the UAT context. Always set `KUBECONFIG=~/.kube/mjbl-prod.config` for prod.
- **Network segmentation:** prod (`10.88.x`) is **not routable from the office/UAT LAN** (`192.168.1.25` → "No route to host"). To test a prod IP/port from a real prod vantage point, jump:
  ```bash
  ssh khemphet-mac            # Mac jump host
    ssh k8s-cp-01             # → mjbl-k8s-n01 (10.88.101.32), READ-ONLY prod cp node
  # then e.g.  nc -zv -w5 10.88.101.144 8096   /   curl -sS http://10.88.101.144:8096/health
  ```

## Nodes
| Node | Role | Internal IP |
|---|---|---|
| `mjbl-k8s-n01` | control-plane | `10.88.101.32` |
| `mjbl-k8s-n02` | control-plane | `10.88.1.27` |
| `mjbl-k8s-n03` | control-plane | `10.88.101.31` |
| `mjbl-k8s-n04` | worker | `10.88.1.26` |

API (ArgoCD destination + kubeconfig server): `https://rkek8s.vte.mjblao.local:6443`.

**etcd HA (unlike facility):** 3 control-plane nodes = **3 etcd members → quorum 2 → tolerates ONE node failure** with no control-plane outage (contrast the facility cluster's fragile 2-node etcd, where any single node down = total outage). Storage is **Longhorn**; with 4 nodes the default 3-replica SC schedules fine here (whereas facility, at 2 nodes, must use `longhorn-2replicas`). For the cluster-agnostic recovery playbooks — node-down behavior, post-reboot sanitize (NodeLost pods / stuck `VolumeAttachment`), the **Longhorn `degraded` replica-count-vs-nodes** fix, and the **ArgoCD `Replace=true` OutOfSync** fix — see `mjbl-k8s-facility` (they apply on any cluster).

## MetalLB — the L4 entry plane
Pool **`default-pool` = `10.88.101.140 – 10.88.101.189`** (ns `metallb-system`, auto-assign on). Pin a specific IP with the modern annotation:
```yaml
metadata:
  annotations:
    metallb.universe.tf/loadBalancerIPs: "10.88.101.<n>"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local   # preserves the real client source IP
```
Assigned IPs (check `kubectl get svc -A | grep LoadBalancer` for the current truth):

| IP | Service |
|---|---|
| `10.88.101.140` | `ingress-nginx-controller` (the cluster ingress) |
| `10.88.101.141` | `microloan-app` |
| `10.88.101.142` | `mjbl-mtls-gateway` (`:2399`) |
| `10.88.101.143` | `mjbl-enroll-relay` (`:8443`) |
| `10.88.101.144` | `mjbl-api-gateway` — LapNet domestic-payment L4 (`:8096`) |

**Two exposure styles on prod:** (a) a **MetalLB `LoadBalancer`** for direct-IP / L4 / partner traffic (mTLS gateway, relay, the LapNet gateway), or (b) an **Ingress** on `ingress-nginx` (`.140`) for hostname+TLS HTTP apps. ingress-nginx serves a configured default cert; per-host Ingresses can omit `secretName` to use it (as the `microloan*-ings` prod fleets do).

## How workloads get here
**ArgoCD on the facility cluster** syncs prod from the `k8s-config` git repo. Prod Applications use `destination.server: https://rkek8s.vte.mjblao.local:6443`. **There is no `argocd` namespace on prod itself** — the Application objects live on facility (see `mjbl-k8s-facility`). Day-2 flow: edit `k8s-config` → PR → **user merges** → ArgoCD auto-syncs (prune + selfHeal). New apps must be **registered** in facility ArgoCD (a user-authorized prod write).

What's deployed here includes: the mTLS platform (`mjbl-mtls-gateway`, `mjbl-enroll`, `mjbl-mtls-operator-portal`), `microloan-application`, `lapnet-systems`, `gold-price-service` (prod), and `mjbl-api-gateway` / `agency-v2-uat-gateway`.

## Gotchas
- Wrong-context `NotFound` → set the prod kubeconfig.
- Can't reach a prod IP from the ops box → segmentation; use the Mac→`k8s-cp-01` jump.
- `kubectl get app` on prod resolves to Rancher's `apps.catalog.cattle.io`, not ArgoCD — ArgoCD Applications live on **facility** (`get applications.argoproj.io`).
- `externalTrafficPolicy: Local` needs a ready pod on the announcing node; fine with ≥2 replicas spread across nodes.

## Related
`mjbl-k8s-platform` (map) · `mjbl-k8s-facility` (ArgoCD/deploys) · `mjbl-mtls-platform` + `mjbl-*` mTLS skills (what runs here) · `k8s-bare-metal` (provisioning).
