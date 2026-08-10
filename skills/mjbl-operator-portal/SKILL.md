---
name: mjbl-operator-portal
description: This skill should be used when the user asks to "deploy/run the operator portal", "operate the mTLS console", "configure the portal BFF", "set up portal LDAP/AD login", "wire portal RBAC", "grant/assign a permission to an operator", "which operator can mint/revoke/edit a device", "why can't an operator do X in the console", "add a new portal permission", "edit/rename a device / change its alias or device details", "do the P5 cutover", "roll back the portal", "add the signer admin endpoints (/devices /revoke /allowlist /activity)", or otherwise operate the MJBL OPERATOR PORTAL — the React-SPA + Bun/Hono BFF console for the device-cert lifecycle (mint/revoke/inventory/activity) on the live MJBL mTLS platform on this host. Covers the BFF (LDAP-HTTP-delegate auth, session, CSRF, the DB-backed permission catalog + branch scope, server-side signer admin token), the signer admin endpoints, editable device details (`device:edit` / `portal.device_labels`), migrations, release triggers, prod deploy (ArgoCD/Postgres), and the P5 AD-login cutover/rollback.
version: 0.1.0
---

# MJBL Operator Portal — BFF + RBAC + AD-login console

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname root-ca, the MJBL mTLS *remote runner*) holds the authoritative runbooks. This skill is the operational index + distilled live facts — READ the referenced docs before any prod-touching step:
> - `/home/mjbl/mjbl-operator-portal-runbook.md` — the master runbook: run-locally, mock→live switches, full BFF `.env` reference, build/deploy (GitOps), operating (roles/mint/revoke/allowlist/activity), security checklist, rollback/troubleshooting.
> - `/home/mjbl/mjbl-mtls-portal-p5-prod-golive-runbook.md` — the P5 prod go-live: Postgres-backed dynamic RBAC + AD login, **the 2026-06-11 HTTP-DELEGATE supersede note** (the live auth model), cutover/verify/rollback.
> - `/home/mjbl/mjbl-operator-portal/` — the monorepo: BFF at the repo root (`src/`, `example.env`, `Dockerfile`, `README.md`); the SPA under `applications/operator-portal-web/`; the dev CA under `deploy/dev-ca/`.
> - `/home/mjbl/mjbl-mtls-portal-p5-cutover.sh` — the (now arg-less) cutover script the P5 runbook drives.
> - `/home/mjbl/mjbl-mtls-enrollment/signer/mjbl_enroll_signer.py` — the signer; the BFF's only backend (the admin endpoints `/devices /revoke /allowlist /activity` live here). See the `mjbl-enrollment-plane` skill for the signer/relay detail.
> - `~/.ldapserver` — the one-line LDAP-auth HTTP-delegate endpoint URL (`http://10.88.2.82:3001/ldap/authziedUser`).

## When to use
- Run the whole portal stack locally (bootstrap admin + mock signer, or the dockerized dev CA for a real signer with no prod access).
- Configure the BFF `.env` for real mode (auth, session, signer, root-CA pinning) and understand why the BFF refuses to boot.
- Set up / debug AD login (the HTTP-delegate model) or RBAC (roles + branch scope).
- Add or deploy the signer admin endpoints (`/devices /revoke /allowlist /activity`).
- Build + deploy the two container tiers via GitOps (ArgoCD), or run the **P5 cutover** (bootstrap/in-memory → Postgres RBAC + AD login) and its rollback.
- Operate the portal (mint a token, revoke a device, allowlist a branch, read activity) or triage "signer unreachable", "BFF exits 2", "login fails", "revoke propagating forever".

## Architecture / live facts
Three tiers, one origin. The **browser only ever calls same-origin `/api/*`** and holds **no secret**; the BFF holds the signer admin token + does auth/RBAC; the airgapped signer is the only thing that touches Vault.

```
  operator browser ──https (same origin)──► nginx (web pod): static SPA + /api/* reverse-proxy
                                                  │
                                                  ▼
                                            BFF  (Bun + Hono + TS)   — admin bearer + root-CA-pinned TLS
                                              │                      — AUTH via HTTP-DELEGATE (below)
                                              ▼
                                     SIGNER  10.88.1.116:8444  (CA host, airgapped)
                                              ▼
                                     Vault PKI (localhost-only on the CA host)
```

**Monorepo** `/home/mjbl/mjbl-operator-portal/` — the **BFF is the repo root**; the SPA lives under `applications/`:
- BFF: Bun + Hono + TS, `src/` (`config.ts`, `index.ts`, `auth/`, `db/`, `routes/`, `signer/`, `audit.ts`), env template `example.env`, listens on **`PORT=8787`**. `.dockerignore` excludes `applications/`.
- SPA: `applications/operator-portal-web/` — Bun + Vite + React + TS, dev server **5173**; prod = nginx serving the static build + reverse-proxying `/api/` → the BFF service. Its own `Dockerfile`/`nginx.conf`/`.env.example`.
- Dev CA: `deploy/dev-ca/` — dockerized Vault-backed replica of the signer plane (runs the real `mjbl_enroll_signer.py`) for real-mode local dev with **no prod access**.

**Prod deployment** (rkek8s, GitOps via `k8s-config` + ArgoCD, images → GHCR → the `mjcr` pull-through):
- Namespace **`mjbl-mtls-operator-portal`**; ArgoCD app **`mjbl-mtls-portal`** (syncs the two `production/` dirs under `deployments/mjbl-mtls-operator-portal/`).
- Web at **`https://mtls-portal.vte.mjblao.local`** (HTTPS, internal CA cert, `COOKIE_SECURE=true`).
- Deployment `mjbl-mtls-operator-portal` with containers **`bff`** + **web**; env Secret **`mjbl-mtls-operator-portal-env`**; **Postgres `:16-alpine` StatefulSet** + headless Service + 10Gi longhorn PVC (`postgres.fleet.yaml`, internal-zone affinity) holds RBAC + sessions.
- Images: `ghcr.io/mjbl-digital/operator-portal-bff:<tag>` (built from repo root) and `…/operator-portal-web:<tag>` (built from `applications/operator-portal-web`).
- **Placement is load-bearing:** the signer is airgapped behind a source-IP allowlist (`10.88.1.26`, `10.88.1.27`, `127.0.0.1`). The BFF MUST run on **internal-zone nodes** (`nodeSelector: network-zone=internal`, like the relay) so its egress SNATs to an allowlisted IP and can reach `10.88.1.116:8444`. Add a node → add its IP to the signer's `SIGNER_ALLOW`.

**AD login = HTTP-DELEGATE (the live model, since 2026-06-11; supersedes any LDAPS/`ldap://` direct-bind step).** The BFF pod is firewalled off the DC's LDAP port — a direct bind to `10.88.1.113:389` RSTs (`ECONNRESET`), and LDAPS `:636` is a dead end (RST even from an allowlisted host). So the BFF **POSTs** `{meta:{user,password}}` to the cluster LDAP-auth HTTP service **`http://10.88.2.82:3001/ldap/authziedUser`** (`LDAP_AUTH_SERVICE_URL`, the `httpLdapAuth` path, pkg pattern `pkg.ldapauth`) and trusts the `{meta:{authorized}}` envelope; that service binds the DC from an allowlisted host. The endpoint URL is in `~/.ldapserver`. (Direct-bind `LDAP_URL`/bind-DN/search-base config remains a fallback for `LDAP_AUTH_SERVICE_URL` empty, but is dead in prod.)

**Live prod state: image `v0.4.0` (2026-08-10)** — editable device details + the `device:edit`
permission (migration `0005_device_labels.sql`). Earlier: `v0.3.0` renew events in the console;
**P5 cutover applied 2026-06-13** as `v0.2.1`: `AUTH_MODE=ldap` +
`LDAP_AUTH_SERVICE_URL=http://10.88.2.82:3001/ldap/authziedUser`, `RBAC_BACKEND=postgres` (sessions +
dynamic RBAC in Postgres), break-glass bootstrap `root` admin preserved. **AD sign-in CONFIRMED
working in prod (2026-06-14, by the user).** First AD login = deny-until-assigned (break-glass admin
assigns the operator to a group in Access control → Users).

**Migrations run themselves at BFF start** (`src/db/migrate.ts`) — `src/db/migrations/NNNN_*.sql` in
lexical order, once each, tracked in `portal.schema_migrations`, the whole run inside ONE transaction
holding a transaction-scoped advisory lock so concurrent replicas can't race. After a deploy, the
proof the schema landed is the log line `db migrate: applied <file>` (or `db migrate: up to date`).
Never edit an applied migration; add a new numbered file.

**RBAC = a DYNAMIC, DB-backed permission catalog. AD authenticates; the PORTAL authorizes.** There is no
static role map in the live path — `src/auth/roles.ts` (the old `ROLES` + `roleFromGroups`) has **zero
importers**, and `config.ts` says so outright: *"legacy `LDAP_GROUP_ADMIN/OFFICER/AUDITOR` vars are
unused; do not require them"*, `ldap.ts`: LDAP *"plays NO part in authorization"*. Do not configure
group→role mapping to grant access; it does nothing.
- **Model:** operator (keyed by AD username, auto-upserted at first login) → assigned **platform
  groups** (`portal.platform_groups`, admin-editable at runtime) → union of **grants**
  (permission + `scope_all` or an explicit branch set) → an `EffectiveAuthz` snapshot on the session.
  Merge is most-permissive: `scope_all` wins, else branch sets union.
- **Permission catalog** (`portal.permissions`, seeded by migrations — the admin UI renders whatever is
  in this table, so a new permission is grantable with **no frontend change**):
  `devices:view` · `activity:view` · `allowlist:view` · `device:mint` · **`device:edit`** ·
  `device:revoke` · `allowlist:add` · `allowlist:remove` · `rbac:admin`.
- **Deny-until-assigned:** a valid AD user with no group (or groups granting nothing) authenticates
  and is then refused — recorded as a "discovered" operator for an admin to assign.
- **Break-glass** `superadminEffective()` holds every permission and is computed **in-process, never
  touching the DB**, so it still works with Postgres down. A new permission must be added to
  `ALL_PERMS` as well as the migration, or break-glass won't hold it.
- The three-role vocabulary survives only as a **back-compat display block** (`sessionView` derives
  `roleId`/`capabilities` from the real permissions for older screens). A capability the operator
  lacks is *absent* from the UI, not greyed out.

**Device details are editable (v0.4.0) — and they are PORTAL data, not PKI data.** The signer cannot
edit them: its inventory is replayed from an append-only audit log, so `metadata` is write-once at
`/mint`, and `/renew` deliberately *inherits* it (so a wrong alias would otherwise propagate forever).
- `portal.device_labels` — keyed **`(branch, device_id)`**, NOT serial: a serial rotates on every
  renewal, a device id doesn't, so a label survives renewal *and* re-enrollment. Merged **per key**
  over the signer's `/devices`; clearing every field DELETES the row so the mint value resurfaces.
- **`POST /devices/label`** is portal-only — it never calls the signer. Gated by `device:edit`,
  scope-checked against the **resolved** device's branch (never a branch from the request body);
  a device the session can't see is **404, not 403**.
- Fields today are `alias` + `serial` (`applications/operator-portal-web/src/lib/metadataFields.tsx`,
  a shared catalog used by Mint, Claim-QR, and the edit modal — extending it is one line).
- ⚠️ **Mint metadata is capped at 16 keys by the signer** (`validate_metadata`), while the BFF's
  `sanitizeMetadata` allows 20. Harmless at 2 fields; anything that grows the mint-time catalog must
  reconcile these or enrollment fails with a 400 at the tablet.

**Signer admin endpoints (the BFF's backend):** `POST /mint` (pre-existing), plus the added `GET /devices`, `POST /revoke`, `GET|POST /allowlist` + `DELETE /allowlist/<code>`, `GET /activity` — all admin-bearer, reusing the signer's source-IP allowlist + AppRole→Vault + audit. (Owned by the `mjbl-enrollment-plane` skill; deploy via `! ssh ca`.)

**Key env keys** (BFF `.env`; full table in the runbook §3): `AUTH_MODE` (`bootstrap`|`ldap`), `RBAC_BACKEND` (`memory`|`postgres`), `LDAP_AUTH_SERVICE_URL`, `DATABASE_URL`, `USE_MOCK_SIGNER`, `SIGNER_URL`/`SIGNER_ADMIN_TOKEN` (server-side only), `MJBL_ROOT_CA` (pinned), `SESSION_SECRET`, `COOKIE_SECURE`, `ALLOWED_ORIGINS`, `BOOTSTRAP_ADMIN_*` (break-glass), `LDAP_BRANCH_ATTR`, `INSECURE_DEV` (dev-only). No mock-user mode exists; there is only `bootstrap` and `ldap`. **`LDAP_GROUP_ADMIN/OFFICER/AUDITOR` are LEGACY and unused** — still parsed by `config.ts` but wired to nothing; authorization is 100% portal-managed groups (see RBAC above).

**Release triggers — `deploy.yml` (know which action deploys what):**
| Event | Channel | Effect |
|---|---|---|
| push to **`main`** (i.e. merging the promote PR) | `uat` | builds `staging-sha<sha>` for BFF+web, then **pushes DIRECTLY to `k8s-config` `main`** (bot PAT, no PR) bumping `uat.fleet.yaml` |
| push of a **`v*` tag** | `prod` | builds `v<x.y.z>`, bumps `production/production.fleet.yaml` → ArgoCD rolls prod |
| `pull_request` | — | `verify` only; `build`/`gitops` are explicitly skipped ("a PR must gate, not deploy") |

So **merging dev→main is itself a UAT deploy that bypasses the usual k8s-config PR gate**, and tagging
is the production write. Branch flow is `feat/*` → **`dev`** → a "Promote dev -> main" PR → tag.

## Key procedures
See the runbooks for the full text; this is the condensed map. Prod gates apply (below).

**Run locally (mock).** `cd /home/mjbl/mjbl-operator-portal; bun install; bun run dev` (→ `:8787`; prints the bootstrap `root` password ONCE as a banner — or set `BOOTSTRAP_ADMIN_PASSWORD`). Then `cd applications/operator-portal-web; bun install; cp .env.example .env; bun run dev` (→ `:5173`). `VITE_USE_MOCK=true` = SPA-only fabricated fleet; `false` = SPA→BFF. (Runbook §1.)

**Run locally against a real signer (no prod access).** `cd deploy/dev-ca && docker compose up -d --build && ./seed.sh`; set BFF `.env`: `USE_MOCK_SIGNER=false`, `INSECURE_DEV=true`, `SIGNER_URL=https://localhost:8444`, `SIGNER_ADMIN_TOKEN=<from logs>`, `MJBL_ROOT_CA=./deploy/dev-ca/out/root-ca.crt`. (Runbook §1.)

**Go real (mock→live), three switches in order** (runbook §2): (2a) deploy the signer's new endpoints via `! ssh ca` + restart `mjbl-enroll-signer` (mjbl-enrollment-plane); (2b) fill the BFF `.env` (`USE_MOCK_SIGNER=false`, `SIGNER_ADMIN_TOKEN`, `MJBL_ROOT_CA`, fresh `SESSION_SECRET`, `COOKIE_SECURE=true`, `AUTH_MODE`); (2c) point the frontend (`VITE_USE_MOCK=false`).

**Build + deploy (prod).** Build both images (BFF from repo root, web from `applications/operator-portal-web`) → push to GHCR → bump the prod fleet tag in `k8s-config` (PR, **user-merged**) → ArgoCD rolls both pods. Inject `SIGNER_ADMIN_TOKEN`/`SESSION_SECRET`/LDAP secret as a k8s Secret; mount the public `MJBL_ROOT_CA` PEM. (Runbook §4.)

**P5 cutover (bootstrap/in-memory → Postgres RBAC + AD HTTP-delegate)** — the **HTTP-delegate path** (P5 runbook 2026-06-11 note, supersedes the LDAPS steps):
1. Ship code+infra: merge the k8s-config Postgres PR (StatefulSet sits Pending until the DB Secret exists — expected); promote dev→main; tag **`v0.2.1`** (must contain `httpLdapAuth`) and let ArgoCD roll it **FIRST**.
2. Pre-flight: `kubectl -n mjbl-mtls-operator-portal get pods` → BFF+web Running on the new image, `…-db-0` Pending.
3. Cutover (arg-less): `bash /home/mjbl/mjbl-mtls-portal-p5-cutover.sh` — creates the DB Secret (Postgres goes Running), flips the env Secret to `RBAC_BACKEND=postgres` + `DATABASE_URL` + `AUTH_MODE=ldap` + `LDAP_AUTH_SERVICE_URL=http://10.88.2.82:3001/ldap/authziedUser` (drop `LDAP_URL`/`LDAP_ALLOW_PLAINTEXT`), rolls the BFF; on boot it migrates the schema + seeds the system groups. The script **aborts unless the running image is ≥ v0.2.1** and gates on `rollout status`.
4. Verify: `…-db-0` Running + BFF Ready; logs show `migrat`/`listening`/`auth=ldap`; the `INSECURE … plaintext http://` warning is expected (= delegate active); from the pod, POST a bogus user to the delegate service → expect `200 {…"authorized":false…}`; break-glass `root` login → assign an AD user a group → real AD login; smoke devices/mint/revoke/activity.

**Rollback (P5).** Flip env back without redeploying, then restart:
```bash
kubectl -n mjbl-mtls-operator-portal patch secret mjbl-mtls-operator-portal-env --type merge \
  -p '{"stringData":{"AUTH_MODE":"bootstrap","RBAC_BACKEND":"memory"}}'
kubectl -n mjbl-mtls-operator-portal rollout restart deploy/mjbl-mtls-operator-portal
```
Portal returns to break-glass + in-memory; the Postgres StatefulSet can stay (unused). Release rollback = redeploy the previous image tag (GitOps revert) — both tiers are stateless once RBAC/sessions are externalized.

**Operate** (runbook §5): **mint** Devices→Enroll→branch+Device-ID→Mint (one-time token, copy/QR, signer binds it to `(branch, Device-ID)`); **revoke** Device detail→Danger zone→type-to-confirm (UI shows `Active → Revoked·propagating → Revoked·enforced`; the BFF's `/revoke` only does **hop 1** of the **3-hop, ≤15 min** CRL propagation); **allowlist** Branches→add/remove branch codes; **activity** secret-free feed + CSV export. The BFF also logs every operator action (`AUDIT …`) to stdout.

## Gotchas & hard-won lessons
- **AD auth is HTTP-DELEGATE, NOT a direct bind.** Do not configure/troubleshoot `LDAP_URL`/`ldaps://`/bind-DN/search-base in prod — the pod is firewalled off the DC (`:389` RSTs, `:636` dead). The auth env is `AUTH_MODE=ldap` + `LDAP_AUTH_SERVICE_URL=http://10.88.2.82:3001/ldap/authziedUser`. Post-cutover troubleshooting is **service reachability + envelope shape** (`{meta:{authorized}}`), not bind/TLS. The plaintext-http `INSECURE` boot warning is expected (accepted internal-segment tradeoff = delegate active).
- **Cutover ORDER:** deploy the **v0.2.1** image (with `httpLdapAuth`) **first**, then run the cutover — else the new env Secret hits the old image and CrashLoops on its old `LDAP_URL`-required boot gate. The script enforces this (aborts < v0.2.1).
- **The BFF refuses to boot (exit 2) in real mode** if `SESSION_SECRET` is the dev default, `COOKIE_SECURE` is false, the signer admin token is missing, the root CA is unreadable, or (in `ldap`) no group mapping is set. Read the `ERROR config:` lines. By design — not a bug.
- **BFF egress placement is the #1 deploy footgun.** If the BFF isn't on an internal-zone node (egress IP on the signer's `SIGNER_ALLOW`), every signer call 403s and the "Signer unreachable" banner shows. Add a node → add its IP to `SIGNER_ALLOW`.
- **The signer admin token + `SESSION_SECRET` are server-side ONLY** — never in the browser, never committed (keep them in `.env`/k8s Secret, not `example.env`). `MJBL_ROOT_CA` is mounted public PEM and the BFF *pins* it (refuses to call the signer without it).
- **Do NOT reach for `LDAP_GROUP_*` to grant access — they are legacy and unused.** If an operator "can't do anything", the fix is assigning them a platform group in Access control → Users, never an env var. (`ALLOWED_ORIGINS` must still be the real https portal origin, not localhost, or logins/mutations 403 "bad origin".)
- **A new permission ships GRANTED TO NOBODY.** Seeding it in a migration only makes it *grantable*; until an admin adds it to a group the UI affordance is absent and the endpoint refuses. `device:edit` shipped this way in v0.4.0 — "the feature deployed but nothing changed" is the expected first observation, not a bug.
- **Add a new permission in BOTH places:** the migration (so it's in `portal.permissions` and therefore grantable) **and** `ALL_PERMS` in `src/auth/rbac.ts` (so break-glass superadmin holds it — that path never reads the DB). Miss the second and superadmin silently lacks it exactly when Postgres is down.
- **Scope-check against the RESOLVED object, never a branch from the request body.** `/revoke` and `/devices/label` both fetch the device from the signer first, then check `hasPermissionForBranch(s, perm, dev.branch)`; `resolveLabelTarget` takes no branch argument at all so the mistake is structurally impossible. Out-of-scope → 403 (audited); not-visible → **404, not 403** (a 403 confirms existence).
- **Don't duplicate a composite-key format across layers.** `portal.device_labels` is keyed `(branch, device_id)`; the db layer once built its own lookup key with a different separator than `labelKey()`, so every override was silently dropped while both halves looked correct in isolation, and no unit test could see it. The db returns plain rows; one module owns the key. A real-Postgres round-trip caught it — pure-function tests could not.
- **Revoke is eventually consistent (3 hops, ≤15 min)** — the BFF's `/revoke` does only hop 1 (Vault revoke + CRL rotate); hops 2–3 are the CA-host `refresh-crl.sh` + the cluster CRL CronJob. "Propagating forever" = hops 2–3 didn't run (see the enrollment-plane skill / pilot runbook §7). A kept-alive connection isn't re-checked.
- **Sessions/RBAC live in Postgres in prod** (`RBAC_BACKEND=postgres`) — required for >1 replica so logout/revoke are cluster-wide and the BFF HPA is unblocked. In-memory was the v0.1.x single-replica mode.
- **Break-glass `root` always coexists with `AUTH_MODE=ldap`** — keep `BOOTSTRAP_ADMIN_*` as the emergency account. Lost the password → delete `BOOTSTRAP_ADMIN_FILE` (default `./.bootstrap-admin.json`) and restart to regenerate.
- **DB link is plaintext in-cluster** (same ns, internal net) — acceptable for v1; postgres-server-TLS + `DB_SSL_CA` and a `pg_dump` backup CronJob are deferred hardening.
- **Same-origin is the security model** — the SPA only calls `/api/*`, the web pod's nginx reverse-proxies to the BFF service → httpOnly cookies, no CORS, no browser-held secret. Don't break it by exposing the BFF directly.

## Related skills
- `mjbl-enrollment-plane` — the SIGNER (`:8444`) + RELAY (`:8443`) the portal drives; owns the signer admin endpoints (`/devices /revoke /allowlist /activity`), mint/sign/revoke/allowlist wire contracts, and the 3-hop CRL propagation.
- `mjbl-ca-operations` — the 2-tier PKI + Vault the signer issues/revokes from.
- `mjbl-mtls-platform` — the platform-wide index (gateway, clusters, ArgoCD/Fleet topology).
- `mjbl-client-provisioning` — the agency_v2 device/client side that enrolls against this plane.
