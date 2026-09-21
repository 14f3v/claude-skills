---
name: mjbl-k8s-facility
description: This skill should be used when the user asks to operate the MJBL FACILITY cluster or ArgoCD — "where does ArgoCD run", "the facility cluster", "register / create / sync / inspect an ArgoCD Application", "deploy via ArgoCD", "why is my facility kubectl failing with an x509 / certificate SAN error", "which destination.server for prod vs UAT" — AND for facility CLUSTER-level faults & recovery: the 3-node etcd layout, a facility node down / not pinging / post-reboot recovery, SSH node access, the **post-reboot rebalance** (workloads never return to a rebooted node), the **mjcr DNS round-robin trap** (a node without an ingress replica silently fails ~1-in-3 registry pulls), the **CI-runner placement rule** (never schedule runners on `mjbl-cicd`), the **Harbor postgres SPOF**, post-reboot **sanitize** (NodeLost/`Unknown` pods, stuck `VolumeAttachment`), **Longhorn `degraded` volumes** (incl. a replica stranded on a cordoned node), an ArgoCD app stuck **`OutOfSync`** (the `Replace=true` / bound-PVC trap), and the **mis-airflow deploy model** (tag→ArgoCD manifests vs Release→image).
version: 0.3.0
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
Cluster is k8s **1.31** (v1.31.13). The `argocd` CLI (`v3.4.3`) + `~/.argocd-credential` are also present for API access to `argocd.vte.mjblao.local`.

⚠️ **zsh does not word-split `$VAR`.** `K="kubectl …"; $K get nodes` fails with *"no such file or directory"*. Use a function:
```bash
k() { kubectl --kubeconfig="$HOME/.kube/mjbl-facility.config" \
        --server=https://10.88.101.35:6443 \
        --tls-server-name=registry.k8sapi.local --request-timeout=30s "$@"; }
```

## Cluster shape — THREE nodes / three etcd members
Verified live 2026-09-21. All three are `control-plane+etcd+worker` (Ubuntu 24.04, containerd):

| Node | IP | ssh alias | Notes |
|---|---|---|---|
| `mjbl-registry` | `10.88.101.35` | `mjbl-facility-n01` | tz **Asia/Vientiane** |
| `mjbl-cicd` | `10.88.101.36` | `mjbl-facility-n02` | tz **Asia/Vientiane** — the **HOT** node, most etcd-strained |
| `k8s-fc-033` | `10.88.101.38` | `mjbl-facility-n03` | joined 2026-08-27, tz **Etc/UTC**, **cordoned** |

**Quorum is now 2/3 — a single node loss no longer kills the control plane.** (Historical: this used to be a 2-member etcd with zero fault tolerance; the 3rd node added 2026-08-27 fixed it, and is why the 2026-09-17 registry reboot and the 2026-09-21 `mjbl-cicd` NotReady event were both survivable.)

The API DNS `k8sregistry.vte.mjblao.local` **round-robins to `.35`, `.36` and the ingress VIP `.190`**, so kubectl can land on a sick node — pin a known-good one with `--server=https://10.88.101.35:6443 --tls-server-name=registry.k8sapi.local`. Probe from the ops box (it CAN route to `10.88.101.x`): `curl -k -m6 https://10.88.101.35:6443/livez` (`200` = healthy; a slow/`500`/`000` answer means that node is struggling — try the others).

**Node down:** boot it back. With 3 members, etcd reforms quorum automatically. Never reach for `etcdctl member remove` or `force-new-cluster` while 2 of 3 are alive.

⚠️ **Mixed node timezones.** `uptime -s` prints **local** time; two nodes are UTC+7 and one is UTC. Always convert before correlating a boot time with pod/event timestamps — this will silently invert an incident timeline.

## Node labels — and the one that lies
```bash
k get nodes -L ci-runner -L mjbl-network/egress
```
| Label | Where | Meaning |
|---|---|---|
| `mjbl-network/egress=allowed` | `mjbl-registry`, `mjbl-cicd` | — |
| `mjbl-network/egress=denied` | `k8s-fc-033` | **declared policy — ENFORCED BY NOTHING** |
| `ci-runner=true` | `mjbl-registry` only (since 2026-09-21) | RunnerDeployment `mjbl-k8s` `nodeSelector` |

🚨 **`mjbl-network/egress` is decorative.** There are zero Calico `GlobalNetworkPolicies`, zero Calico `NetworkPolicies` and zero `HostEndpoints` in the cluster, and no k8s `NetworkPolicy` references it. `k8s-fc-033` in fact has **full egress** (docker.io / ghcr.io / api.github.com all reachable from host *and* pod). Treat the label as an intent record, never as a guarantee — and **verify egress empirically** before concluding a workload failed for lack of it:
```bash
k -n <ns> exec <pod-on-that-node> -- sh -c \
  'curl -s -o /dev/null -m8 -w "%{http_code}\n" https://registry-1.docker.io/v2/'   # 401 = reachable
```
If the policy is ever made real, it must exempt the cluster CIDR `10.244.0.0/16`, node CIDR `10.88.101.0/24`, **DNS** (coredns forwards to `/etc/resolv.conf` → breaks external resolution otherwise), NTP, and the internal registries `mjcr.`/`github.vte.mjblao.local`.

## 🚨 CI-runner placement — never on `mjbl-cicd`
RunnerDeployment `mjbl-k8s` (ns `actions-runner-system`, org `mjbl-digital`, ARC + HorizontalRunnerAutoscaler min 1 / max 4) is **DIND**: `limits cpu 4 / mem 6Gi` **plus an 18Gi `docker-graph` emptyDir** (~38Gi ephemeral needed). Its image is `mjcr.vte.mjblao.local/ghcr/actions-runner-controller/actions-runner-controller/actions-runner-dind:*` — pulled from **internal Harbor**, so a runner never needs internet egress just to *start*.

**Proven failure (2026-09-21):** labelling `mjbl-cicd` `ci-runner=true` let one queued Dart/Java build land there → **load 189** on 8 cores, mem 14.1/15.9 GB, SSH refusing connections, apiserver `500` → node **`NotReady`** → `postgresql-0` (Harbor's DB, see below) died with `Input/output error` → **`mjcr` returned 503**. Recovery: remove the label, delete the runner pod; the node self-recovers in ~2 min.

- **Keep `ci-runner=true` on `mjbl-registry` only.** It has the headroom (~44% mem, 139G free).
- `k8s-fc-033` is cordoned and `egress=denied` — **do not** put CI there.
- The selector has **no tolerations and (historically) one eligible node**, so cordoning that node = a **silent total CI outage**. It ran 3d15h that way with 1049 `FailedScheduling` events and no alert. Check with:
  ```bash
  k -n actions-runner-system get pods -o wide     # a Pending runner = CI is down
  k get nodes -l ci-runner=true
  ```
- A runner pod's GitHub **registration token expires in ~1h** — a long-Pending pod will never register even once it schedules. **Delete it** and let ARC mint a fresh one. Healthy end state:
  ```bash
  k -n actions-runner-system logs deploy/actions-runner-controller -c manager --tail=5 | grep num_runners_registered   # >0
  k -n actions-runner-system logs <runner-pod> -c runner | grep -E 'Connected to GitHub|Listening for Jobs'
  ```

## 🚨 The `mjcr` DNS round-robin trap (silent ~1-in-3 registry failures)
`mjcr.vte.mjblao.local` (internal Harbor) has **three A records: `10.88.101.35`, `.36`, `.190`** (the MetalLB VIP). `k8sregistry.` and `artifacts.mjcr.` resolve to the same three. **No hostname resolves to `.38`.**

`ingress-nginx-controller` is **`hostNetwork: true`, 2 replicas** — a node only answers `:443` while *hosting* an ingress pod. After `mjbl-registry` rebooted on 2026-09-17 its ingress replica never came back, so `.35` returned `000` **while still being served in DNS → roughly 1 in 3 internal registry pulls failed estate-wide for 3+ days**, presenting as random "workload error loops". Check after **any** node reboot or drain:
```bash
for ip in 10.88.101.35 10.88.101.36 10.88.101.190; do
  printf "%s -> " "$ip"; curl -sk -o /dev/null -m6 -w '%{http_code}\n' \
    --resolve "mjcr.vte.mjblao.local:443:$ip" https://mjcr.vte.mjblao.local/v2/
done    # all three MUST be 401; 000 = that node has no ingress pod
```
Fix = `k -n ingress-nginx rollout restart deploy/ingress-nginx-controller` (cordon any node you don't want replicas on first). Verified **zero-downtime** (59/59 VIP probes stayed `404`). A transient `FailedScheduling … didn't have free ports` mid-roll is expected — hostNetwork needs a node with `:80/:443` free for the surge pod.

## Post-reboot rebalance — workloads do NOT come home
Kubernetes never reschedules **Running** pods, so a rebooted/drained node stays empty indefinitely. After the 2026-09-17 reboot the split was `mjbl-cicd` **58** / `k8s-fc-033` **32** / `mjbl-registry` **16**, leaving ArgoCD 7/7 on one node and neither coredns nor ingress on `mjbl-registry`. Check and fix:
```bash
k get pods -A -o custom-columns='NODE:.spec.nodeName,PHASE:.status.phase' --no-headers \
  | grep -v Succeeded | awk '{print $1}' | sort | uniq -c | sort -rn
```
Rebalance by **rolling restart**, one at a time, waiting for `rollout status` between each — **never `kubectl drain`** (it evicts healthy pods for no reason):
```bash
k -n kube-system    rollout restart deploy/coredns
k -n ingress-nginx  rollout restart deploy/ingress-nginx-controller     # hostNetwork — alone, watch the VIP
k -n argocd         rollout restart deploy/argocd-repo-server deploy/argocd-server
k -n argocd         rollout restart statefulset/argocd-application-controller
k -n harbor         rollout restart deploy/harbor-core deploy/harbor-registry deploy/harbor-portal
```
**Skip `harbor-jobservice`** — single replica on an RWO Longhorn PVC; restarting it risks the Multi-Attach / stuck-VolumeAttachment trap for no gain. `harbor-core` / `harbor-registry` / `harbor-portal` have **no PVCs** (object storage via MinIO `10.88.101.192`), so they move cleanly.

## 🚨 Harbor's database is a single-replica SPOF
`cattle-system-dbfacility/postgresql-0` — a StatefulSet on RWO Longhorn PVC `data-postgresql-0`. **Any node loss where it sits takes the whole internal registry down** (both `harbor-core` replicas go 0/1 → `mjcr` 503). Recovery when it crash-loops with `Input/output error` on `postmaster.pid` (wedged mount after a node stall):
```bash
k -n cattle-system-dbfacility delete pod postgresql-0     # forces a clean unmount/remount
```
Expect a transient `Multi-Attach error` / *"volume is not ready for workloads"* for ~80s, then it attaches and starts. Also note it pulls **`registry-1.docker.io/bitnami/postgresql:latest`** — an unpinned tag on a chart Bitnami has paywalled; pin it and mirror into Harbor. Redis (`storage-facility`) is a related dependency; `redis-replicas-0` has been CrashLoopBackOff for 40d+ (pre-existing).

## ArgoCD topology (critical)
ArgoCD runs HERE and deploys to **other** clusters registered as external clusters — so an Application's `destination.server` is the **target** cluster, never `https://kubernetes.default.svc` (which = facility):

| Target | `destination.server` |
|---|---|
| **prod (rkek8s)** | `https://rkek8s.vte.mjblao.local:6443` |
| **UAT** | `https://192.168.1.65:6443` |

Registered clusters (`get secret -n argocd -l argocd.argoproj.io/secret-type=cluster`): `rkek8s.vte.mjblao.local:6443`, `192.168.1.65:6443`, and `10.88.101.31:6443` — the third is **rkek8s registered again by node-IP**; always use the DNS name. Prod **Application** names to mirror: `mjbl-mtls-gateway`, `mjbl-mtls-enrollment`, `mjbl-mtls-portal`, `microloan-system-podntnyx`, `prod.gold-price-service`, `mjbl-api-gateway`, `agency-v2-uat-gateway`. The lone facility-self app `mis-airflow` is the one place `destination.server: https://kubernetes.default.svc` is correct.

⚠️ **UAT apps sit at `Sync: Unknown` — known and expected.** 7 apps (`approval-form-system-uat`, `partner-payment-system-uat`, `itdprofiler-alert-service-uat`, `uat.gold-price-service`, `uat.gold-price-service-web`, `mjbl-individual-sit`, `mjbl-individual-uat`) report `dial tcp 192.168.1.65:6443: i/o timeout`. **`192.168.1.65` is fully dark** — no ping, no `:22`, no `:6443` from the Mac, the ops box, *or* any facility node. This is the UAT host being down, **not** an ArgoCD fault. Do not chase it as a facility problem.

**`mis-airflow` deploy model — TWO mechanisms (don't conflate):** (1) **manifests → ArgoCD pull**: source is the `apache_airfllow` repo with **`targetRevision: v*`**, so ArgoCD resolves the latest `v0.0.N` git **tag** and applies `k8s/fleet/prod/*` — **a plain tag push deploys the manifests; no GitHub Action involved.** (2) **image → GitHub Actions push**: `.github/workflows/deploy-prod.yml` fires on a **published GitHub Release** (NOT a tag) and builds/pushes `customer-profile-airflow`. So a **config/manifest-only** change needs only a `v*` **tag**; a **code/DAG/Dockerfile** change needs a **Release** (which also creates the tag → does both).

## Inspect apps
```bash
k -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEST:.spec.destination.server,PATH:.spec.source.path'
```
(Use the **full** `applications.argoproj.io` — bare `app` can collide with Rancher's `apps.catalog.cattle.io`. Don't `head` the list and draw conclusions from a truncated count.)

## Register a new Application (user-authorized prod write)
Each `k8s-config` app dir carries `argocd/application.yaml`, applied **manually to facility ArgoCD** (NOT auto-discovered — there is no app-of-apps):
```bash
k apply -f deployments/<service>/argocd/application.yaml
```
**Prerequisite:** the manifests must already be on `main` or ArgoCD syncs a stale state.

## Node access (SSH) + post-reboot sanitize
`mjbl@10.88.101.35` (and `.36`/`.38`) has **key auth + a cluster-admin `~/.kube/config`**; on-node `kubectl` works. **No passwordless sudo** → no root/etcd/`crictl` surgery. After a node reboots + rejoins:
- **NodeLost / `Unknown` pods** — often self-recover; else `kubectl delete pod` (esp. a `Recreate`/replicas-1 Deployment like `airflow-scheduler`, which won't respawn until the ghost is gone).
- **Stuck `VolumeAttachment`** (pod `ContainerCreating`, "volume attachment is being deleted", Longhorn volume healthy but the k8s VA wedged): `kubectl delete volumeattachment <csi-name> --wait=false`, then `kubectl patch <same> --type=merge -p '{"metadata":{"finalizers":null}}'`, then delete the pod. Safe for RWO / single-consumer / same-node.
- **Re-run the `mjcr` round-robin check above** and **rebalance** (both sections above).

## Longhorn `degraded` — three distinct causes
Diagnose with the engine's `replicaModeMap` before touching anything:
```bash
k -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,NODE:.status.currentNodeID'
k -n longhorn-system get engines.longhorn.io \
  -o custom-columns='VOLUME:.spec.volumeName,MODEMAP:.status.replicaModeMap,REBUILD:.status.rebuildStatus'
```
1. **A real rebuild** — a **`WO`** replica present. Just needs time; leave it alone. Self-heals.
2. **Replica stranded on a cordoned node** — a replica with `failedAt` on a node Longhorn marks `Schedulable: False` (a k8s cordon propagates to `nodes.longhorn.io`). Longhorn will **not** replenish on its own; `rebuildStatus` stays empty. Confirm the surviving replica is the engine's `RW` one, then delete the failed replica to trigger replenishment:
   ```bash
   k -n longhorn-system get replicas.longhorn.io \
     -o custom-columns='NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState,FAILEDAT:.spec.failedAt' | grep <vol-id>
   k -n longhorn-system delete replicas.longhorn.io <the one with a failedAt>
   ```
   A fresh replica appears on a schedulable node within ~1 min and both go `RW`. (Done 2026-09-21 for `pvc-f9ad1004-…` / postgres.) Note `replica-replenishment-wait-interval` is **600s**.
3. **The 3-replica-on-2-node trap** — all replicas `RW`, `rebuildStatus={}`, condition `Scheduled=False`, and `spec.numberOfReplicas` > schedulable node count. Longhorn's 1-replica-per-node anti-affinity makes the extra permanently unschedulable. Live fix, no data movement:
   ```bash
   k -n longhorn-system patch volumes.longhorn.io <vol> --type=merge -p '{"spec":{"numberOfReplicas":2}}'
   k -n longhorn-system patch settings.longhorn.io default-replica-count --type=merge -p '{"value":"2"}'
   ```

## ArgoCD app stuck `OutOfSync` on a bound PVC (the `Replace=true` trap)
An app with app-level `syncOptions: Replace=true` and a standalone, dynamically-bound PVC tries to `kubectl replace` the PVC every sync and **fails** on the immutable `spec.volumeName` → stuck `OutOfSync` but **non-destructive** (replace errors *before* any delete → PVC stays `Bound`, `Health=Healthy`). A resource-level `argocd.argoproj.io/sync-options: Replace=false` does **nothing** — ArgoCD only checks for the literal presence of `Replace=true`. FIX = remove app-level `Replace=true`, **then trigger one sync** (an app with `automated` but no `selfHeal` won't auto-retry a `Failed` op):
```bash
k -n argocd patch application <app> --type=merge -p '{"spec":{"syncPolicy":{"syncOptions":["CreateNamespace=true"]}}}'
k -n argocd patch application <app> --type=merge -p '{"operation":{"initiatedBy":{"username":"ops"},"sync":{"syncStrategy":{"apply":{}}}}}'
```
**Lesson: never put `Replace=true` on an app containing a dynamically-bound PVC.**

## etcd health reality
`mjbl-cicd` is by far the most strained member — ~**410** `apply request took too long` per 2000 log lines vs ~27 (`mjbl-registry`) and ~11 (`k8s-fc-033`). `mjbl-registry`'s high **restart count is historical** (accrued over 320d, largely the old 2-member era), not current instability. No alarms, no leader churn, no fsync warnings on any member. DB ~662 MB allocated / ~312 MB in use (~350 MB reclaimable → defrag is housekeeping, not urgent). All nodes report `rotational=1` (hypervisor not advertising SSD) — uniform, so not a differentiator.
```bash
for n in mjbl-registry mjbl-cicd k8s-fc-033; do
  printf "etcd-%s: " "$n"; k -n kube-system logs "etcd-$n" --tail=2000 | grep -c 'apply request took too long'
done
```

## Gotchas
- Missing `--tls-server-name=registry.k8sapi.local` → x509 SAN error on every call.
- `$K="kubectl …"` string variables **don't word-split in zsh** — use a shell function.
- **Ready ≠ working.** Every Deployment can be `Available` while `mjcr` fails 1-in-3 (ingress gap) or CI is dead (Pending runner). Check the round-robin and `get pods -A | grep Pending` explicitly.
- `destination.server: https://kubernetes.default.svc` in an Application → wrongly targets facility.
- App "registered" but never deploys → manifests aren't on `main`, or the destination cluster isn't registered.
- `ai.` / `maas-admin.vte.mjblao.local` have Ingress objects but **no DNS records** even internally — the LLM platform is unreachable by hostname (pre-existing; see `mjbl-llm-platform`).
- DR is **not** managed by the facility ArgoCD — it runs its OWN local Rancher CD (Fleet); see `mjbl-k8s-dr`.
- **No alerting** on Pending pods or node load — both 2026-09 failures were silent for days. Worth adding.

## Related
`mjbl-k8s-platform` (map) · `mjbl-k8s-production` · `mjbl-llm-platform` · `cicd-platform` (installing ArgoCD fresh) · memory `mjbl-facility-3-node-topology`, `mjbl-facility-cicd-node-fragility`, `mjbl-facility-mjcr-dns-roundrobin`.
