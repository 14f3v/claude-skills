---
name: mjbl-k8s-dr
description: This skill should be used when the user asks to operate the MJBL DISASTER-RECOVERY (DR) Kubernetes cluster — "the DR cluster / dr-k8s-n1 / 10.99.1.160 / drk8s.vte.mjblao.local", "is DR a replica/standby of prod", "deploy / sync a service (gold-price, microloan) to DR", "DR transforms (LoadBalancer→NodePort, longhorn→local-path, registry rewrite)", "the DR CA / dr-ca-issuer / *.dr.vte.mjblao.local", "DR prerequisites (cert-manager, metrics-server, DNS)", "the DR-local Rancher CD (Fleet) seeding", "why DR isn't on the DC ArgoCD/Rancher", "manage DR from the Mac", or DR cluster faults ("etcd slow / ImagePullBackOff / Calico Unauthorized / expired SA token"). DR is a SINGLE-NODE, standalone, lean cluster **seeded by a LOCAL Rancher CD (Fleet) that runs on the DR cluster itself** and watches the k8s-config `dr/` overlays — the older plain `kubectl apply` / `dr-deploy.sh` flow is DEPRECATED. DR is isolated and firewalled from the prod/DC network and is NOT a downstream of the DC ArgoCD/Rancher.
version: 0.1.1
---

# MJBL Disaster-Recovery Cluster

> **What it is:** a **single-node** (by design) Kubernetes **v1.31.14** cluster — host `10.99.1.160`, node `dr-k8s-n1` (Ubuntu 24.04 VM) — to host applications *during* DR activity. **It is standalone / independent of production** (`rkek8s`): NO replication, federation, shared state, or hot/warm-standby mirroring. Treat it as its own self-contained cluster; DR data-protection means **this cluster's own backups** (storage is host-local `local-path`, no replication/snapshots), not cross-cluster sync. Firewalled: the DR segment `10.99.1.0/24` **cannot reach the DC segment `10.88.101.0/24`** (so no prod CA `10.88.1.116`, no MetalLB VIPs, no DC-Rancher import). Source-of-truth: `k8s-config/tools/dr/`, `DR-MIGRATION-PLAN.md`, and the Mac memory `project-drk8s-cluster` / `project-drk8s-fleet-migration`. Orientation: `mjbl-k8s-platform`.

## Cluster shape (lean by deliberate choice)
Provisioned 2026-06-16 via the [[k8s-bare-metal]] `k8s-single-node-cluster-setup.sh` (kubeadm + Calico). Full Rancher AND Longhorn were dropped 2026-06-18 to cure etcd I/O contention on a shared spinning HDD (WAL fsync ~100 ms-p99 → ~5 ms after). Stack now: **kubeadm + Calico + `local-path` (sole default StorageClass, v0.0.30, data at `/opt/local-path-provisioner`) + `ingress-nginx` + a LOCAL Rancher CD (Fleet)**.
- **DR seeding = a LOCAL Rancher CD (Fleet) on the DR cluster itself** (adopted 2026-07-29), which watches the `mjbl-digital/k8s-config` repo's `deployments/<svc>/dr/` overlays and reconciles them onto DR. This **supersedes the deprecated `kubectl apply` / `dr-deploy.sh` flow**. It is kept **self-contained** — DR runs its *own* CD, it is NOT a downstream of the DC Rancher/ArgoCD (the DR→DC firewall). Given the etcd-I/O history that removed the full Rancher, **watch `/home/mjbl/dr-health.log` (`slow_apply`) after adopting CD.**
- **Harbor and the DC ArgoCD stay OUT OF SCOPE on DR** (DC→DR firewall). For ad-hoc / break-glass changes, `kubectl` / `helm` against DR still work.
- **Ingress is `hostNetwork` on `10.99.1.160`** (no MetalLB). DNS `*.dr.vte.mjblao.local` → `10.99.1.160`.
- **Self-managed — DR runs its OWN local Rancher CD; do NOT import DR into the DC Rancher** (`rkek8s.vte.mjblao.local`); the DR→DC firewall silently drops a DC-managed import (attempted + abandoned 2026-06-16). The DR-local CD watches git directly, so it needs no path back to the DC.
- **Single etcd member by design** (1 node) — no quorum games, but also **no HA**: a node/disk fault = full outage (accepted for a DR target; recover by fixing the node, see faults below). This is the same node-count-vs-redundancy principle that bites elsewhere — a **2-node** etcd is actually the *worst* spot (zero fault tolerance; see `mjbl-k8s-facility`), and Longhorn replica count must match node count (why DR uses single-replica `local-path`, not Longhorn).
- Namespaces: `default kube-system kube-node-lease kube-public ingress-nginx local-path-storage` (+ deployed app ns).

## Access (DR work happens from the Mac, not this ops box)
DR is reached from **`khemphet-mac`** (the `192.168.1.25` ops box has **no** DR kubeconfig). On the Mac/DR side the kubeconfig the tools expect is `~/.kube/dr-config`; on the DR host itself it's `/home/mjbl/.kube/config`.
```bash
ssh khemphet-mac                 # then run kubectl/helm against DR, or:
ssh mjbl@10.99.1.160             # DR host (key-based; sudo pw is base64 at ~/.host-10.99.1.160-password-base64)
export KUBECONFIG=~/.kube/dr-config   # must show node dr-k8s-n1 — NEVER prod
```

## Migration model — which services, and the transforms
Replicate each **prod** fleet (`mjbl-digital/k8s-config`) into a new `deployments/<svc>/dr/` of **plain, pre-transformed** manifests. The **DR-local Rancher CD (Fleet) syncs these `dr/` overlays** onto DR (the T1–T5 pre-transform below stays — Fleet bundles the already-transformed output, it does not transform). **Repo-side wiring (a separate change, not yet in `k8s-config`):** the DR GitRepo must be scoped to `dr/`, and the prod/UAT GitOps must keep *excluding* `dr/`+`tools/` (via `.fleetignore` / per-path GitRepo scoping) so DR overlays never land on prod/UAT.
- **In scope = only services with a `production/` dir.** Real set so far: **`gold-price-service` (Wave 2)** + **`microloan` (Wave 3)**. The **4 `mjbl-mtls-*`** services have `production/` but stay **prod-only** (prod CA + MetalLB unreachable from DR); `edl-api-integrations` deferred; the 7 flat-file/UAT services are out of scope.
- **Transform set T1–T5** (`dr-sync-from-prod.sh`, needs `yq` v4):
  - **T1** image `mjcr.vte.mjblao.local/ghcr|docker.io/...` → `ghcr.io|docker.io/...` (mjcr unreachable; keep `github-pat` pull secret).
  - **T2** strip the whole `.affinity` block + `nodeSelector` (DR node is unlabeled, has no `network-zone`).
  - **T3** `LoadBalancer`/MetalLB → `NodePort` (drop `loadBalancerIP`/`externalIPs`/`externalTrafficPolicy`/MetalLB annotations).
  - **T4** `storageClassName` → `local-path`.
  - **T5** ingress host `*.vte.mjblao.local` → `*.dr.vte.mjblao.local`, force class `nginx`, rewrite `cert-manager.io/cluster-issuer` → `dr-ca-issuer`.
  - **Per-service extras:** microloan needed `imagePullSecrets: github-pat` ADDED + a declared `logs-store` PVC (prod provisioned both out-of-band).

## Workflow — sync then commit (per service); the DR-local Fleet reconciles
```bash
# 1. regenerate deployments/<svc>/dr/ from production/ via T1–T5 (review the diff!)
tools/dr/dr-sync-from-prod.sh <service>
git diff -- deployments/<service>/dr/

# 2. commit + push the dr/ overlay (via PR — k8s-config is ruleset-protected) → the DR-LOCAL
#    Rancher CD (Fleet) pulls from main and reconciles it onto DR. No manual apply step.
git add deployments/<service>/dr/ && git commit -m "dr(<service>): sync overlay" && git push
```
- **`tools/dr/dr-deploy.sh` is DEPRECATED** (it did `kubectl apply -f dr/`). Keep it only as a **break-glass** manual apply if the DR-local CD is down. The old "can never hit prod" guard is now inherent: the **DR GitRepo is scoped to the DR cluster only**, so a `dr/` overlay can only ever reconcile onto DR.
- Order matters: **gold-price-service before microloan** (microloan nginx proxies `/glms-api/v1/` to it in-cluster). Manual follow-ups (unchanged): provision out-of-band secrets (`github-pat` + `<svc>-env` + any TLS), and **pin the ACTUAL current prod image tag** — `production/` may hold `:latest`/a placeholder (DR carried `gold-price v1.0.5`, `micro_loan 92a521d`, `agency_v2 v1.1.11`; re-sync before a real cutover so DR isn't behind prod).

## One-time prerequisites (before Ingress/TLS services — "Wave 2+")
```bash
export KUBECONFIG=~/.kube/dr-config
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version v1.16.2 --set crds.enabled=true
kubectl apply -f tools/dr/cluster-prereqs/dr-ca-issuer.yaml          # self-signed DR CA → ClusterIssuer dr-ca-issuer
kubectl -n cert-manager get secret dr-ca-keypair -o jsonpath='{.data.tls\.crt}' | base64 -d > mjbl-dr-ca.crt
```
Also: **metrics-server** (microloan HPAs), **DNS** `*.dr.vte.mjblao.local → 10.99.1.160`, node tz `/usr/share/zoneinfo/Asia/Vientiane`. **Why a self-signed DR CA** (not the MJBL prod CA): the prod CA host is firewalled from DR — keep DR self-contained. HTTP-only is an option (drop the `tls:` blocks + `cert-manager.io/cluster-issuer` annotation from each `dr/` Ingress).
- **Rancher CD (Fleet) is a one-time prereq now too:** install the local Rancher CD / Fleet on DR and register a **`GitRepo` scoped to `deployments/*/dr/`** of `mjbl-digital/k8s-config`, targeting the DR cluster. After that, seeding = commit the `dr/` overlay (no manual apply). Keep it lean (the full Rancher was dropped for etcd I/O — see cluster-shape note).

## Status & known faults
- **PR #52 merged to `main`** (DR overlays; zero `production/` changes → no prod reconcile). cert-manager + `dr-ca-issuer` + leaf certs Ready; **`gold-price-service` + `microloan` deployed but `ImagePullBackOff` BY DESIGN** — `github-pat` + `<svc>-env` arrive via the planned **prod→DR backup/restore** (next step); until then private ghcr.io pulls 401.
- **Latent fragility (watch under restore load):** expired projected-SA-token / Calico CNI `Unauthorized` (fix: **restart the calico pods**); one `coredns` replica CrashLooping; intermittent docker.io egress. **Durable clear = a node reboot.** etcd boot-race on reboot → `systemctl restart kubelet`. **Do NOT run disk-loading diagnostics (`dd O_DSYNC`) on the shared etcd disk** — it has crashed the control plane.
- **Monitoring:** `/home/mjbl/dr-health-check.sh` (zero-load etcd `:2381/metrics` + kubectl) runs via the DR host's user crontab every 10 min → `/home/mjbl/dr-health.log` (rising `slow_apply` = I/O contention returning).

## Related
`mjbl-k8s-platform` (estate map) · `mjbl-k8s-production` (the prod fleets DR overlays are derived from) · `mjbl-k8s-facility` (the DC ArgoCD — which DR bypasses; DR runs its OWN local Rancher CD/Fleet) · `k8s-bare-metal` (how this node was provisioned) · `internal-ca`/`mtls` (CA concepts behind the DR CA).
