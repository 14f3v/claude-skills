# k8s-bare-metal — full gotcha catalog

The complete set of hard-won, known-bad-pattern-avoided idioms baked into `k8s-single-node-cluster-setup.sh` and `k8s-node-cleanup.sh`. The SKILL.md inlines the ~12 that gate a successful run; this file is the debugging reference for everything else. Each entry: the failure mode, then the exact idiom that handles it.

When a phase fails, jump to the matching section. `[severity]` reflects how badly it breaks a run.

## Table of contents
- [Wait / poll / errexit](#wait--poll--errexit)
- [Cluster bring-up](#cluster-bring-up)
- [HA & join](#ha--join)
- [Ingress & Rancher](#ingress--rancher)
- [Node environment (LXC / Proxmox / arch)](#node-environment-lxc--proxmox--arch)
- [Resume, idempotency & sudo](#resume-idempotency--sudo)
- [Security & reproducibility](#security--reproducibility)
- [Cleanup / reset](#cleanup--reset)

---

## Wait / poll / errexit

### G-PIPEFAIL — `grep -v "True" | wc -l` kills the script on success `[critical]`
Under `set -euo pipefail`, a pipeline's status is that of the last command that fails. `grep -v "True"` exits **1 when it finds no non-Ready lines** — i.e. when every pod IS Ready, the success case. pipefail propagates that 1 and `errexit` aborts the run at the instant everything is healthy. This is the "Prevent wait_for_pods crash on successful pipefail" commit.
```bash
NOT_READY=$(kubectl get pods -n "$ns" -l "$label" \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | grep -v "True" | wc -l || true)   # <-- the || true is load-bearing
```

### G-ZEROPOD — "all ready" must not pass on zero pods `[high]`
A naive all-ready check passes when there are **no** pods yet (NOT_READY=0), declaring success before the workload even schedules. `wait_for_pods` first guards existence, then requires both conditions:
```bash
if ! kubectl get pods -n "$ns" -l "$label" &>/dev/null; then echo "not found yet"; ...; fi
[ "$TOTAL" -gt 0 ] && [ "$NOT_READY" -eq 0 ]   # must have pods AND none not-ready
```
Readiness is read from the actual `Ready` **condition** (not phase=Running), because a pod can be Running but failing its readiness probe.

### G-POLL — custom polling loop instead of `kubectl wait` `[high]`
`kubectl wait --for=condition=Ready` errors immediately (and aborts under errexit) if the resource/label doesn't exist yet — guaranteed right after `kubectl apply` before the controller creates pods. Admission webhooks (MetalLB, cert-manager) also reject applies until their pods are Ready. So the script polls in a bounded loop (`timeout=600s`, `interval=10s`) and `sleep 10`s after readiness before applying CRs, to let the webhook settle.

### G-READYREPLICAS — empty-string jsonpath on a fresh Deployment `[high]`
`.status.readyReplicas` is **absent** (not `0`) on a brand-new Deployment, so `jsonpath='{.status.readyReplicas}'` returns `""`, and comparing that empty string can false-positive. (Mechanism note: an *empty* value doesn't trip `set -u` — nounset fires on *unset* variables, and the `$(… || echo "0")` default keeps it always set; the real hazard is the empty-string comparison itself.) The ingress-nginx wait uses defaults + a triple guard:
```bash
READY=$(kubectl get deploy ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED=$(kubectl get deploy ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
[[ "$READY" == "$DESIRED" ]] && [[ "$READY" != "0" ]] && [[ -n "$READY" ]]   # all three required
```

### G-SLEEP — Longhorn uses a blind `sleep 30`, not a readiness wait `[medium]`
After `helm install longhorn … --timeout 15m` the script just `sleep 30`s instead of polling. Helm's `--timeout` blocks on its own readiness so it's usually fine, but a slow image pull can let Phase 8 race a not-ready `longhorn` StorageClass (PVC stuck Pending). If PostgreSQL's PVC won't bind, wait on `longhorn-system` pods before retrying. Hardening: replace the sleep with `wait_for_pods longhorn-system`.

---

## Cluster bring-up

### G-SYSTEMDCGROUP — containerd cgroup driver `[critical]`
`containerd config default` writes `SystemdCgroup=false` but kubelet defaults to the systemd driver; the mismatch makes pods fail to start / kubelet flap.
```bash
sed -i '/^\s*SystemdCgroup\s*=/s/false/true/' /etc/containerd/config.toml
systemctl restart containerd
```

### G-TAINT — remove control-plane taint on single node `[critical]`
kubeadm taints the control-plane `NoSchedule`; on one node nothing schedules until:
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-   # trailing - removes it
```

### G-KUBELET-TLS — metrics-server on self-signed kubelet certs `[high]`
kubeadm kubelet serving certs aren't in the cluster CA, so metrics-server gets `x509: certificate signed by unknown authority`.
```bash
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```
Note: re-applying this **appends a duplicate arg** (not idempotent) — fine because it's checkpoint-guarded to run once. If you hand-re-run it, check for a doubled flag.

### G-CIDR — pod CIDR `10.244.0.0/16` is Flannel's conventional CIDR, used with Calico `[low]`
The script passes `--pod-network-cidr=10.244.0.0/16` (Flannel's conventional value) and installs Calico v3.27.0 via the **non-operator** `manifests/calico.yaml`. In v3.27.0 that manifest ships with `CALICO_IPV4POOL_CIDR` **commented out**, so Calico auto-detects and honors the kubeadm pod CIDR — the `192.168.0.0/16` you'll see in the manifest is only the *commented example*, not an active conflict. So this normally just works. If you ever uncomment/override the pool, set it to `10.244.0.0/16` to match kubeadm.

### G-CERTMGR-CRDS — cert-manager CRDs applied out-of-band `[medium]`
The chart here does **not** install CRDs. They're applied separately with `--validate=false` (the apiserver/old kubectl can reject the large structural schema), and the CRD URL tag **must match** the chart `--version` (both `v1.12.3`):
```bash
kubectl apply --validate=false -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.3/cert-manager.crds.yaml
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.12.3 --timeout 10m
```

---

## HA & join

### G-HA-HOSTS — control-plane endpoint must resolve before init `[high]`
With `--control-plane-endpoint <host>:6443`, kubeadm/etcd try to reach that name during bootstrap; on the first node there's no LB/DNS yet.
```bash
CP_HOST=$(echo "$CP_ENDPOINT" | cut -d: -f1)
grep -q "$CP_HOST" /etc/hosts || echo "$PRIMARY_IP $CP_HOST" >> /etc/hosts   # idempotent
kubeadm init --control-plane-endpoint "$CP_ENDPOINT" --apiserver-advertise-address="$PRIMARY_IP" --upload-certs ...
```

### G-SANS — extra SANs for LB VIP / alternate DNS `[high]`
Without the SAN, clients hitting the API via an LB VIP or alternate name get TLS verification errors. Pass at init (hard to add later without regenerating certs): `--apiserver-cert-extra-sans="name1,ip2,..."`.

### G-EVAL — kubeadm command built as a string + `eval`; SAN quoting is load-bearing `[high]`
The init command is assembled into one string and `eval`'d. A comma-separated SAN list or a `host:port` endpoint gets word-split if the inner quotes are wrong. Each value is wrapped in escaped quotes:
```bash
KUBEADM_INIT_CMD="kubeadm init --control-plane-endpoint \"$CP_ENDPOINT\" --apiserver-advertise-address=\"$PRIMARY_IP\" --upload-certs --pod-network-cidr=10.244.0.0/16"
[ -n "$APISERVER_CERT_EXTRA_SANS" ] && KUBEADM_INIT_CMD="$KUBEADM_INIT_CMD --apiserver-cert-extra-sans=\"$APISERVER_CERT_EXTRA_SANS\""
```
Hardening: prefer an array `kubeadm init "${args[@]}"` over `eval` to eliminate this class of bug.

### G-JOIN — join mode preps the node, then exits `[info]`
`--join` runs after Phase 1 node prep, builds `kubeadm join` (adds `--control-plane --certificate-key` when `--control-plane` is set), sets up kubeconfig for a CP join, and **exits 0** (TOTAL_STEPS=2). Recall a fresh token/hash with `kubeadm token create --print-join-command`; for a CP join, recall the cert-key with `kubeadm init phase upload-certs --upload-certs`.

---

## Ingress & Rancher

### G-RANCHER-404 — ingress class annotation, idempotent + soft-fail `[high]`
If the Rancher ingress isn't claimed by the controller, the host returns nginx `default backend - 404`. The fix is `--overwrite` (idempotent if the annotation already exists) and `|| log_warn` (so a missing-ingress race doesn't abort the run):
```bash
kubectl annotate ingress rancher -n cattle-system kubernetes.io/ingress.class=nginx --overwrite \
  || log_warn "Failed to annotate rancher ingress. Only critical if you see 'default backend - 404'"
```

### G-HOSTNETWORK — bare-metal ingress needs hostNetwork + cluster DNS `[high]`
The baremetal ingress-nginx manifest isn't externally reachable without a cloud LB. Patch both hostNetwork and dnsPolicy atomically (a hostNetwork pod otherwise inherits `Default` dnsPolicy and loses cluster DNS, breaking webhook/Service resolution from the controller), then restart:
```bash
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/hostNetwork","value":true},
       {"op":"replace","path":"/spec/template/spec/dnsPolicy","value":"ClusterFirstWithHostNet"}]'
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```
With MetalLB instead: `kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"<ingress-ip>"}}'`.

---

## Node environment (LXC / Proxmox / arch)

### G-LXC-SWAP — swap disable is best-effort `[high]`
kubelet refuses to start with swap on, but inside LXC `swapoff` fails (host-managed) and would abort under errexit.
```bash
if [ "$(swapon --show 2>/dev/null | wc -l)" -gt 0 ]; then
  swapoff -a 2>/dev/null || echo "WARNING: could not disable swap (normal in LXC; set swap:0 on the Proxmox HOST)"
fi
grep -q swap /etc/fstab 2>/dev/null && sed -i '/swap/d' /etc/fstab   # permanent, guarded
```

### G-LXC-MODULES — modprobe best-effort with a pre-check `[high]`
`modprobe overlay`/`br_netfilter` fails in unprivileged LXC (no `CAP_SYS_MODULE`); modules may already be host-loaded.
```bash
module_loaded(){ lsmod | grep -q "^$1 " || [ -d "/sys/module/$1" ]; }   # trailing space anchors exact name
module_loaded overlay || modprobe overlay 2>/dev/null || echo "WARNING: load 'overlay' on the Proxmox HOST"
```

### G-SYSCTL — `/proc` fallback for read-only container sysctls `[medium]`
`sysctl --system` partially fails in LXC where `/proc/sys` is read-only or bridge keys are absent. Verify by grep, fall back to direct writes:
```bash
if sysctl --system 2>/dev/null | grep -q 'net.ipv4.ip_forward'; then :; else
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ] && echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables || true
fi
```

### G-IP — `get_primary_ip` is fragile to awk field offset `[medium]`
```bash
get_primary_ip(){ ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}'; }
```
Relies on the src IP sitting at `NF-2` in `1.0.0.0 via X dev Y src Z uid 0`. If newer/older iproute2 drops the trailing `uid N`, this grabs the wrong token. If advertise-address / ingress IP is wrong, override or use `hostname -I | awk '{print $1}'`.

### G-ARCH — Helm arch detection hard-fails the unknown `[medium]`
Downloading the wrong-arch Helm tarball yields "cannot execute binary file" much later. The script maps only `x86_64→amd64` / `aarch64→arm64` and `exit 1`s otherwise, verifying the tarball and extracted binary exist before `mv`. On an unusual arch, install Helm manually after node prep.

---

## Resume, idempotency & sudo

### G-CHECKPOINT — exact-line resume gating `[high]`
A 10-phase installer that aborts at phase 7 must not re-run `apt upgrade` or the non-idempotent `kubeadm init`. Phases are gated by an exact whole-line match so `Phase 1` never matches `Phase 10`:
```bash
is_step_complete(){ grep -qFx "$1" "$CHECKPOINT_FILE"; }   # -F fixed string, -x whole line
mark_step_complete(){ is_step_complete "$1" || echo "$1" >> "$CHECKPOINT_FILE"; }
```
Every phase: `if is_step_complete "X"; then log_step "(SKIPPED)"; else …; mark_step_complete "X"; fi`.

### G-RESUME-KUBECONFIG — skipped Phase 2 must re-export KUBECONFIG `[high]`
On resume, phases 3–10 all call `kubectl`. The skipped-Phase-2 branch re-establishes config:
```bash
mkdir -p $HOME/.kube
[ -f /etc/kubernetes/admin.conf ] && cp /etc/kubernetes/admin.conf $HOME/.kube/config && chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config
```
If you hand-run later phases after a failure, export KUBECONFIG yourself first.

### G-TRAP — EXIT trap names the failing step (no rollback) `[medium]`
```bash
trap 'if [ $? -ne 0 ]; then log_error "Script failed at step: $CURRENT_STEP"; log "Check log file: $LOG_FILE"; fi' EXIT
```
`$?` is read first thing in the handler; `$CURRENT_STEP` is set by `log_step`. The trap reports but does **not** clean up — recovery = fix + re-run (checkpoint resumes).

### G-NOUNSET — `${SUDO_USER:-}` under `set -u` `[high]`
`set -u` aborts on unset vars; `SUDO_USER` is unset under `sudo su -` / login root.
```bash
if [[ -n "${SUDO_USER:-}" ]]; then USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6); ...; fi
```

### G-KUBECONFIG-BOTH — kubeconfig for root AND the sudo caller `[medium]`
Running under sudo writes config only to root's home; the operator's own `kubectl` then can't reach the cluster. The script also copies to the sudo user, chowning via `getent`:
```bash
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown $(id -u "$SUDO_USER"):$(id -g "$SUDO_USER") "$USER_HOME/.kube/config"
```

### G-IDEMPOTENT-CREATE — `kubectl create … || true` `[low]`
`create namespace`/`create secret` fail `AlreadyExists` on re-run and abort under errexit; suffixed with `|| true`. The cleaner idiom (use when hardening) is `kubectl create … --dry-run=client -o yaml | kubectl apply -f -`.

### G-TTY — no TTY guard on the per-phase prompts `[medium]`
Prompts are `if [[ "$FORCE_MODE" == false ]]; then read -p …; fi`; `-y|--yes|--force` sets `FORCE_MODE=true`. There's **no** `[ -t 0 ]` detection, so an interactive run piped without `-y` hangs on EOF. **Always pass `-y` for non-interactive / piped / CI runs.**

### G-GPG — `gpg --dearmor` not idempotent across re-runs `[low]`
On a Phase-1 re-run with a lost checkpoint, dearmoring onto an existing keyring can prompt to overwrite. Normally checkpoint-guarded to run once; for true idempotency add `--yes` or `rm -f` the keyring first.

### G-CD — `cd /tmp` for the Helm download is never restored `[low]`
Phase 1 `cd /tmp` and doesn't return; later steps use absolute paths so it's currently harmless. Any relative path after that point would resolve under `/tmp`. Hardening: `wget -P /tmp …` or a `( cd /tmp; … )` subshell.

### G-DUP — duplicated blocks from sloppy merges `[low]`
`mkdir -p "$LOG_DIR"`, the Defaults block, and `INGRESS_IP` fallback appear twice; a "skip-metallb flag set" message references a non-existent flag. The Phase 3 continue-prompt also mislabels the step `network setup (Flannel)` even though **Calico** is what's deployed — a stale string, harmless but confusing if you're reading the live output. Benign overall (idempotent), but when editing, de-dup and fix these labels so the copies don't diverge.

---

## Security & reproducibility

### G-PIN — floating versions break previously-working runs `[high]`
Pinned: Calico `v3.27.0`, Longhorn `1.7.2`, cert-manager `v1.12.3`, MetalLB `v0.13.12`, Helm `v3.16.3`, k8s `v1.31` channel. **Floating:** metrics-server (`releases/latest`), ingress-nginx (`main` branch), Rancher (`latest` server-charts channel), bitnami/postgresql (no `--version`). Suspect these first on a sudden install failure. Pin them for reproducibility:
- metrics-server → `download/<vX.Y.Z>/components.yaml`
- ingress-nginx → `controller-vX.Y.Z` baremetal `deploy.yaml` (not `main`)
- Rancher → `--version` (consider `stable` channel)
- postgresql → `--version` (bitnami's 2024-2025 catalog change can break unpinned installs outright)
- `apt-mark hold kubeadm kubelet kubectl` to stop floating within v1.31.x

### G-DBCREDS — hardcoded weak DB credentials `[medium]`
PostgreSQL/Rancher use literal `rancher` / `rancher#2025` / `rancherdb`, passed on the helm command line and into the tee'd log. The `#` must stay single-quoted or the shell truncates it as a comment. Lab-only; for prod use a generated Secret and keep it off the CLI/log.

### G-PULLSECRET — empty docker-registry pull secret `[low]`
`rancher-registry-secret` is created with single-space username/password/email — a placeholder, not real Docker Hub auth, so it gives no rate-limit relief. Supply real creds if hitting anonymous pull limits.

---

## Cleanup / reset

### G-CLEAN-PARTIAL — tolerate partially-installed state `[high]`
A reset may hit a node missing kubeadm/containerd/CNI; under `set -euo pipefail` the first missing thing aborts cleanup midway. Every destructive op is guarded:
```bash
command -v kubeadm &>/dev/null && (kubeadm reset -f 2>&1 | tee -a "$LOG_FILE" || true)
systemctl stop kubelet 2>/dev/null || true ; systemctl disable kubelet 2>/dev/null || true
apt-get purge -y kubeadm kubelet kubectl kubernetes-cni || true
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /var/lib/cni /etc/cni /opt/cni 2>/dev/null || true
```

### G-CLEAN-ORDER — stop services before purging packages `[high]`
Cleanup runs `kubeadm reset -f` → stop/disable kubelet then containerd → `apt-get purge` → delete config/state. Purging a running kubelet/containerd or removing config before stopping wedges systemd units and orphans mounts.

### G-CLEAN-CALI — sweep dynamic Calico veth interfaces `[medium]`
Calico leaves `caliXXXX` veths plus `tunl0`/`vxlan.calico`; a static delete list misses them and a re-init hits stale routes.
```bash
for i in cni0 flannel.1 docker0 tunl0 vxlan.calico; do ip link delete "$i" 2>/dev/null || true; done   # each guarded
for iface in $(ip link show | grep -oP 'cali[a-f0-9]+' | sort -u); do ip link delete "$iface" 2>/dev/null || true; done
iptables -F; iptables -t nat -F; iptables -t mangle -F; iptables -X
```

### G-CLEAN-CONTAINERD — purge both package names `[medium]`
containerd comes from Docker's repo as `containerd.io`, but a distro `containerd` may also exist. Cleanup purges both and removes the Docker keyring + `docker.list` so a re-run starts clean: `apt-get purge -y containerd containerd.io || true`.

### G-LONGHORN-WIPE — guarded destructive data prompt `[critical]`
Removing `/var/lib/longhorn` destroys ALL persistent volume data. Interactive mode asks a **separate** confirmation (default No); `-y`/`--force` deletes with no prompt. **Never pass `-y` on a node whose Longhorn data matters.**

### G-CLEAN-KUBECONFIG — wipe kubeconfig for root and every `/home/*` user `[low]`
Setup wrote configs to multiple homes; stale configs pointing at a destroyed cluster cause confusing errors. Cleanup removes `$HOME/.kube`, `/root/.kube`, and every `/home/*/.kube` (all `|| true`).
