---
description: Operate the MJBL facility cluster + ArgoCD — register/inspect/sync Applications, the TLS-SNI kubectl fix, prod/UAT destinations. Wraps the mjbl-k8s-facility skill.
argument-hint: "[topic]   e.g. access | apps | register | clusters | <argocd intent>"
---

Use the **mjbl-k8s-facility** skill for the facility cluster (which **hosts ArgoCD**, `argocd.vte.mjblao.local`). **Every** facility `kubectl` needs `--tls-server-name=registry.k8sapi.local` (the API cert SAN), else an x509 SAN error. ArgoCD prod writes (app create / sync / force-sync) are **user-authorized**; reads are fine.

Interpret $ARGUMENTS:
- `access` → `KUBECONFIG=~/.kube/mjbl-facility.config kubectl --tls-server-name=registry.k8sapi.local …`; argocd CLI v3.4.3 + `~/.argocd-credential`.
- `apps` → list Applications (`get applications.argoproj.io` — full name, not bare `app`) with sync/health/dest/path.
- `register` → apply `deployments/<svc>/argocd/application.yaml` to facility ArgoCD; the file's `destination.server` MUST be the target cluster (`rkek8s.vte.mjblao.local:6443` prod / `192.168.1.65:6443` UAT), NOT `kubernetes.default.svc`; manifests must already be on `main`.
- `clusters` → the registered external clusters (prod rkek8s, UAT 192.168.1.65) and which destination maps to which.
- an argocd intent → do read-only freely; for an app create/sync/force-sync, prepare it and have the user authorize the prod write.

Confirm the manifests are merged to `main` before syncing (else a stale state deploys). DR is NOT in ArgoCD — use `mjbl-k8s-dr`.
