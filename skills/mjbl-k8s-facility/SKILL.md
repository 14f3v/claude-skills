---
name: mjbl-k8s-facility
description: This skill should be used when the user asks to operate the MJBL FACILITY cluster or ArgoCD — "where does ArgoCD run", "the facility cluster", "register / create an ArgoCD Application", "deploy via ArgoCD", "why is my facility kubectl failing with an x509 / certificate SAN error", "list ArgoCD apps / registered clusters", "sync an app", "which destination.server for prod vs UAT", or any ArgoCD / facility-cluster operation. Covers the facility kubeconfig + the mandatory TLS-SNI fix, the ArgoCD-manages-prod+UAT-as-external-clusters topology, Application destinations, and the app-create/sync method.
version: 0.1.0
---

# MJBL Facility Cluster + ArgoCD

> The facility cluster **hosts ArgoCD** (`argocd.vte.mjblao.local`) and manages prod + UAT as registered external clusters. **ArgoCD prod writes (app create / sync / force-sync) are user-authorized; reads are fine.** Orientation: `mjbl-k8s-platform`.

## Access — the TLS-SNI fix is mandatory
```bash
export KUBECONFIG=~/.kube/mjbl-facility.config
# The kubeconfig server is k8sregistry.vte.mjblao.local:6443 but the API cert SAN is
# registry.k8sapi.local — so EVERY kubectl call needs --tls-server-name, else:
#   x509: certificate is valid for ... registry.k8sapi.local, not k8sregistry.vte.mjblao.local
kubectl --tls-server-name=registry.k8sapi.local -n argocd get applications.argoproj.io
```
Cluster is k8s **1.31**. The `argocd` CLI (`v3.4.3`) + `~/.argocd-credential` are also present for API access to `argocd.vte.mjblao.local`.

## ArgoCD topology (critical)
ArgoCD runs HERE and deploys to **other** clusters registered as external clusters — so an Application's `destination.server` is the **target** cluster, never `https://kubernetes.default.svc` (which = facility):

| Target | `destination.server` |
|---|---|
| **prod (rkek8s)** | `https://rkek8s.vte.mjblao.local:6443` |
| **UAT** | `https://192.168.1.65:6443` |

Registered clusters (`get secret -n argocd -l argocd.argoproj.io/secret-type=cluster`): `rkek8s.vte.mjblao.local:6443`, `192.168.1.65:6443`, and `10.88.101.31:6443` — the third is **rkek8s registered again by node-IP**; always use the DNS name `rkek8s.vte.mjblao.local:6443` in `destination.server`. Existing prod **Application** names to mirror (ArgoCD app names — they differ from the workload/ns names listed in `mjbl-k8s-production`): `mjbl-mtls-gateway`, `mjbl-mtls-enrollment`, `mjbl-mtls-portal`, `microloan-system-podntnyx`, `prod.gold-price-service`, `mjbl-api-gateway`, `agency-v2-uat-gateway` (all → rkek8s); UAT apps: `approval-form-system-uat`, `partner-payment-system-uat`, `uat.gold-price-service*`, `itdprofiler-alert-service-uat` (→ 192.168.1.65). The lone facility-self app `mis-airflow` is the one place `destination.server: https://kubernetes.default.svc` is correct (it deploys to facility itself).

## Inspect apps
```bash
K="kubectl --tls-server-name=registry.k8sapi.local -n argocd"
$K get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEST:.spec.destination.server,PATH:.spec.source.path'
```
(Use the **full** `applications.argoproj.io` — bare `app` can collide with Rancher's `apps.catalog.cattle.io`.)

## Register a new Application (the deploy step — user-authorized prod write)
Each `k8s-config` app dir carries `argocd/application.yaml`. It is applied **manually to facility ArgoCD** (NOT auto-discovered — there is no app-of-apps). The repo file must already have the correct prod `destination.server`:
```bash
KUBECONFIG=~/.kube/mjbl-facility.config kubectl --tls-server-name=registry.k8sapi.local \
  apply -f deployments/<service>/argocd/application.yaml
```
With `syncPolicy.automated` (prune + selfHeal), ArgoCD then pulls from `main` and reconciles to the target cluster. **Prerequisite:** the manifests must already be on `main` (merge the PR first) or ArgoCD syncs a stale state.

## Gotchas
- Missing `--tls-server-name=registry.k8sapi.local` → x509 SAN error on every call.
- `destination.server: https://kubernetes.default.svc` in an Application → wrongly targets facility; use the prod/UAT external URL.
- App appears "registered" but never deploys → the manifests aren't on `main` yet, or the destination/cluster isn't registered.
- DR is **not** managed by ArgoCD — see `mjbl-k8s-dr`.

## Related
`mjbl-k8s-platform` (map) · `mjbl-k8s-production` (what lands on prod) · `cicd-platform` (installing ArgoCD on a fresh cluster) · memory `reference_argocd_access.md`, `reference_facility_cluster.md`.
