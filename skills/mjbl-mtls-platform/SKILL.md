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
| **Trust/PKI** | Signer | CA host | `:8444` (admin-Bearer + IP-allowlist) | `/opt/mjbl-enroll/mjbl_enroll_signer.py`, systemd `mjbl-enroll-signer`, user `mjbl-enroll`. Endpoints: `/mint /sign /revoke /devices /activity /allowlist /claim-status /healthz`. Audit `/var/log/mjbl-enrollment.log`. |
| **Trust/PKI** | CRL HTTP server + OCSP responder | CA host | CRL `:8888` (docroot `/opt/mjbl-demo/crl-serve`), OCSP `:2560` | Hop-2 publish timer `mjbl-crl-publish.timer` (**1 min**, intermediate-only, churn-free); `mjbl-crl-root-refresh.timer` (daily). `refresh-crl.sh` / `publish-intermediate-crl.sh`. |
| **Access** | mTLS gateway (nginx) | cluster ns `mjbl-mtls-gateway` (rkek8s) | LB `10.88.101.142:2399` | `ssl_verify_client on`, `ssl_verify_depth 2`, `ssl_crl /etc/ssl/mjbl/crl-bundle.pem`. Injects `X-Client-CN/Serial/Verify`. CronJob `mjbl-crl-refresh` (`*/2`, sha256 change-detect → rollout). Guardrail CronJob `mjbl-revocation-selftest` (`*/5`, valid+revoked canary). |
| **Enrollment** | Relay (LB → signer `/sign`) | cluster ns `mjbl-enroll` (rkek8s) | LB `10.88.101.143:8443`, `enroll.vte.mjblao.local` | Device→CA path; keeps the CA airgapped from the device network. |
| **Operations** | Operator portal — BFF (Bun + Hono) | cluster ns `mjbl-mtls-operator-portal` | `:8787` | **Only** component that talks the signer admin API (admin token server-side, pins root CA). `AUTH_MODE=bootstrap`\|`ldap`. RBAC + branch-scope, CSRF, `__Host-` session. |
| **Operations** | Operator portal — Web (Vite/React + nginx) | same ns | Ingress `mtls-portal.vte.mjblao.local` | Same-origin nginx reverse-proxies `/api` → BFF. Dashboard / Devices / Enroll / Enroll-by-QR / Allowlist / Activity. `VITE_USE_MOCK=false` in prod image. |
| **Device** | agency_v2 (Flutter/Android) | pilot tablets | — | Self-generates stable UUID, builds CSR, enrolls (token or QR), stores cert in secure storage, presents on every mTLS call; routes revoked/expired back to re-enroll. |
| **Ops runner** | THIS host | `root-ca` `192.168.1.25` `/home/mjbl` | — | The remote runner: has `ssh ca` to the CA host and the prod kubeconfig. Not in the trust boundary. |

### Cluster topology (3 clusters — do not confuse them)
- **rkek8s** (prod) — runs the gateway, relay, portal. GitOps: `mjbl-digital/k8s-config` reconciled by **ArgoCD** → `rkek8s.vte.mjblao.local:6443`. Prod also uses Rancher Fleet for the portal image bump. **Prod kubectl MUST pin `~/.kube/mjbl-prod.config`** (or `--context rkek8s`) — the default context is a *different* cluster and silently no-ops.
- **facility** — hosts the ArgoCD control plane (`argocd.vte.mjblao.local`).
- **`192.168.1.65`** — UAT / the default `kubectl` context.

### The three end-to-end flows
1. **Enroll:** operator → Portal "Enroll" / "Enroll by QR" → BFF → signer `/mint` (admin) → one-time token → device (token or scans claim-QR) → relay → signer `/sign` (token + CSR) → device cert.
2. **Access (every request):** device → mutual TLS to gateway (presents cert) → nginx verifies chain + CRL → backend, with `X-Client-CN/Serial/Verify` injected.
3. **Revoke (the pull chain that must stay healthy):** Portal Revoke → BFF → signer `/revoke` → Vault `pki/revoke` + `pki/crl/rotate` → CA-host hop-2 timer publishes `:8888` (≤1 min) → cluster CRL CronJob fetches + rolls gateway (≤2 min) → revoked cert refused on next handshake. Self-tested every 5 min.

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
