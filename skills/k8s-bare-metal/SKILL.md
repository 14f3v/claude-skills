---
name: k8s-bare-metal
description: This skill should be used when the user asks to "set up / bootstrap / provision a bare-metal (or on-prem / Proxmox / LXC) Kubernetes cluster", "stand up a single-node k8s cluster with Rancher", "install kubeadm + Calico + Longhorn + Rancher", "set up an HA control-plane node", "join a worker or control-plane node to my cluster", "resume a failed k8s setup", or "reset / clean up / tear down a Kubernetes node". Orchestrates the battle-tested `k8s-single-node-cluster-setup.sh` provisioner (and `k8s-node-cleanup.sh`): kubeadm v1.31 + Calico + Longhorn + metrics-server + cert-manager + optional MetalLB + PostgreSQL + Rancher + ingress-nginx, with checkpoint/resume, LXC-safe node prep, and single-node / HA / join modes. Use it whenever the user wants a working Rancher-managed Kubernetes cluster on their own hardware, even if they don't name the script. Hands off to [[harbor-registry]] for a private registry and [[cicd-platform]] for Argo CD + GitHub Actions runners.
version: 0.1.0
---

# k8s-bare-metal — kubeadm + Rancher cluster bootstrap

You are provisioning a Kubernetes cluster on bare-metal / on-prem / Proxmox-LXC hosts. The output is a working **single-node or HA** cluster running Rancher, built by a single idempotent, resumable Bash provisioner. The script does the heavy lifting; your job is to **pick the right mode and flags, watch the verify gates, and recover cleanly when a phase fails** using the gotchas below.

This is the entry-point skill for the bare-metal stack. After the cluster is up, hand off to **[[harbor-registry]]** (private registry) and **[[cicd-platform]]** (Argo CD + self-hosted runners).

> ⚠️ These scripts are **demo/lab-grade** by the author's own framing: floating versions, hardcoded DB credentials, single Rancher replica. They produce a real working cluster fast, but read the **Production hardening** table before using on anything that matters.

---

## Where the script lives (prefer local, fall back to URL)

The automation is one script: **`k8s-single-node-cluster-setup.sh`** (plus `k8s-node-cleanup.sh` for teardown). All modes are flags on that one script.

1. **Prefer a local `script-helper` checkout** if one is reachable (e.g. the user has the repo, or you cloned it). Run it directly:
   ```bash
   sudo bash <repo>/scripts/k8s-bare-metal/k8s-single-node-cluster-setup.sh <flags>
   ```
2. **Otherwise pull from the published raw URL** (this is what the repo README documents):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/phimasonelabs/script-helper/main/scripts/k8s-bare-metal/k8s-single-node-cluster-setup.sh \
     | sudo bash -s -- <flags>
   ```

The checkpoint lives **on the target host** (`/var/lib/k8s-setup/checkpoint_state`), not in the script, so re-running either form **resumes from where it failed** — see [Recovery](#recovery--resume-on-failure). For repeated debugging on one host, download once (`curl -fsSLo /tmp/k8s-setup.sh <url>`) and re-run the local copy so you're not re-fetching each time.

---

## When to act vs ask first

**Just do it (auto-mode signals):** the user says "cook it" / "ship it" / "run it end-to-end", an auto-mode reminder is active, or they hand you a host + hostname. In auto-mode, pass **`-y`** so the script's per-phase prompts don't hang (see G-TTY).

**Confirm one batched set of params first when ambiguous** — these change the kubeadm invocation and can't be undone without a node reset:
- **Mode**: single-node, HA first control-plane, or join (worker / control-plane)?
- **`--hostname`** (REQUIRED for a fresh cluster) — the Rancher hostname, e.g. `rancher.lab.local`.
- **MetalLB or not**: if they want LoadBalancer IPs, get the **`--iprange`** pool and the **`--ingressip`**. No `--iprange` ⇒ ingress runs in **hostNetwork** mode on the node IP.
- **HA only**: the **`--endpoint`** (the external LB `host:port` fronting the API server) and any extra **`--apiserver-cert-extra-sans`**.
- **DNS reality check**: the Rancher hostname must resolve to the ingress IP (MetalLB IP, or node IP in hostNetwork mode). If there's no DNS, tell them to add an `/etc/hosts` entry on clients.

---

## Modes & required params

| Mode | Invocation | Required | Notes |
|---|---|---|---|
| Single-node + MetalLB | `--hostname H --iprange R --ingressip IP` | hostname, iprange, ingressip | LoadBalancer services get real IPs |
| Single-node, no MetalLB | `--hostname H` | hostname | Ingress uses hostNetwork on the node IP |
| HA first control-plane | `--hostname H --ha --endpoint LB:6443 [--apiserver-cert-extra-sans …]` | hostname, endpoint | Needs an external LB **already** fronting `:6443` |
| Join worker | `--join H:6443 --token T --discovery-token-ca-cert-hash sha256:…` | join, token, hash | Preps the node, then `kubeadm join`, then exits |
| Join control-plane | add `--control-plane --certificate-key K` | + control-plane, certificate-key | HA secondary CP node |
| Non-interactive | add `-y` / `--yes` / `--force` | — | Skips all confirmation prompts (use in automation) |
| Reset / teardown | run `k8s-node-cleanup.sh` | — | See [Cleanup](#cleanup--reset). `-y` also wipes Longhorn data |

After a successful first-node run, the script prints the **worker and control-plane join commands** (and how to recall the certificate-key and mint a fresh token). Capture those to add nodes later.

---

## Phase map

Full single-node run is **10 phases** (9 without MetalLB, 2 in join mode). Each phase is checkpoint-gated, so a resume skips completed ones. Versions are pinned where shown; ⚠️ marks a **floating** (unpinned) component (see G-PIN).

| # | Phase | Installs | Verify gate |
|---|---|---|---|
| 1 | Node prep | k8s v1.31 repo, containerd.io, kube{adm,let,ctl}, Helm **v3.16.3**, swap off, modules, sysctl | `helm version` ok; containerd active; `SystemdCgroup=true` |
| 2 | Control-plane init | `kubeadm init` (+`--control-plane-endpoint`/`--upload-certs` in HA) | `kubectl get nodes` Ready; taint removed; kubeconfig for root **and** sudo user |
| 3 | Calico CNI | Calico **v3.27.0** manifest (non-operator `calico.yaml` → pods land in `kube-system`) | manifest applied (⚠️ **no scripted wait** in Phase 3); CoreDNS/Calico pods go Ready shortly after |
| 4 | Longhorn | Longhorn **1.7.2** (helm, `--timeout 15m`) | `longhorn` StorageClass exists (⚠️ script just `sleep 30`s — see G-SLEEP) |
| 5 | metrics-server | latest ⚠️ + `--kubelet-insecure-tls` patch | `kubectl top nodes` returns data |
| 6 | cert-manager | cert-manager **v1.12.3** (CRDs `--validate=false`, then chart) | cert-manager pods Ready |
| 7 | MetalLB *(if `--iprange`)* | MetalLB **v0.13.12** + IPAddressPool `default-pool` + L2Advertisement | `wait_for_pods metallb-system app=metallb`; pool applied |
| 8 | PostgreSQL | bitnami/postgresql ⚠️ (creds `rancher`/`rancher#2025`/`rancherdb`, 10Gi on `longhorn`) | PVC Bound; pod Ready |
| 9 | Rancher | rancher-latest ⚠️ (external DB, `replicas=1`) | rancher deployment up; ingress object created |
| 10 | ingress-nginx | baremetal manifest from `main` ⚠️ → hostNetwork patch; LB IP if MetalLB | controller `readyReplicas==spec.replicas`; Rancher ingress annotated |

Don't advance past a failing gate — the script's `set -euo pipefail` + checkpoint design means you fix, then re-run to resume.

---

## Filesystem, logging & conventions

```
/var/log/k8s-setup/k8s-setup-<YYYYMMDD-HHMMSS>.log   ← full setup log (tee'd)
/var/log/k8s-setup/k8s-cleanup-<…>.log                ← cleanup log
/var/lib/k8s-setup/checkpoint_state                   ← resume checkpoint (one phase phrase per line)
/etc/apt/keyrings/kubernetes-apt-keyring.gpg          ← k8s v1.31 repo key
/usr/share/keyrings/docker-archive-keyring.gpg        ← Docker repo key (for containerd.io)
/etc/containerd/config.toml                           ← SystemdCgroup=true
/etc/sysctl.d/k8s.conf  /etc/modules-load.d/k8s.conf  ← bridge-nf + overlay/br_netfilter
$HOME/.kube/config  +  <sudo-user>/.kube/config       ← kubeconfig for BOTH users
/usr/local/bin/helm                                   ← Helm v3.16.3
```

- **Pod CIDR** is fixed at `10.244.0.0/16` (Flannel's conventional CIDR, used here with Calico — see G-CIDR).
- **Namespaces**: `kube-system` (Calico + metrics-server), `longhorn-system`, `cert-manager`, `metallb-system`, `postgresql`, `cattle-system`, `ingress-nginx`. (No `calico-system` — that only exists with the Tigera-operator install, which this script doesn't use.)
- **Primary IP** is auto-detected via `ip route get 1` (see G-IP if it picks the wrong NIC).

---

## Critical gotchas

These are the ones that gate a successful run or come up most. The script already handles them — they're here so you understand the behavior and can diagnose fast. **The full ~30-entry catalog with exact code idioms is in [`references/gotchas.md`](references/gotchas.md)** — read it when a specific phase misbehaves.

### G-PIPEFAIL — `wait_for_pods` must not die at the moment of success
The readiness check pipes `kubectl … | grep -v "True" | wc -l`. Under `set -euo pipefail`, when **all** pods are Ready, `grep -v` matches nothing and exits 1, and pipefail aborts the script *exactly when it succeeded*. The fix (already in the script) is the trailing **`|| true`** on that pipeline, plus requiring `TOTAL > 0 && NOT_READY == 0` so zero pods isn't a false pass. If you adapt the wait logic, keep both guards.

### G-SYSTEMDCGROUP — containerd cgroup driver
`containerd config default` ships `SystemdCgroup=false`, but kubelet uses the systemd driver. Mismatch ⇒ pods won't start. The script `sed`s it to `true` and restarts containerd. If kubelet is flapping, verify `grep SystemdCgroup /etc/containerd/config.toml` is `true`.

### G-TAINT — single-node scheduling
kubeadm taints the control-plane `NoSchedule`. On a single node nothing schedules until `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` runs (the script does this after init). If Longhorn/Rancher pods are stuck `Pending` on one node, this taint is the usual cause.

### G-KUBELET-TLS — metrics-server on kubeadm
kubeadm kubelet serving certs are self-signed, so metrics-server can't scrape (`x509: unknown authority`). The script JSON-patches `--kubelet-insecure-tls` onto the deployment. Without it, `kubectl top` and HPA never work.

### G-LXC — Proxmox/LXC node prep is best-effort
Inside an unprivileged LXC container `swapoff`, `modprobe overlay/br_netfilter`, and parts of `sysctl --system` **fail** (those are host-controlled). The script tolerates each (guards + `|| true`, a `module_loaded()` pre-check, and a `/proc` sysctl fallback) and warns you to **set `swap: 0` and load the modules on the Proxmox HOST**. If pod networking is broken in LXC, fix the host first.

### G-HA-HOSTS — HA endpoint must resolve during bootstrap
`kubeadm init --control-plane-endpoint <host>` needs that host to resolve, but on the first node there's no LB/DNS yet. The script seeds `/etc/hosts` with `<PRIMARY_IP> <endpoint-host>` (idempotently) and passes `--apiserver-advertise-address`. If HA init hangs on the endpoint, this entry is missing.

### G-SANS — API server cert extra SANs
Reaching the API via an LB VIP or alternate DNS name needs those names in the cert, or kubectl/agents get TLS errors. Pass them comma-separated via **`--apiserver-cert-extra-sans`** at init time (you can't easily add them later without regenerating certs). These are appended into the kubeadm command — see G-EVAL in the reference for the quoting caveat.

### G-RANCHER-404 — ingress class annotation
If the Rancher hostname returns nginx's **`default backend - 404`**, the Rancher ingress wasn't claimed by the controller. Fix: `kubectl annotate ingress rancher -n cattle-system kubernetes.io/ingress.class=nginx --overwrite`. The script does this soft-failing (`|| warn`), so a missing-ingress race doesn't abort the run — but it's the #1 "Rancher won't load" cause.

### G-HOSTNETWORK — bare-metal ingress
With no cloud LB, the baremetal ingress-nginx won't receive traffic. The script patches the controller to `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` (so cluster DNS still resolves) and restarts it; with MetalLB it instead patches the Service to `LoadBalancer` with `loadBalancerIP=$INGRESS_IP`. Don't "fix" the dnsPolicy back to Default — the controller will lose in-cluster name resolution.

### G-RESUME-KUBECONFIG — resumes must re-export KUBECONFIG
On a resume where Phase 2 is already checkpointed, the script jumps to phases that all use `kubectl`. The skipped-Phase-2 branch re-copies `admin.conf` and re-exports `KUBECONFIG`. If you hand-run later phases after a failure, **`export KUBECONFIG=$HOME/.kube/config` first** or every `kubectl` fails with connection-refused.

### G-PIN — floating versions are a real break risk
Calico, Longhorn, cert-manager, MetalLB are pinned. But **metrics-server (`latest`), ingress-nginx (`main` branch), Rancher (`latest` channel), and bitnami/postgresql (no `--version`)** float. A previously-working run can break when upstream moves — bitnami's 2024-2025 catalog change is a known one. If an install suddenly fails, suspect a floated version first; pin it before retrying (guidance in the reference).

> More gotchas (checkpoint internals, `${SUDO_USER:-}` under `set -u`, `eval`/SAN quoting, helm arch detect, gpg idempotency, `get_primary_ip` fragility, cleanup interface sweep, weak DB creds, empty pull secret, …) are in **[`references/gotchas.md`](references/gotchas.md)**.

---

## Recovery — resume on failure

The script is built to be re-run. When a phase fails:

1. **Read the EXIT-trap line** — it prints `Script failed at step: <phase>` and the log path. The trap does **not** roll back; recovery is "fix the cause, re-run."
2. **Inspect the log** at `/var/log/k8s-setup/k8s-setup-*.log` (the most recent timestamp).
3. **Fix the root cause** (use the matching gotcha — most failures are G-PIN, G-LXC, DNS, or a not-yet-ready add-on).
4. **Re-run the exact same command.** Completed phases are skipped via the checkpoint (`grep -qFx` whole-line match in `/var/lib/k8s-setup/checkpoint_state`), so it picks up at the failed phase. `kubeadm init` is **not** idempotent, so never delete the checkpoint and re-run on a half-initialized node — reset first (below).
5. **If state is corrupted** (half-init, wrong flags baked into certs): run cleanup, then start fresh.

To force a clean re-run of one phase, remove its exact line from the checkpoint file (e.g. `sed -i '/^Phase 5: Setup Metrics Server$/d' /var/lib/k8s-setup/checkpoint_state`).

---

## Cleanup / reset

`k8s-node-cleanup.sh` resets a node to pre-Kubernetes state. It runs in the right order — `kubeadm reset -f` → stop/disable kubelet+containerd → purge packages → delete `/etc/kubernetes`, CNI, containerd state → **sweep all `caliXXXX`/`tunl0`/`vxlan.calico` interfaces** → flush iptables → optional Longhorn wipe — and tolerates partial state (`|| true` throughout), so it's safe on a half-broken node.

```bash
# Interactive (prompts before the destructive Longhorn data wipe):
sudo bash k8s-node-cleanup.sh
# Force, NO prompts — ⚠️ this DELETES /var/lib/longhorn (all PV data):
sudo bash k8s-node-cleanup.sh -y
```

**Never pass `-y` on a node whose Longhorn data matters** (G-LONGHORN-WIPE). After cleanup, a reboot is recommended before re-provisioning.

---

## Production hardening — surface, don't auto-apply

When the demo cluster is up, present these as a deferred to-do list (do not silently change the script's behavior):

| Demo behavior | Production move |
|---|---|
| Floating versions (metrics-server/ingress-nginx/rancher/postgres) | Pin every chart/manifest to a tested tag; `apt-mark hold` the kube packages |
| `pod-network-cidr=10.244.0.0/16` with Calico | Confirm `CALICO_IPV4POOL_CIDR` matches, or use Calico's native CIDR |
| Hardcoded DB creds `rancher#2025` on the helm CLI (and in the log) | Generate a Secret; keep secrets off the command line and out of `tee` logs |
| Rancher `replicas=1`, single node | ≥3 control-plane HA, dedicated workers, leave control-plane tainted |
| `--kubelet-insecure-tls` | Issue proper kubelet serving certs (`serverTLSBootstrap` + approver) |
| ingress-nginx `hostNetwork` | MetalLB/real LB with a dedicated controller Service |
| Empty docker-registry pull secret | Real registry creds to dodge Docker Hub rate limits |
| `sleep 30` after Longhorn | Replace with `kubectl rollout status` / `wait_for_pods` on `longhorn-system` |

---

## Handoffs

After the cluster is up and Rancher loads over HTTPS:
- User mentions a **private registry / Harbor / "push images internally"** → invoke **[[harbor-registry]]** (it assumes this cluster + ingress-nginx exist).
- User mentions **GitOps / Argo CD / self-hosted GitHub Actions runners / CI** → invoke **[[cicd-platform]]** (it assumes the cluster and, for image push, Harbor exist).
