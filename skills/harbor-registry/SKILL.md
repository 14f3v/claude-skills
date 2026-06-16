---
name: harbor-registry
description: This skill should be used when the user asks to "install Harbor", "set up a private container registry", "deploy Harbor on my Kubernetes cluster", "give the cluster its own image registry with TLS", "create a Harbor Root CA and TLS cert", or "make my k8s nodes trust the registry CA". Also triggers on Harbor failure symptoms: "x509 / unknown authority pulling from Harbor", "Harbor returns default backend 404", "Harbor data disappears after restart", or "change the Harbor admin password". Orchestrates the `harbor-infra/` pipeline (00-prereqs → 01-create-harbor-ca → 02-install-harbor): a self-signed 2-cert PKI (Root CA + SAN leaf via openssl) loaded as k8s secrets, then the upstream Harbor Helm chart behind NGINX ingress. Assumes a working cluster from [[k8s-bare-metal]] (cluster + ingress-nginx). Feeds its CA to [[cicd-platform]] so CI runners can push images. Use it whenever the user wants a private registry on their own cluster, even if they don't name Harbor.
version: 0.1.0
---

# harbor-registry — private Harbor registry with self-signed CA

You are deploying a Harbor container registry onto an existing bare-metal Kubernetes cluster, fronted by NGINX ingress with TLS terminated by a **dedicated self-signed Harbor Root CA**. The flow is a 3-step pipeline: verify tools → generate a Root CA + SAN leaf cert with raw `openssl` → load them as secrets and `helm install` Harbor from a templated values file.

The single most important consequence of the self-signed design: **the CA is not trusted by anything until you install it on every node's container runtime** (and into any CI runner). Harbor deliberately does **not** use cert-manager here.

This skill assumes the cluster is already up via **[[k8s-bare-metal]]** (it needs the cluster + the hostNetwork ingress-nginx). It produces the Root CA that **[[cicd-platform]]**'s runner must trust to push images.

> ⚠️ Demo/lab defaults: unpinned chart, `harborAdminPassword: ChangeThisPassword123!`, `persistence.enabled: false` (data is **ephemeral**). Change these before any real use — see the gotchas.

---

## Where the scripts live (run from a local checkout)

The scripts use **relative paths** (`./harbor-cert`, `values/harbor-values.tpl.yaml`), so unlike the cluster bootstrap they **cannot be piped from a raw URL** — they must run from inside the `harbor-infra/` directory. Use a local `script-helper` checkout (clone it if needed):

```bash
cd <repo>/scripts/k8s-bare-metal/harbor-infra
./00-prereqs-check.sh
./01-create-harbor-ca.sh <harbor-domain>     # e.g. mjcr.vte.mjblao.local  → writes ./harbor-cert/
./02-install-harbor.sh   <harbor-domain>     # same hostname; renders values, installs chart
```
Run **01 and 02 from the same directory** or secret creation / template rendering breaks (H-RELPATH).

---

## When to act vs ask first

**Confirm before running:**
- **Harbor domain/hostname** — the FQDN clients and nodes will use (e.g. `mjcr.vte.mjblao.local`). It becomes the leaf cert CN, the ingress host, and the `certs.d` path on every node. Pick it once and keep it consistent everywhere.
- **DNS/hosts**: the domain must resolve to the ingress IP (MetalLB IP or node IP). No DNS ⇒ add `/etc/hosts` entries on every node and client.
- **Org fields** for the CA subject (default `/C=LA/ST=Vientiane/O=MJBL/CN=Harbor-Root-CA`) — change `C/ST/O` to the user's org if they care; CN stays `Harbor-Root-CA`.
- **Persistence**: confirm whether they want durable storage. The default is **ephemeral** (H-EPHEMERAL); for a real registry set `persistence.enabled: true` before install. The template has **no `storageClass` key**, so Harbor falls back to the cluster's default StorageClass — point it at `longhorn` (from [[k8s-bare-metal]]) or another class.
- **Admin password**: change `harborAdminPassword` from the placeholder (H-ADMINPW).

---

## Phase map

| # | Step | What it does | Verify gate |
|---|---|---|---|
| 0 | Prereqs | `command -v kubectl helm openssl` | all three present |
| 1 | Create CA | 4096-bit Root CA (self-signed, 3650d, `CN=Harbor-Root-CA`) + 4096-bit leaf signed with SAN `req_ext`, into `./harbor-cert/` | `openssl x509 -in harbor-cert/tls.crt -noout -text` shows correct SANs |
| 2 | Secrets + install | ns `harbor` (auto-created if absent); TLS secret `harbor-tls` + generic `harbor-ca` (both via `--dry-run=client \| apply`, idempotent); render `{{HOSTNAME}}` → `/tmp/harbor-values.yaml`; `helm upgrade --install harbor harbor/harbor -n harbor` | Harbor pods Ready; `curl -k https://<domain>` responds |
| 3 | **Trust CA (manual)** | the script only **prints** these — you must run them on **every node** | `crictl pull`/`docker pull` from Harbor succeeds without x509 error |

The trust step (the load-bearing one) on **each** node:
```bash
sudo cp harbor-cert/ca.crt /usr/local/share/ca-certificates/harbor-ca.crt
sudo update-ca-certificates
sudo systemctl restart containerd docker
```

---

## Conventions

```
./harbor-cert/          ca.key ca.crt ca.srl openssl.cnf tls.key tls.csr tls.crt   (RELATIVE to cwd)
values/harbor-values.tpl.yaml → sed {{HOSTNAME}} → /tmp/harbor-values.yaml
namespace:  harbor
secrets:    harbor-tls (kubernetes.io/tls)   harbor-ca (generic, key ca.crt)
helm:       repo+release+chart all named "harbor"  (https://helm.goharbor.io)
node trust: /usr/local/share/ca-certificates/harbor-ca.crt   (then update-ca-certificates)
CI trust:   /etc/docker/certs.d/<harbor-domain>/ca.crt        (consumed by cicd-platform)
```
Defaults: RSA 4096, sha256, **3650-day** validity for both CA and leaf; `expose.type: ingress`, `expose.tls.secretName: harbor-tls`; ingress `core` and `registry` hosts both `{{HOSTNAME}}`; annotations `proxy-body-size: 0`, `proxy-buffering: off`, read/send timeouts 600.

---

## Critical gotchas

### H-TRUST — the self-signed CA must be installed on EVERY node (script only prints it) `[critical]`
Harbor terminates TLS with a private CA the cluster doesn't trust, so containerd/docker on each node fail to pull/push with `x509: certificate signed by unknown authority`. Step 02 **echoes** the trust commands but never runs them and never loops over nodes. Run the three-command trust block (above) on **every** node, then restart the runtime. The CI runner does the equivalent in an initContainer (see [[cicd-platform]]).

### H-ADMINPW — hardcoded admin password `[critical]`
The values template ships `harborAdminPassword: ChangeThisPassword123!` in clear text. Override before install (`--set harborAdminPassword=…` or edit the template). Treat the default as a placeholder, not a secret.

### H-EPHEMERAL — `persistence.enabled: false` means data is lost on restart `[high]`
All Harbor data (images, DB, config) lives in pod ephemeral storage and is **gone** on pod reschedule. Fine for a smoke test, catastrophic for a real registry. Set `persistence.enabled: true` for anything durable — the template has no `storageClass` key, so Harbor uses the cluster's default StorageClass; add/point one at `longhorn` (from [[k8s-bare-metal]]).

### H-UNPINNED — Harbor chart version is not pinned `[high]`
`helm upgrade --install harbor harbor/harbor` has no `--version`, so it pulls the **latest** chart from `helm.goharbor.io`. Re-running later can silently jump a major version (schema/migration surprises). Pin `--version <x.y.z>` to a known-good chart.

### H-RELPATH — all cert/values paths are relative to cwd `[high]`
`OUTDIR=./harbor-cert`, `CERT_DIR=./harbor-cert`, and `sed … values/harbor-values.tpl.yaml`. Running 02 from a different directory than 01, or outside `harbor-infra/`, breaks secret creation (missing cert files) or template rendering. Always run both from `harbor-infra/` and don't relocate `./harbor-cert` between steps.

### H-SAN — wildcard SAN strips only the first label `[medium]`
`DNS.2 = *.$(echo "$DOMAIN" | cut -d. -f2-)` — for `mjcr.vte.mjblao.local` this yields `*.vte.mjblao.local`. The wildcard doesn't cover the apex (that's `DNS.1`) and doesn't match multi-level subdomains. Verify the SANs match your host: `openssl x509 -in harbor-cert/tls.crt -noout -text | grep -A1 'Subject Alternative Name'`. `DNS.1` must equal the exact Harbor hostname.

### H-EKU — leaf cert has no explicit `serverAuth` EKU `[medium]`
The leaf carries only `subjectAltName` via `req_ext`; there's no explicit `keyUsage`/`extendedKeyUsage = serverAuth`. Lenient clients accept it, but strict TLS clients may reject a server cert lacking `serverAuth`. If a client rejects it, add `keyUsage`/`extendedKeyUsage = serverAuth` to `[req_ext]` in `openssl.cnf` and re-sign.

### H-NOCERTMGR — does not use cert-manager despite it being in the cluster `[medium]`
Operators assume cert-manager (installed by the cluster stack) manages/renews Harbor's cert. It does **not** — these are hand-signed openssl certs with a 10-year life and no auto-renewal; no Issuer/Certificate resources exist for Harbor. Renewal = re-run step 01 and re-create the secrets.

### H-CIDOMAIN — the CI runner hardcodes the example domain `[medium]`
`[[cicd-platform]]`'s `runner-deployment.yaml` hardcodes `/etc/docker/certs.d/mjcr.vte.mjblao.local` and `harbor-ca-secret.yaml` has a `<BASE64_OF_HARBOR_CA>` placeholder. Reusing with a different Harbor hostname means editing **both** the `certs.d` path and the base64'd `ca.crt`. Keep the Harbor domain consistent across this skill and the CI layer.

### H-OPENSSL — step 01 may prompt to apt-install openssl `[low]`
If `openssl` is missing, `01-create-harbor-ca.sh` itself runs `read -p "Install missing dependencies? [Y/n]"` then `sudo apt update && sudo apt install -y openssl` — separate from the 00 prereq check. That **hangs a piped/non-interactive run** and fails on non-Debian distros or without sudo. Pre-install openssl (the 00 check already verifies it) so step 01 never prompts.

---

## Verify & troubleshoot

- After install: `kubectl get pods -n harbor` all Ready (there's **no** scripted readiness gate — check manually), then `curl -k https://<domain>/api/v2.0/health`.
- `x509: unknown authority` on a node ⇒ H-TRUST not done on that node.
- `default backend - 404` ⇒ ingress not claimed (same class-annotation issue as the cluster's Rancher ingress; check `kubectl get ingress -n harbor`).
- Pull from a CI runner fails ⇒ wrong `certs.d` hostname/port (H-CIDOMAIN) — see [[cicd-platform]].

---

## Handoff

Once Harbor is up and its CA is trusted on the nodes, the CA (`harbor-cert/ca.crt`) is the input to **[[cicd-platform]]**: it must be base64'd into that layer's `harbor-ca` secret so the self-hosted runner can push images. Invoke **[[cicd-platform]]** when the user wants Argo CD / GitHub Actions runners.
