---
name: mjbl-mtls-platform
description: This skill should be used when the user asks about "the MJBL mTLS platform", "the device-auth platform", "the mutual-TLS ecosystem", "how enrollment/revocation/the gateway fit together", "which host/IP/namespace/service is what", "where is the runbook for X", or any high-level orientation, architecture, component-map, or ecosystem-index question about the live MJBL mutual-TLS device-authentication platform deployed on this host. It is the top-level map + knowledge-base index over the four planes (PKI/trust, enrollment, access gateway, operations portal) and every sibling mjbl-* skill and /home/mjbl runbook.
version: 0.1.0
---

# MJBL mTLS Device-Auth Platform — Ecosystem Map & KB Index

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname `root-ca`, `192.168.1.25` — the MJBL mTLS *ops / remote runner*, NOT a platform component) holds the authoritative runbooks. This skill is the operational index + distilled live facts — it is the front door; READ the referenced doc before any prod-touching step:
> - `/home/mjbl/mjbl-mtls-production-architecture.md` — the 3-level architecture (abstraction → containers → component detail); the canonical source for hosts/IPs/ports/namespaces below.
> - `/home/mjbl/mjbl-mtls-production-golive-runbook.md` — dependency-ordered Phase 0–7 go-live with per-phase verification gates.
> - `/home/mjbl/mjbl-enrollment-paths-slide-brief.md` + `/home/mjbl/mjbl-enrollment-paths-exec-slides.md` — the two enrollment paths (Token vs Claim-QR) explained for stakeholders.
> - `/home/mjbl/mjbl-mtls-client-context-productions.md` — client-side mTLS concepts, cert lifecycle, demo→prod shift, the `$ssl_client_*` identity vars.
> - `/home/mjbl/mjbl-internal-CA-implementation.md` — the underlying 2-tier PKI build (overview / origin of the CA).
> - …and the full runbook catalog indexed under **KB index** below.

## When to use
- "Give me the architecture / the big picture / how does the mTLS platform work."
- "What lives where?" — mapping a component to its host, IP, port, k8s namespace, or ArgoCD app.
- "Which runbook covers X?" — routing to the right `/home/mjbl/mjbl-*.md` doc or sibling skill.
- Onboarding / orientation before diving into a specific plane (then hand off to the focused sibling skill).
- Slide / briefing material on the platform or the two enrollment paths.
- Sanity-checking an IP / port / service name before acting (this skill is the verified reference; do not invent figures).

For *doing* work in one plane, this skill routes you — then use the focused sibling skill (see **Related skills**).

## Architecture / live facts

**The system in one line:** mutual-TLS device authentication — only an *enrolled, non-revoked* MJBL device (agency_v2 Flutter app) gets an X.509 client cert and is admitted to the banking/agency backend; the gateway requires and CRL-revocation-checks that cert on every connection.

**Four planes:** Trust/PKI (mints & revokes) · Enrollment (how a device first gets its cert) · Access/Gateway (terminates mTLS at the edge) · Operations (operator portal + automation).

**Central constraint:** the CA host is *airgapped* from the cluster DMZ, so revocation propagation is **pull-based** (the cluster fetches published CRLs) — this drives the whole access-plane CRL design.

### Components — where each lives (verified against the architecture doc)

| Plane | Component | Host / location | Address / port | Notes |
|---|---|---|---|---|
| **Trust/PKI** | Vault PKI (Root + Intermediate, KV-v2 `enroll/`) | CA host `mjbl-ca-crl` (internal zone, airgapped) | `10.88.1.116` | Vault 2.0.1, Raft. Issuing role `pki/sign/mjbl-branch-client-role` (EC P-256, `clientAuth`, CN `<branch>.<uuid>.mjbl.internal`). AppRole `mjbl-enroll`. |
| **Trust/PKI** | Signer | CA host | `:8444` (admin-Bearer + IP-allowlist) | `/opt/mjbl-enroll/mjbl_enroll_signer.py`, systemd `mjbl-enroll-signer`, user `mjbl-enroll`. Endpoints: `/mint /sign /renew /revoke /devices /activity /allowlist /claim-status /healthz`. **`/renew` (2026-08-06)** is token-free: the device's CURRENT valid cert IS the credential, forwarded by the relay as base64 DER in `X-Client-Cert-DER` and **re-validated independently** by the signer (8-stage fail-closed, incl. a live Vault revocation gate). Audit `/var/log/mjbl-enrollment.log`. Auths to Vault via AppRole `mjbl-enroll` (`/opt/mjbl-enroll/approle/{role_id,secret_id}`); secret_id recovery = `mjbl-enroll-signer-vault-recover.sh` + monthly `mjbl-enroll-signer-vault-recover.timer`. |
| **Trust/PKI** | CRL HTTP server + OCSP responder | CA host | CRL `:8888` (docroot `/opt/mjbl-demo/crl-serve`), OCSP `:2560` | Hop-2 publish timer `mjbl-crl-publish.timer` (**1 min**, intermediate-only, churn-free); `mjbl-crl-root-refresh.timer` (daily). `refresh-crl.sh` / `publish-intermediate-crl.sh`. |
| **Access** | mTLS gateway (nginx) | cluster ns `mjbl-mtls-gateway` (rkek8s) | LB `10.88.101.142` — **`:2399` app** + **`:2401` renew** | `:2399` = the app gateway: `ssl_verify_client on`, `ssl_verify_depth 2`, `ssl_crl /etc/ssl/mjbl/crl-bundle.pem`, injects `X-Client-CN/Serial/Verify`. `:2401` = a **dedicated `stream{}` passthrough** that does NOT decrypt — unconditional `proxy_pass 10.88.101.143:8445` (`nginx-renew-conf.fleet.yaml`). CronJob `mjbl-crl-refresh` (`*/2`, sha256 change-detect → rollout). Guardrail CronJob `mjbl-revocation-selftest` (`*/5`, valid+revoked canary). |
| **Enrollment** | Relay (LB → signer `/sign`, `/renew`) | cluster ns `mjbl-enroll` (rkek8s) | LB `10.88.101.143` — **`:8443` full** + **`:8445` renew-only** | Device→CA path; keeps the CA airgapped from the device network. **`verify_mode=CERT_OPTIONAL` on both sockets**: `/enroll` presents NO client cert (token-authenticated), `/renew` REQUIRES one and enforces its presence **in application code**, because Python `ssl` applies `verify_mode` per socket, not per path. `:8445` (`PUBLIC_RENEW_PORT`) additionally serves **only `/renew`** — see the public-exposure note below. Image `enroll-relay:0.4.1`. |
| **Operations** | Operator portal — BFF (Bun + Hono) | cluster ns `mjbl-mtls-operator-portal` | `:8787` | **Only** component that talks the signer admin API (admin token server-side, pins root CA). `AUTH_MODE=bootstrap`\|`ldap`. RBAC + branch-scope, CSRF, `__Host-` session. |
| **Operations** | Operator portal — Web (Vite/React + nginx) | same ns | Ingress `mtls-portal.vte.mjblao.local` | Same-origin nginx reverse-proxies `/api` → BFF. Dashboard / Devices / Enroll / Enroll-by-QR / Allowlist / Activity. `VITE_USE_MOCK=false` in prod image. |
| **Device** | agency_v2 (Flutter/Android) | pilot tablets | — | Self-generates stable UUID, builds CSR, enrolls (token or QR), stores cert in secure storage, presents on every mTLS call; routes revoked/expired back to re-enroll. |
| **Ops runner** | THIS host | `root-ca` `192.168.1.25` `/home/mjbl` | — | The remote runner: has `ssh ca` to the CA host and the prod kubeconfig. Not in the trust boundary. |

### Cluster topology (3 clusters — do not confuse them)
- **rkek8s** (prod) — runs the gateway, relay, portal. GitOps: `mjbl-digital/k8s-config` reconciled by **ArgoCD** → `rkek8s.vte.mjblao.local:6443`. Prod also uses Rancher Fleet for the portal image bump. **Prod kubectl MUST pin `~/.kube/mjbl-prod.config`** (or `--context rkek8s`) — the default context is a *different* cluster and silently no-ops.
- **facility** — hosts the ArgoCD control plane (`argocd.vte.mjblao.local`).
- **`192.168.1.65`** — UAT / the default `kubectl` context.

### The four end-to-end flows
1. **Enroll:** operator → Portal "Enroll" / "Enroll by QR" → BFF → signer `/mint` (admin) → one-time token → device (token or scans claim-QR) → relay → signer `/sign` (token + CSR) → device cert.
2. **Access (every request):** device → mutual TLS to gateway (presents cert) → nginx verifies chain + CRL → backend, with `X-Client-CN/Serial/Verify` injected.
3. **Revoke (the pull chain that must stay healthy):** Portal Revoke → BFF → signer `/revoke` → Vault `pki/revoke` + `pki/crl/rotate` → CA-host hop-2 timer publishes `:8888` (≤1 min) → cluster CRL CronJob fetches + rolls gateway (≤2 min) → revoked cert refused on next handshake. Self-tested every 5 min.

4. **Renew (token-free, unattended — live 2026-08-06):** device notices its cert is inside the
   **30-day window** → generates a NEW keypair + CSR → `POST /renew` over mTLS **presenting its
   current cert as the credential** → relay verifies the peer cert, forwards base64 DER in
   `X-Client-Cert-DER` → signer **re-validates independently** (chain → expiry/`too_early` → CN
   split → live allowlist → **Vault revocation gate** → CSR proof-of-possession) → new 90-day cert
   → device hot-swaps its `SecurityContext`. No operator, no token, no site visit.
   - **The superseded cert is deliberately NOT revoked** — the device's persistence is several
     non-atomic writes, so revoking on issue would brick any device that fails to store the new
     one. Overlap is bounded by natural expiry (≤30d). The compensating control: revoking a device
     by branch+uuid must revoke **every** unexpired serial.
   - **Why the signer re-validates instead of trusting the relay:** Python's `ssl` does **no CRL or
     OCSP check**, so a revoked-but-unexpired cert completes the relay handshake cleanly. The
     signer's Vault revocation read is the ONLY gate stopping a revoked device from minting itself
     a fresh cert whose serial is on no CRL — which the gateway would then accept. Get this wrong
     and revocation is defeated platform-wide.
   - Client policy (`agency_v2 lib/services/mtls.dart`): 30-day window, per-device jitter over
     0–47h (FNV-1a of the UUID, so no thundering herd), daily retry with 1/2/4/8/16→24h backoff,
     7-day cliff, one-deep identity backup so a partial write cannot brick the device.
   - Operator visibility: `renew` is a first-class audit event — it appears in the portal activity
     feed, the device timeline, and the "Renewed / last 7d" dashboard tile (portal ≥ v0.3.0).
   - **Expiry is NOT recoverable.** The cert IS the credential, so an expired one is refused three
     times over: the relay handshake (`CERT_OPTIONAL` + `load_verify_locations` → OpenSSL aborts
     before application code), the signer's stage-2 `remaining <= 0` → `401 cert_expired`, and the
     gateway's path validation. A grace period would mean accepting an expired credential as proof
     of identity, i.e. no expiry at all — the "other credential" fallback IS the operator
     enrollment token. Miss the window → full operator re-enrollment. See `mjbl-client-provisioning`.

#### The PUBLIC renewal endpoint (live 2026-08-07) — why a second port, not a path
Renewal originally only worked on the internal network, which is useless for a tablet that is
off-site when its window opens. It is now reachable from anywhere:

```
device → microloan.maruhanjapanbanklao.com:2401   public DNS → NAT 202.136.241.166
       → gateway 10.88.101.142:2401               stream{} passthrough, NO decryption
       → relay  10.88.101.143:8445                renew-only listener
       → TLS terminates AT THE RELAY              mTLS stays end-to-end, device→relay
```

- **The path lives INSIDE TLS**, so nothing in front of the relay — NAT, LB, SNI router — can
  publish `/renew` without also publishing `/enroll`, an endpoint that mints certs for a token.
  So the relay gates on **which local socket the connection landed on** (`getsockname()[1]`):
  server-side and unspoofable, unlike `Host` or any `X-Forwarded-*` claim. **The port IS the
  routing decision**, which is why the gateway's `proxy_pass` is unconditional.
- **Allowlist, not denylist** (`PUBLIC_ALLOWED_PATHS = {"/renew"}`) — a denylist leaks every path
  added later. Off-list → **404**, not 403: a 403 confirms the endpoint exists.
- `getsockname()` failure **fails closed** (treated as public); `validate_listener_ports()` refuses
  to start if the public port equals the internal one, which would apply renew-only policy to
  `/enroll` fleet-wide.
- **Path-routing through the existing `:2400` mTLS gateway was rejected** — it would have moved
  cost out of infra and into the *trust model*: header-forwarded identity instead of a real peer
  cert, a new gateway→relay mTLS hop, a rate limiter collapsing to one fleet-wide bucket, and
  dual-path auth during migration. Passthrough keeps the relay the only thing that validates a
  device cert. (`k8s-config#128` closed in favour of `#129`.)

### Two enrollment paths (see the slide docs)
- **Path A — Token (per-device / classic):** operator reads the Device ID, mints a token bound to **branch + that exact device**, hands it over. Strongest binding; best for one remote/high-assurance device; bottleneck = a Device-ID round-trip per device.
- **Path B — Claim-QR (mass / batch):** operator opens "Enroll by QR" (no Device ID), portal shows a short-lived (2–5 min), single-use, **auto-rotating** branch-scoped QR (WhatsApp-Web style); device scans, self-asserts its UUID, `/sign` binds at first use. Best for on-site batch onboarding.
- Both: operator-authorized · branch must be on the allowlist · single-use & short-lived · same cert · revocation identical afterward.

## Key procedures
Each routes to the runbook that owns the detail — read it before prod-touching steps.

- **Stand up / go live end-to-end** → `mjbl-mtls-production-golive-runbook.md` (Phase 0 prereqs → 1 CA/PKI → 2 gateway → 3 portal → 4 enrollment/allowlist → 5 device app → 6 e2e verify → 7 ops handoff). Each phase has a verification gate; do not proceed past a failing gate.
- **Understand the architecture at any altitude** → `mjbl-mtls-production-architecture.md` (Level 1 concept → Level 2 containers → Level 3 component detail).
- **Enroll a device** → portal Enroll (token) or Enroll-by-QR; mint helper on the CA host; pilot flow in `mjbl-agency-v2-pilot-runbook.md`, delivery in `mjbl-device-delivery-runbook.md`.
- **Revoke a device** → Portal Revoke → confirm `crl_published:true`; for need-it-now run `enforce-crl-now.sh` (~30 s) or Rancher *Run now* on `mjbl-crl-refresh`. **The full chain is 3 hops** — see the revocation postmortem before relying on it.
- **Recover the signer↔Vault auth** (signer logs `outcome:degraded / reason:vault_unreachable / revocation_source:audit-only`; Vault logs `auth/approle/login … user is locked out`) → the `mjbl-enroll` AppRole `secret_id` expired and the retries tripped Vault's lockout; new enroll/revoke fail while existing devices stay up. Fix: run `/home/mjbl/mjbl-enroll-signer-vault-recover.sh` on the CA host (re-issues the secret_id, sets `secret_id_ttl=0`, clears the lockout, restarts + verifies). Runs automatically monthly via `mjbl-enroll-signer-vault-recover.timer`.
- **Rotate the relay TLS cert** → `mjbl-relay-cert-rotation-runbook.md`. **Rotate the CA host** → `mjbl-CA-host-rotation-checklist.md`.
- **Operate the portal** → `mjbl-operator-portal-runbook.md`; its P5 prod cutover → `mjbl-mtls-portal-p5-prod-golive-runbook.md`.
- **Harden for prod** → `mjbl-prod-hardening-checklist.md`. **Move to real-time revocation** → `mjbl-gateway-ocsp-plan.md`.

## Gotchas & hard-won lessons
- **Wrong kubeconfig = silent no-op.** Prod cluster ops MUST pin `~/.kube/mjbl-prod.config` / `--context rkek8s`. The default `kubectl` context is a different cluster.
- **Revocation needs ALL 3 hops, not just `vault revoke`.** Missing/missed hop-2 (CA-host publish) or hop-3 (cluster CRL CronJob roll) leaves a revoked cert *still admitted*. This caused the real incident — see `mjbl-mtls-revocation-postmortem.md`.
- **Root cause of that incident: a missing `pki/crl/rotate` (read) grant** in live Vault's `mjbl-enroll` policy. The go-live runbook makes you re-verify the grant explicitly (`vault policy read mjbl-enroll | grep crl/rotate`). Vault 2.0 `auto_rebuild` defers, so the signer must explicitly rotate.
- **Allowlist is UPPERCASE + case-sensitive.** The device upper-cases the branch; the signer is case-sensitive — an off-case branch is refused (403).
- **Out-of-band secrets are NOT in git** (gateway server/trust material, portal env, revocation canary). They are seeded by scripts and ArgoCD is set to `ignoreDifferences` on them — else placeholders clobber them. `bootstrap-secrets.sh` reads `/etc/ssl/mjbl/` so it runs **on the CA/gateway host** via `ssh ca`, not the ops VM.
- **The canary expires (~90 days, role-capped — not the requested 1-year TTL).** Trust the `expire:` the script prints. A persistent "valid canary rejected" WARN is your prompt to re-provision.
- **Under TLS 1.3 a refused client cert returns `400`, not `000`** — the self-test asserts accordingly.
- **CA-host script heredoc gotcha:** feed scripts via `ssh ca 'sudo -n bash -s' < file` (interactive `!`-paste indents heredoc delimiters and breaks). `pki/crl/rotate` is a **read**, not a write (`write` → 405).
- **The signer's AppRole `secret_id` expires (default `secret_id_ttl=720h` ≈ 30 days) → Vault user-lockout → signer runs `degraded`/`audit-only`; new enroll + revoke fail, existing devices unaffected.** Confirmed incident 2026-07-06 (secret_id issued 06-04, expired 07-04). Now mitigated: `secret_id_ttl=0` (non-expiring) + monthly `mjbl-enroll-signer-vault-recover.timer`. One-shot fix / rotation: `mjbl-enroll-signer-vault-recover.sh`. Unlock path is `sys/locked-users/<approle-mount-accessor>/unlock/<role_id>`.
- **Break-glass Vault token:** the root token + unseal keys sit in **plaintext at `/root/vault-init.json`** on the CA host — `export VAULT_TOKEN=$(sudo jq -r .root_token /root/vault-init.json)` gets you an authenticated root session (this build even requires a token for `generate-root`, so there's no token-less recovery path). It works, but it's a hardening gap: move it off-host and give the recovery script a **scoped token** (just `auth/approle/role/mjbl-enroll/secret-id` + the unlock path) instead of root. See `mjbl-prod-hardening-checklist.md`.
- **Read the ACTUAL public response after exposing anything.** The relay had been leaking
  `Server: mjbl-enroll-relay/0.1.0 Python/3.12.13` — harmless while internal, but on a published
  endpoint it hands over the exact codebase to go read and a runtime version to match CVEs
  against, for zero operational benefit (nothing legitimate parses it). It was **invisible from
  inside the cluster** and only appeared in a real external `curl -i`. Fixed in `0.4.1` by
  overriding `version_string()` to return `""`. Verify exposure from off-network, not from a pod.
- **A `v*` tag on `mjbl-mtls-enrollment` auto-deploys to production** — the relay-image job builds,
  pushes, and bumps the `k8s-config` image tag, and ArgoCD rolls it. Tagging is a prod write.
- **`v*` tag builds carry NO `workflow_dispatch` inputs** — every `github.event.inputs.*` is empty,
  so the `|| 'default'` fallback IS the shipped contract. This nearly shipped APK `1.1.43 (55)`
  with `MTLS_RENEW_BASE` empty, which (higher versionCode) would have superseded the good build
  and silently reverted the pilot fleet to internal-only renewal. Flip the workflow **default**
  before tagging; never rely on dispatch inputs for a tag release.
- **Prod gates:** CA-host changes go via `! ssh ca`; `k8s-config` merges are user-gated (agent self-merge denied → user merges → triggers the ArgoCD roll); ArgoCD prod writes / force-sync are user-gated/denied to the agent (reads OK).

## KB index — every `/home/mjbl/mjbl-*.md` runbook by topic
**Architecture & go-live**
- `mjbl-mtls-production-architecture.md` — 3-level production architecture (the map).
- `mjbl-mtls-production-golive-runbook.md` — dependency-ordered Phase 0–7 prod go-live with gates.
- `mjbl-prod-hardening-checklist.md` — post-go-live production hardening to-dos.

**PKI / CA / trust plane**
- `mjbl-internal-CA-implementation.md` — the 2-tier PKI build (Root + Intermediate + Vault).
- `mjbl-internal-CA-implementation-x-client-certs.md` — client-certificate (mTLS) extension of the CA build.
- `mjbl-CA-host-rotation-checklist.md` — production CA-host rotation runbook.
- `mjbl-relay-cert-rotation-runbook.md` — enroll-relay TLS cert rotation.

**Enrollment plane**
- `mjbl-enrollment-paths-slide-brief.md` — the two enrollment paths, stakeholder slide brief.
- `mjbl-enrollment-paths-exec-slides.md` — the two paths as a 4-slide exec deck.
- `mjbl-claim-qr-enrollment-design.md` — Claim-QR (Path B) design.
- `mjbl-enrollment-app-golive-plan.md` — agency_v2 enrollment go-live readiness plan.
- `mjbl-device-delivery-runbook.md` — client-app delivery & device-enrollment runbook.

**Access plane / revocation**
- `mjbl-gateway-ocsp-plan.md` — gateway OCSP for real-time client-cert revocation (planned).
- `mjbl-mtls-revocation-postmortem.md` — post-mortem: revocation not enforced at the gateway (the 3-hop lesson).

**Operations / portal**
- `mjbl-operator-portal-runbook.md` — operator portal runbook & guide.
- `mjbl-mtls-portal-p5-prod-golive-runbook.md` — portal P5 prod cutover runbook.
- `mjbl-mtls-next-milestone-plan.md` — trunk integration + operator portal milestone plan.

**Device app (agency_v2)**
- `mjbl-mtls-client-context-productions.md` — client-side mTLS concepts, cert lifecycle, demo→prod shift.
- `mjbl-mtls-client-provisioning.md` — Flutter/Android credential provisioning.
- `mjbl-agency-v2-pilot-runbook.md` — agency_v2 mTLS pilot go-live (Phase H).
- `mjbl-agency-v2-remaining-golive-plan.md` — remaining agency_v2 go-live work.
- `mjbl-agency-v2-firebase-app-distribution-runbook.md` — Firebase App Distribution rollout.
- `mjbl-agency-v2-owner-merge-gap-analysis.md` — owner feature-release ↔ mTLS merge gap analysis.
- `mjbl-agency-v2-device-serial-mdm-roadmap.md` — device-serial enrollment via MDM roadmap.

**Adjacent (not mTLS, same repos/cluster)**
- `mjbl-airflow-k8s-config-migration-plan.md` — Airflow manifests → k8s-config migration.

## Related skills
Route to the focused sibling skill to *do* work in a plane (this skill is the map):
- **`internal-ca`** — stand up / understand the 2-tier PKI (Root + Intermediate + Vault PKI, OCSP/CRL). The trust plane's foundation.
- **`mtls`** — add mutual TLS on top of the CA: client certs (`clientAuth`), PKCS#12, `ssl_verify_client`, CRL revocation.
- Additional `mjbl-*` planes (enrollment, gateway, operator-portal, CA-operations) are documented in the runbooks indexed above; consult them directly until a dedicated sibling skill exists.
