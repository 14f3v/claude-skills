---
name: cicd-platform
description: This skill should be used when the user asks to "install Argo CD", "set up GitOps on my cluster", "deploy a self-hosted GitHub Actions runner on Kubernetes", "install the actions-runner-controller (ARC)", "set up the CI/CD layer", or "make my CI runner trust the Harbor registry". Also triggers on symptoms: "my runner pod is stuck in ContainerCreating / FailedMount harbor-ca", "the runner won't register with my GitHub org", "x509 / certificate error pushing images to Harbor from CI", or "get the Argo CD initial admin password". Orchestrates the `cicd-infra/` pipeline (00-prereqs → 01-install-argocd → 02-install-actions-runner): Argo CD from the upstream manifest, plus ARC + a Docker-in-Docker RunnerDeployment that trusts the private Harbor CA. Assumes a working cluster from [[k8s-bare-metal]] and a registry from [[harbor-registry]]. Use it whenever the user wants GitOps or self-hosted CI runners on their own cluster, even if they don't name Argo CD or ARC.
version: 0.1.0
---

# cicd-platform — Argo CD + self-hosted GitHub Actions runners

You are installing the CI/CD layer on top of an existing bare-metal cluster: **Argo CD** (GitOps CD) and a **self-hosted GitHub Actions runner** (via the actions-runner-controller / ARC) that runs Docker-in-Docker and trusts the private Harbor registry's CA so CI jobs can push/pull images over TLS.

This is the top layer. It assumes the cluster from **[[k8s-bare-metal]]** and the registry from **[[harbor-registry]]** already exist. Two prerequisites are **not** provisioned by any script here and are the usual reasons a runner never comes up — surface them before running (C-CASECRET, C-GHAUTH).

> ⚠️ Demo/lab posture: the runner is **privileged DinD with Docker TLS disabled** (a real security surface — C-PRIV), Argo CD tracks a floating branch, and the org/registry names are hardcoded. Read the gotchas before using beyond a lab.

---

## Where the scripts live (run from a local checkout)

Step 02 applies `runner/runner-deployment.yaml` by **relative path**, so run from inside `cicd-infra/` (clone the `script-helper` repo if needed):

```bash
cd <repo>/scripts/k8s-bare-metal/cicd-infra
./00-prereqs-check.sh                  # kubectl/helm/openssl + kubectl cluster-info
./01-install-argocd.sh                 # installs Argo CD, prints the initial admin password
./02-install-actions-runner.sh         # installs ARC + applies runner/runner-deployment.yaml
```

---

## Do this FIRST — the two unscripted prerequisites

The runner pod will **not** start (and ARC can't register it) unless these exist before step 02:

1. **The `harbor-ca` Secret** in `actions-runner-system` (C-CASECRET). The runner mounts it as a **volume** (`secretName: harbor-ca` → `/harbor-ca` in the initContainer); without it the pod is stuck in `ContainerCreating` with a `FailedMount` event (`secret "harbor-ca" not found`). Create it from Harbor's CA ([[harbor-registry]] produced `harbor-cert/ca.crt`):
   ```bash
   kubectl create namespace actions-runner-system --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n actions-runner-system create secret generic harbor-ca --from-file=ca.crt=harbor-cert/ca.crt
   # (or edit runner/harbor-ca-secret.yaml: data.ca.crt = base64 -w0 harbor-cert/ca.crt, then apply it)
   ```
2. **ARC GitHub auth** (C-GHAUTH). ARC needs a GitHub **App** (recommended) or a **PAT** with org scope, installed as the ARC controller's auth secret, to register runners with the org (default `mjbl-digital`). No script creates this — provision it per the ARC docs before/at step 02, or runners never register.

---

## When to act vs ask first

**Confirm before running:**
- **GitHub org** the runner registers to (default `mjbl-digital`) and the **ARC auth** method (App vs PAT) — and that the auth secret exists.
- **Harbor domain** must match what [[harbor-registry]] used — it's hardcoded in the runner's `certs.d` path (C-CADOMAIN). If it differs, edit `runner/runner-deployment.yaml`.
- Whether they actually want **both** Argo CD and the runner, or just one (the steps are independent; 01 and 02 can run separately).

---

## Phase map

| # | Step | What it does | Verify gate |
|---|---|---|---|
| 0 | Prereqs | `command -v kubectl helm openssl` + `kubectl cluster-info` | tools present; cluster reachable |
| — | **harbor-ca secret** | create `harbor-ca` in `actions-runner-system` (manual — see above) | `kubectl -n actions-runner-system get secret harbor-ca` |
| — | **ARC GitHub auth** | GitHub App/PAT secret for ARC (manual — see above) | ARC controller has org credentials |
| 1 | Argo CD | ns `argocd`; apply upstream `stable` install manifest; `rollout status` argocd-server; print initial admin password | `argocd-server` rolled out; password printed |
| 2 | ARC + runner | ns `actions-runner-system`; `helm upgrade --install actions-runner-controller … --set certManager.enabled=false`; `rollout status`; apply `runner/runner-deployment.yaml` | controller rolled out; runner pod Ready and **registered** with the GitHub org |

Get the Argo CD password anytime:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## Conventions

```
namespaces:  argocd   actions-runner-system
RunnerDeployment:  mjbl-k8s   (org: mjbl-digital;  labels: registry-runner, self-hosted, linux;  replicas: 1)
runner image:  ghcr.io/actions-runner-controller/actions-runner-controller/actions-runner-dind:ubuntu-22.04  (privileged DinD, DOCKER_TLS_CERTDIR="")
CA initContainer (ubuntu:22.04):  installs harbor-ca into /usr/local/share/ca-certificates + /etc/docker/certs.d/<harbor-domain>/ca.crt  (shared via emptyDir)
secret:  harbor-ca (Opaque, key ca.crt) in actions-runner-system
Argo CD:  upstream "stable" install.yaml; initial password in secret argocd-initial-admin-secret
helm:  actions-runner-controller (repo + release), --set certManager.enabled=false
```

---

## Critical gotchas

### C-CASECRET — the `harbor-ca` Secret is never applied by any script `[critical]`
The runner's `install-harbor-ca` initContainer mounts Secret `harbor-ca`. No script in `cicd-infra/` applies it, and `harbor-ca-secret.yaml` only holds the `<BASE64_OF_HARBOR_CA>` placeholder. Because it's a **volume-mounted** secret, a missing one leaves the runner pod stuck in `ContainerCreating` with a `FailedMount` event (`secret "harbor-ca" not found`) — it never starts or registers. **Create it before step 02** (see "Do this FIRST").

### C-GHAUTH — ARC needs GitHub org auth this layer doesn't provision `[critical]`
The RunnerDeployment targets org `mjbl-digital`, but ARC needs a GitHub App private key or a PAT (org admin scope) installed as the controller's auth secret to register runners. `helm install` passes no auth values and no script creates the secret. Provision it out of band, or runners can't register — this is the silent, undocumented prerequisite of step 02.

### C-PRIV — privileged DinD runner with Docker TLS disabled `[high]`
The runner runs `privileged: true` with `dockerdWithinRunnerContainer` and `DOCKER_TLS_CERTDIR=""` (daemon TLS off) to allow in-pod image builds. That's a significant attack surface (container→node escape; unauthenticated local docker). Acceptable for an isolated lab; for real use, node-isolate/segregate runners and never run untrusted workloads on them.

### C-CADOMAIN — Harbor CA trust is keyed to the exact registry hostname `[high]`
The initContainer writes the CA to `/etc/docker/certs.d/<harbor-domain>/ca.crt`. Docker only consults that dir for the exact `host` (or `host:port`). If Harbor is reached via a different hostname, IP, or non-443 port (e.g. `…:30003`), Docker won't find the CA and pushes/pulls fail with x509. Keep the Harbor hostname consistent with [[harbor-registry]]; if a port is used, the dir must be `host:port`. Edit the initContainer's `mkdir`/`cp` target to match your real endpoint.

### C-ARGOPIN — Argo CD tracks the floating `stable` branch `[medium]`
`.../argo-cd/stable/manifests/install.yaml` follows the moving `stable` Git branch, so re-running at different times installs different Argo CD versions (CRD/feature drift). For reproducibility pin a release tag, e.g. `.../argo-cd/v2.x.y/manifests/install.yaml`.

### C-CERTMGR — ARC installed with `certManager.enabled=false` `[medium]`
ARC's admission webhook normally uses cert-manager for its serving cert; here it's disabled, so ARC must self-handle webhook certs. Verify the controller comes up healthy (the `rollout status` gate) and that applying the RunnerDeployment isn't rejected by a failing webhook.

### C-CAEMPTYDIR — CA re-installed on every pod start via initContainer apt `[low]`
The CA isn't baked into the image; the initContainer `apt install ca-certificates` + `update-ca-certificates` runs each pod start, populating shared `emptyDir` volumes. This keeps the image generic but adds startup latency and a dependency on apt-repo reachability from inside the pod. If apt is unreachable/slow, bake the CA into a custom runner image instead.

### C-RELPATH — step 02 applies the runner manifest by relative path `[medium]`
`kubectl apply -f runner/runner-deployment.yaml` is relative; run `02-install-actions-runner.sh` from the `cicd-infra/` directory or it can't find the manifest.

### C-HARDCODE — org and registry names are hardcoded `[medium]`
`mjbl-digital` (org) and `mjcr.vte.mjblao.local` (registry) are baked into `runner/runner-deployment.yaml`. Editing for another environment means changing the org, the labels if desired, and the `certs.d` path (C-CADOMAIN) — and re-base64'ing the right CA into the secret.

---

## Verify & troubleshoot

- **Argo CD**: `kubectl -n argocd rollout status deploy/argocd-server`; UI via the printed password (user `admin`).
- **Runner**: `kubectl -n actions-runner-system get pods` → runner Ready; confirm it appears in the GitHub org's runner list with labels `registry-runner, self-hosted, linux`.
- Runner pod stuck `ContainerCreating` / `FailedMount` (`secret "harbor-ca" not found`) ⇒ C-CASECRET (missing `harbor-ca` secret).
- Runner Ready but not in GitHub ⇒ C-GHAUTH (missing/invalid ARC auth).
- CI image push fails with x509 ⇒ C-CADOMAIN (wrong `certs.d` host) or the node/runner doesn't trust the Harbor CA ([[harbor-registry]] H-TRUST).

---

## Handoff

This is the terminal layer of the bare-metal stack. If the user is starting fresh, the order is **[[k8s-bare-metal]]** → **[[harbor-registry]]** → **cicd-platform**. If a runner can't reach Harbor, the fix is usually in [[harbor-registry]] (CA trust) or C-CADOMAIN here.
