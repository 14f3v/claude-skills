---
description: Operate the MJBL operator portal — BFF/RBAC/AD-HTTP-delegate login, signer admin endpoints, prod deploy + P5 cutover/rollback. Wraps the mjbl-operator-portal skill (MJBL mTLS platform).
argument-hint: "[task]  e.g. deploy | ldap-auth | rbac | cutover"
---

Use the **mjbl-operator-portal** skill as the authoritative source for the operator portal — the React-SPA + Bun/Hono BFF console (mint/revoke/inventory/activity) — on the MJBL mTLS platform. The skill indexes the runbooks under `/home/mjbl/*` (this host is the mTLS remote runner) — treat those as the source of truth: `mjbl-operator-portal-runbook.md`, `mjbl-mtls-portal-p5-prod-golive-runbook.md`, the monorepo `/home/mjbl/mjbl-operator-portal/`, the cutover script `/home/mjbl/mjbl-mtls-portal-p5-cutover.sh`, and `~/.ldapserver`.

Context from $ARGUMENTS: the requested task.
- `deploy` / `build` — build the two images (BFF from the repo root, web from `applications/operator-portal-web`) → GHCR → bump the prod fleet tag in `k8s-config` (PR, **user-merged**) → ArgoCD app `mjbl-mtls-portal` rolls ns `mjbl-mtls-operator-portal`. Keep the BFF on an internal-zone node (egress IP on the signer's `SIGNER_ALLOW`).
- `ldap-auth` / `login` — AD login is **HTTP-DELEGATE**: `AUTH_MODE=ldap` + `LDAP_AUTH_SERVICE_URL=http://10.88.2.82:3001/ldap/authziedUser` (the BFF POSTs `{meta:{user,password}}` and trusts `{meta:{authorized}}`). Do NOT configure/troubleshoot a direct `ldap://`/`ldaps://` bind — the pod is firewalled off the DC. Troubleshoot service reachability + envelope shape.
- `rbac` — roles from AD group DNs (HQ Admin / Branch Officer branch-scoped / Auditor); `RBAC_BACKEND=postgres` in prod (sessions + dynamic RBAC in the Postgres StatefulSet); `LDAP_GROUP_*` are exact full group DNs.
- `cutover` — the P5 go-live (bootstrap/in-memory → Postgres RBAC + AD): deploy the **v0.2.1** image (with `httpLdapAuth`) FIRST, then run `bash /home/mjbl/mjbl-mtls-portal-p5-cutover.sh` (arg-less), then verify. Rollback = patch the env Secret `mjbl-mtls-operator-portal-env` back to `AUTH_MODE=bootstrap`/`RBAC_BACKEND=memory` + `rollout restart`.
- `run` / `local` — run the stack locally (bootstrap admin + mock signer, or `deploy/dev-ca` for a real signer with no prod access).
- `signer-endpoints` — the BFF's backend admin endpoints `/devices /revoke /allowlist /activity` on the signer (deploy via `! ssh ca`; owned by the mjbl-enrollment-plane skill).
If empty, summarize the portal's live facts (tiers, ns/ArgoCD app, the HTTP-delegate auth model, current prod = v0.2.1 AD-login confirmed) from the skill and ask which task they need.

Read the specific /home/mjbl runbook the skill points to BEFORE executing any prod-touching step, and respect the prod gates: CA-host / signer changes (`:8444`, the admin endpoints, `mjbl-enroll-signer`) go via `! ssh ca` — the agent cannot reach the CA host directly; k8s-config merges (image-tag bumps, manifest/Postgres PRs) are user-gated; ArgoCD prod writes are user-gated/denied to the agent. The cutover must deploy the v0.2.1 image before flipping the env Secret (the script aborts otherwise). Never put the signer admin token or `SESSION_SECRET` in `example.env`/the browser, and never break the same-origin model (SPA → `/api/*` → BFF only).

RULES: be accurate — VERIFY facts against the actual source docs (Read them; grep the repo) before quoting an IP/path/service/env-key. Do NOT invent figures — use the exact ones from the runbooks (`mjbl-mtls-operator-portal`, `mjbl-mtls-portal`, `http://10.88.2.82:3001/ldap/authziedUser`, BFF `PORT=8787`, `10.88.1.116:8444`, v0.2.1). If asked for a direct-bind LDAP config in prod, correct the user: prod uses the HTTP-delegate.
