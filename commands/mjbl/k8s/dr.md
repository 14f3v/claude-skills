---
description: Operate the MJBL disaster-recovery cluster — sync from prod, deploy via kubectl apply, DR transforms + CA + prereqs. Wraps the mjbl-k8s-dr skill.
argument-hint: "[topic]   e.g. sync | deploy | transforms | prereqs | ca"
---

Use the **mjbl-k8s-dr** skill for the DR cluster (single node `dr-k8s-n1` / `10.99.1.160`, kubeconfig `~/.kube/dr-config`). DR is **isolated and firewalled from prod**, ships **plain manifests via `kubectl apply`** (NOT ArgoCD), and is guarded so tooling can never hit prod.

Interpret $ARGUMENTS:
- `sync` → `tools/dr/dr-sync-from-prod.sh <service>` regenerates `deployments/<svc>/dr/` from `production/` via the transform set (needs `yq` v4); only `production/`-dir services are in scope. Review `git diff` + do the printed manual follow-ups.
- `deploy` → `DR_KUBECONFIG=~/.kube/dr-config tools/dr/dr-deploy.sh <service>` (HARD GUARD: aborts unless a node `dr-k8s-n1` is present; asserts `github-pat` secret).
- `transforms` → T1 registry→ghcr/docker.io · T2 strip network-zone affinity · T3 LoadBalancer→NodePort (drop MetalLB) · T4 longhorn→local-path · T5 ingress `*.dr.vte.mjblao.local` + dr-ca-issuer.
- `prereqs` → one-time cert-manager + `dr-ca-issuer` ClusterIssuer (`tools/dr/cluster-prereqs/`), metrics-server, DNS `*.dr.vte.mjblao.local → 10.99.1.160`, node tz file.
- `ca` → the self-signed DR CA (prod CA is firewalled from DR); export `dr-ca-keypair` for clients; HTTP-only is an option.

Keep `KUBECONFIG`/`DR_KUBECONFIG` on `~/.kube/dr-config` (the guard enforces node `dr-k8s-n1`). Pin the ACTUAL current prod image tag — `production/` may hold `:latest`. Source: `k8s-config/tools/dr/` + `DR-MIGRATION-PLAN.md`.
