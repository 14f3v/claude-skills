---
name: mjbl-k8s-dr
description: This skill should be used when the user asks to operate the MJBL DISASTER-RECOVERY (DR) Kubernetes cluster — "the DR cluster / dr-k8s-n1 / 10.99.1.160 / drk8s.vte.mjblao.local", "is DR a replica/standby of prod", "deploy / sync a service (gold-price, microloan) to DR", "DR transforms (LoadBalancer→NodePort, longhorn→local-path, registry rewrite)", "the DR CA / dr-ca-issuer / *.dr.vte.mjblao.local", "DR prerequisites (cert-manager, metrics-server, DNS)", "why no Rancher/ArgoCD/Harbor on DR", "manage DR from the Mac", or DR cluster faults ("etcd slow / ImagePullBackOff / Calico Unauthorized / expired SA token"). DR is a SINGLE-NODE, standalone, lean cluster deployed by plain `kubectl apply` (NOT GitOps/ArgoCD), isolated and firewalled from the prod/DC network.
version: 0.1.0
---

# MJBL Disaster-Recovery Cluster

> **What it is:** a **single-node** (by design) Kubernetes **v1.31.14** cluster — host `10.99.1.160`, node `dr-k8s-n1` (Ubuntu 24.04 VM) — to host applications *during* DR activity. **It is standalone / independent of production** (`rkek8s`): NO replication, federation, shared state, or hot/warm-standby mirroring. Treat it as its own self-contained cluster; DR data-protection means **this cluster's own backups** (storage is host-local `local-path`, no replication/snapshots), not cross-cluster sync. Firewalled: the DR segment `10.99.1.0/24` **cannot reach the DC segment `10.88.101.0/24`** (so no prod CA `10.88.1.116`, no MetalLB VIPs, no DC-Rancher import). Source-of-truth: `k8s-config/tools/dr/`, `DR-MIGRATION-PLAN.md`, and the Mac memory `project-drk8s-cluster` / `project-drk8s-fleet-migration`. Orientation: `mjbl-k8s-platform`.

## Cluster shape (lean by deliberate choice)
Provisioned 2026-06-16 via the [[k8s-bare-metal]] `k8s-single-node-cluster-setup.sh` (kubeadm + Calico). **Rancher AND Longhorn were dropped 2026-06-18** to cure etcd I/O contention on a shared spinning HDD (WAL fsync ~100 ms-p99 → ~5 ms after). Now: **kubeadm + Calico + `local-path` (sole default StorageClass, v0.0.30, data at `/opt/local-path-provisioner`)** + `ingress-nginx`.
- **Harbor and ArgoCD/Fleet are intentionally OUT OF SCOPE on DR — do not propose them.** Manage DR directly with **`kubectl` / `helm`**.
- **Ingress is `hostNetwork` on `10.99.1.160`** (no MetalLB). DNS `*.dr.vte.mjblao.local` → `10.99.1.160`.
- **Self-managed — do NOT import into the DC Rancher** (`rkek8s.vte.mjblao.local`); the DR→DC firewall silently drops it. Attempted + abandoned 2026-06-16.
- Namespaces: `default kube-system kube-node-lease kube-public ingress-nginx local-path-storage` (+ deployed app ns).

## Access (DR work happens from the Mac, not this ops box)
DR is reached from **`khemphet-mac`** (the `192.168.1.25` ops box has **no** DR kubeconfig). On the Mac/DR side the kubeconfig the tools expect is `~/.kube/dr-config`; on the DR host itself it's `/home/mjbl/.kube/config`.
```bash
ssh khemphet-mac                 # then run kubectl/helm against DR, or:
ssh mjbl@10.99.1.160             # DR host (key-based; sudo pw is base64 at ~/.host-10.99.1.160-password-base64)
export KUBECONFIG=~/.kube/dr-config   # must show node dr-k8s-n1 — NEVER prod
```

## Migration model — which services, and the transforms
Replicate each **prod** fleet (`mjbl-digital/k8s-config`) into a new `deployments/<svc>/dr/` of **plain, pre-transformed** manifests, applied by `kubectl apply` (repo `.fleetignore` excludes `dr/`+`tools/` so Fleet never bundles them onto prod/UAT).
- **In scope = only services with a `production/` dir.** Real set so far: **`gold-price-service` (Wave 2)** + **`microloan` (Wave 3)**. The **4 `mjbl-mtls-*`** services have `production/` but stay **prod-only** (prod CA + MetalLB unreachable from DR); `edl-api-integrations` deferred; the 7 flat-file/UAT services are out of scope.
- **Transform set T1–T5** (`dr-sync-from-prod.sh`, needs `yq` v4):
  - **T1** image `mjcr.vte.mjblao.local/ghcr|docker.io/...` → `ghcr.io|docker.io/...` (mjcr unreachable; keep `github-pat` pull secret).
  - **T2** strip the whole `.affinity` block + `nodeSelector` (DR node is unlabeled, has no `network-zone`).
  - **T3** `LoadBalancer`/MetalLB → `NodePort` (drop `loadBalancerIP`/`externalIPs`/`externalTrafficPolicy`/MetalLB annotations).
  - **T4** `storageClassName` → `local-path`.
  - **T5** ingress host `*.vte.mjblao.local` → `*.dr.vte.mjblao.local`, force class `nginx`, rewrite `cert-manager.io/cluster-issuer` → `dr-ca-issuer`.
  - **Per-service extras:** microloan needed `imagePullSecrets: github-pat` ADDED + a declared `logs-store` PVC (prod provisioned both out-of-band).

## Workflow — sync then deploy (per service)
```bash
# 1. regenerate deployments/<svc>/dr/ from production/ via T1–T5 (review the diff!)
tools/dr/dr-sync-from-prod.sh <service>
git diff -- deployments/<service>/dr/

# 2. apply to DR — HARD GUARD: aborts unless `kubectl get nodes` includes dr-k8s-n1 (can never hit prod);
#    applies the namespace first, asserts the out-of-band secret `github-pat` exists, then kubectl apply -f dr/
DR_KUBECONFIG=~/.kube/dr-config tools/dr/dr-deploy.sh <service>
```
Order matters: **gold-price-service before microloan** (microloan nginx proxies `/glms-api/v1/` to it in-cluster). Manual follow-ups: provision out-of-band secrets (`github-pat` + `<svc>-env` + any TLS), and **pin the ACTUAL current prod image tag** — `production/` may hold `:latest`/a placeholder (DR carried `gold-price v1.0.5`, `micro_loan 92a521d`, `agency_v2 v1.1.11`; re-sync before a real cutover so DR isn't behind prod).

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

## Status & known faults
- **PR #52 merged to `main`** (DR overlays; zero `production/` changes → no prod reconcile). cert-manager + `dr-ca-issuer` + leaf certs Ready; **`gold-price-service` + `microloan` deployed but `ImagePullBackOff` BY DESIGN** — `github-pat` + `<svc>-env` arrive via the planned **prod→DR backup/restore** (next step); until then private ghcr.io pulls 401.
- **Latent fragility (watch under restore load):** expired projected-SA-token / Calico CNI `Unauthorized` (fix: **restart the calico pods**); one `coredns` replica CrashLooping; intermittent docker.io egress. **Durable clear = a node reboot.** etcd boot-race on reboot → `systemctl restart kubelet`. **Do NOT run disk-loading diagnostics (`dd O_DSYNC`) on the shared etcd disk** — it has crashed the control plane.
- **Monitoring:** `/home/mjbl/dr-health-check.sh` (zero-load etcd `:2381/metrics` + kubectl) runs via the DR host's user crontab every 10 min → `/home/mjbl/dr-health.log` (rising `slow_apply` = I/O contention returning).

## Related
`mjbl-k8s-platform` (estate map) · `mjbl-k8s-production` (the prod fleets DR overlays are derived from) · `mjbl-k8s-facility` (ArgoCD — which DR intentionally bypasses) · `k8s-bare-metal` (how this node was provisioned) · `internal-ca`/`mtls` (CA concepts behind the DR CA).
