---
description: Map + access index for the MJBL multi-cluster Kubernetes estate (prod rkek8s / facility-ArgoCD / UAT / DR). Wraps the mjbl-k8s-platform skill.
argument-hint: "[topic]   e.g. clusters | kubeconfig | argocd | which-cluster"
---

Use the **mjbl-k8s-platform** skill as the authoritative cluster map + kubeconfig/access index for the MJBL Kubernetes estate. This host (`192.168.1.25`) is the ops/remote runner and holds the kubeconfigs — treat the live clusters + `/home/mjbl` docs as source of truth and VERIFY figures (never invent IPs/contexts).

Interpret $ARGUMENTS as the focus:
- `clusters` / empty → the four-cluster map (prod `rkek8s`, facility=ArgoCD, UAT `192.168.1.65`, DR `dr-k8s-n1`), their networks, and what each runs.
- `kubeconfig` / `access` → which kubeconfig+context per cluster, the facility `--tls-server-name=registry.k8sapi.local` fix, and the `ssh khemphet-mac → ssh k8s-cp-01` jump for reaching prod from the office LAN (segmented from `10.88.x`).
- `argocd` → the topology: ArgoCD runs on facility and manages prod+UAT as external clusters (destinations `rkek8s.vte.mjblao.local:6443` / `192.168.1.65:6443`); DR is outside ArgoCD. Hand off to `mjbl-k8s-facility`.
- `which-cluster` → help decide where a service belongs / where to look for it.
- a cluster name → route to the sibling skill: `mjbl-k8s-production`, `mjbl-k8s-facility`, or `mjbl-k8s-dr`.

This is an orientation entry point — for hands-on work in one cluster, hand off to the focused sibling skill. Respect the gates: k8s-config merges are user-gated, ArgoCD prod app-create/sync is user-authorized (reads OK), DR tooling is guarded to node `dr-k8s-n1`.
