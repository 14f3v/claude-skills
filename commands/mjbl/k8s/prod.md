---
description: Operate/inspect the MJBL production cluster (rkek8s) — nodes, MetalLB pool, ingress, kubeconfig + jump access. Wraps the mjbl-k8s-production skill.
argument-hint: "[topic]   e.g. access | nodes | metallb | deploy | <kubectl intent>"
---

Use the **mjbl-k8s-production** skill for the MJBL production cluster (`rkek8s`). Reads are fine; **writes are user-gated** (k8s-config merges + ArgoCD app-create/sync are user-authorized — do not self-merge or force-sync prod). Always `export KUBECONFIG=~/.kube/mjbl-prod.config` (the DEFAULT context is UAT, not prod — a `NotFound` usually means wrong context).

Interpret $ARGUMENTS:
- `access` → the prod kubeconfig + the `ssh khemphet-mac → ssh k8s-cp-01` (mjbl-k8s-n01, read-only) jump, since prod `10.88.x` is not routable from the office LAN.
- `nodes` → the 4 nodes (`mjbl-k8s-n01..n04`, `10.88.101.32/.31` + `10.88.1.27/.26`) and the API `rkek8s.vte.mjblao.local:6443`.
- `metallb` → pool `default-pool` `10.88.101.140-189`, the assigned IPs (`.140` ingress … `.144` lapnet gateway), and how to pin (`metallb.universe.tf/loadBalancerIPs` + `externalTrafficPolicy: Local`).
- `deploy` → workloads land via ArgoCD from the facility cluster (no `argocd` ns on prod); hand off to `mjbl-k8s-facility`.
- a kubectl intent → run it read-only against the prod kubeconfig; propose (don't apply) any write and surface it for the user to run.

VERIFY live before asserting (e.g. `kubectl get svc -A | grep LoadBalancer` for current IPs). For what actually runs here, see `mjbl-mtls-platform`.
