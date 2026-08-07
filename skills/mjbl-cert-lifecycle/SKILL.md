---
name: mjbl-cert-lifecycle
description: This skill should be used when the user asks to "revoke a device", "rotate the relay cert", "rotate the CA host cert", "rotate the gateway/server cert", "rotate the intermediate/root CA", "why is a revoked device still logging in", "publish the CRL", "the device wasn't kicked out after revoke", or any cert revocation/rotation operation on the live MJBL mTLS platform (the deployed PKI ecosystem on this host). Covers device revocation (the 3-hop CRL enforcement chain), relay TLS cert rotation, gateway/server cert rotation, intermediate/root CA rotation, and the hard lessons from the revocation post-mortem.
version: 0.1.0
---

# MJBL Cert Lifecycle — Revocation & Rotation

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname root-ca, the MJBL mTLS *remote runner*) holds the authoritative runbooks. This skill is the operational index + distilled live facts — READ the referenced docs before any prod-touching step:
> - `/home/mjbl/mjbl-relay-cert-rotation-runbook.md` — full enroll-relay TLS cert rotation (local keygen + CSR + `pki/sign`, imperative Secret re-create, ArgoCD roll, revoke old serial). Includes the no-key-leak guardrails.
> - `/home/mjbl/mjbl-CA-host-rotation-checklist.md` — production CA-host rotation checklist for every asset (root, intermediate, gateway/server, client, CRL, OCSP, Vault) with the OVERLAP→SWITCH→RETIRE golden rule, propagation matrix, and post-rotation verification gate.
> - `/home/mjbl/mjbl-mtls-revocation-postmortem.md` — the 2026-06-09 incident: revoked devices kept authenticating because the signer's Vault AppRole lacked `pki/crl/rotate`. Source of the 3-hop CRL lesson and the hardening action items.

## When to use
- Revoking a lost / decommissioned / compromised device cert AND making the gateway actually refuse it (the 3-hop chain — `vault revoke` alone is NOT enough).
- Diagnosing "I revoked the device but it's still logging in" (the post-mortem's exact failure mode).
- Rotating the enroll-relay TLS server cert (`enroll-relay-tls`) — routine 90-day TTL or compromise.
- Rotating the gateway/server cert, the intermediate CA, or the root CA on the production CA host.
- Refreshing / republishing the CRL, or verifying revocation is enforced end-to-end.

## Architecture / live facts
**Hosts & network**
- **CA host** (`ca-crl` VM, `mjbl-ca-crl`): `10.88.1.116`. Reach it as jump-host alias `ca` (`! ssh ca`). Runs Vault (`https://127.0.0.1:8200`, Raft, `VAULT_SKIP_VERIFY=true`), the signer (`:8444`), the OCSP responder (`:2560`), and the CRL HTTP publisher (`:8888`).
- **Enroll relay** LB VIP `10.88.101.143:8443` (internal), ns `mjbl-enroll`, Deployment `mjbl-enroll-relay`, Secret `enroll-relay-tls` (keys `tls.crt`, `tls.key`, `mjbl-root.crt`). SANs: `enroll.vte.mjblao.local`, `enroll.maruhanjapanbanklao.com`, IP `10.88.101.143`. Issued from Vault `pki/sign/mjbl-platform-role` (serverAuth, RSA-2048, 2160h).
- **mTLS gateway** ns `mjbl-mtls-gateway`; nginx enforces `ssl_crl` from the `mjbl-tls-trust` ConfigMap; CronJob `mjbl-crl-refresh` keeps that ConfigMap fresh.

**Vault PKI**
- Issuing role for server/relay certs: `pki/sign/mjbl-platform-role` (CSR-signing) / `pki/issue/mjbl-platform-role` (issue w/ key). Client role: `mjbl-branch-client-role`.
- Revoke: `vault write pki/revoke serial_number=<serial>`. Publish: **`vault read pki/crl/rotate`** — the write form returns **405 unsupported operation** on this build (verified 2026-08-06 with BOTH the root and cert-ops tokens, so it is an endpoint limit, not a permission issue). `auto_rebuild` DEFERS CRL regen, so the explicit rotate is mandatory after a revoke. The signer and the helper scripts already use the read form; only the human-facing docs ever claimed otherwise.
- Root token at `/home/mjbl/.vault-init.json` (`jq -r .root_token`). Hardening TODO: scope to a non-root issuance token.
- Signer AppRole policy `mjbl-enroll` (repo `signer/mjbl-enroll.policy.hcl`) MUST grant `path "pki/crl/rotate" { capabilities = ["read"] }` — the missing grant was the post-mortem root cause.

**CRL publication (the 3-hop chain consumers)**
1. Vault internal CRL (rebuilt by `pki/crl/rotate`).
2. CA host `:8888` docroot (`/opt/mjbl-demo/crl-serve/crl/`) + `/etc/ssl/mjbl/crl-bundle.pem` (nginx `ssl_crl`) — published by `/opt/mjbl-demo/scripts/refresh-crl.sh` (root CRL via `openssl ca -gencrl`; intermediate CRL pulled from Vault `curl /v1/pki/crl/pem`). Now also auto-published by a CA-host systemd timer (hop-2 automation, ~1 min).
3. Cluster CronJob `mjbl-crl-refresh` (ns `mjbl-mtls-gateway`, schedule `*/2`) fetches `10.88.1.116:8888` → patches the `mjbl-tls-trust` ConfigMap → rolls the gateway. Propagation ~2–3 min; force with `kubectl create job --from=cronjob/mjbl-crl-refresh <name> -n mjbl-mtls-gateway` (or `enforce-crl-now.sh` ~30 s).

**Helper scripts (ops host / CA host)**
- `/tmp/mjbl_revoke_device.sh` — does **hops 1 + 2** (vault revoke + rotate, then `refresh-crl.sh` on the CA host). Hop-3 is the cluster CronJob (auto ≤15 min, or force).
- `/opt/mjbl-demo/scripts/refresh-crl.sh` (on CA host) — hop-2 republisher.
- `enforce-crl-now.sh` — on-demand full enforcement (~30 s).

## Key procedures

### A. Revoke a device — the 3-HOP enforcement chain (vault revoke alone is NOT enough)
The whole point: marking the cert revoked in Vault does **not** make the gateway refuse it. All three hops must complete and a NEW handshake must occur.
1. **Hop 1 — Vault** (`! ssh ca`): `vault write pki/revoke serial_number=<serial>` then **`vault read pki/crl/rotate`** (rebuilds Vault's CRL — `auto_rebuild` would otherwise defer it).
2. **Hop 2 — CA host publish:** run `/opt/mjbl-demo/scripts/refresh-crl.sh` on the CA host (rebuilds root CRL via openssl, pulls intermediate CRL from Vault, writes the `:8888` docroot + `/etc/ssl/mjbl/crl-bundle.pem`). The systemd timer does this automatically; run it by hand to not wait.
3. **Hop 3 — Cluster:** CronJob `mjbl-crl-refresh` (ns `mjbl-mtls-gateway`) fetches `:8888`, patches the `mjbl-tls-trust` ConfigMap, rolls nginx (≤15 min on the slow path, ~2–3 min on the tuned `*/2` schedule). Force: `kubectl create job --from=cronjob/mjbl-crl-refresh enforce-now -n mjbl-mtls-gateway` or `enforce-crl-now.sh`.
- `/tmp/mjbl_revoke_device.sh <serial>` does hops 1+2 for you; still confirm hop-3 propagated.
- **Verify enforcement:** force a NEW handshake from the revoked device and confirm refusal at the TLS layer (handshake fail / 400). nginx caches `ssl_crl` in memory until reload, and TLS 1.3 verifies the client cert post-handshake — a kept-alive connection is NOT re-checked, so a correct CRL only bites on the next handshake / after the gateway roll.
- Full detail + the signer audit-log smoking gun (`crl_status:403 / crl_published:false`) in `mjbl-mtls-revocation-postmortem.md`.

### B. Rotate the enroll-relay TLS cert (routine 90d or on key compromise)
Last executed **2026-08-06** (new serial `3d:47:c0:16…`, expires **2026-11-04**; old
`48:3e:8d:78…` revoked). Full runbook: `mjbl-relay-cert-rotation-runbook.md`.

> ⚠️ **This cert is now on the client-cert auto-renewal critical path.** Devices renew via
> `POST /renew`, so if it lapses **every device renewal fails at the handshake**. Rotate on
> time, and after rotating verify `/renew` — not just `/enroll`.
>
> **Keep ALL FOUR SANs.** Since 2026-08-07 renewal is public: the device connects to
> `https://microloan.maruhanjapanbanklao.com:2401`, the gateway passes the bytes through
> **without decrypting**, and **TLS terminates at the RELAY** — so the device validates the
> `microloan` name against *this* cert, not the gateway's. Drop that SAN and every public
> renewal fails `no alternative certificate subject name matches` while `/enroll` still looks
> perfectly healthy. Current cert expires **2026-11-05**.
1. **Local ops host:** `openssl genpkey RSA:2048` + CSR with `subjectAltName=DNS:enroll.vte.mjblao.local,DNS:enroll.maruhanjapanbanklao.com,DNS:microloan.maruhanjapanbanklao.com,IP:10.88.101.143`. Key NEVER leaves the ops host.
2. **Capture OLD serial** for the later revoke: `kubectl -n mjbl-enroll get secret enroll-relay-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial`.
3. **Sign on CA host** (`! ssh ca`): `scp` the CSR up; `vault write pki/sign/mjbl-platform-role csr=@relay.csr common_name=enroll.vte.mjblao.local alt_names=... ip_sans=10.88.101.143 ttl=2160h`; append `ca_chain[]` to `tls.crt`; `scp` cert back; record NEW serial.
4. **Re-create the Secret IMPERATIVELY** (the leak fix): `kubectl -n mjbl-enroll delete secret enroll-relay-tls` then `kubectl create secret generic … --from-file=tls.crt --from-file=tls.key --from-file=mjbl-root.crt`. NEVER `kubectl apply` a Secret manifest — it writes a `last-applied-configuration` annotation embedding `tls.key`. **delete+create is also the ONLY way to REMOVE an annotation that already exists** — applying (even server-side) will not strip it. Verify with the **names-only** check below.
5. **Roll the relay GitOps-clean:** bump `mjbl.internal/config-revision` in `deployments/mjbl-mtls-enrollment/production/deployment.fleet.yaml` → k8s-config PR → user merges → ArgoCD auto-syncs (~1 min, `maxUnavailable: 0`).
6. **Verify BOTH paths** — internal serial *and* the public renewal edge, because they exercise different SANs and different sockets:
   ```bash
   echo | openssl s_client -connect 10.88.101.143:8443 -servername enroll.vte.mjblao.local \
     | openssl x509 -noout -serial -dates                       # NEW serial
   curl -sS -o /dev/null -w '%{http_code}\n' https://microloan.maruhanjapanbanklao.com:2401/renew
   # expect 401 (client_cert_required) — proves the public listener + SAN + NAT all still work.
   # /enroll on :2401 must return 404, NOT 401: renew-only gating is intact.
   ```
7. **Revoke OLD serial** (`! ssh ca`): `vault write pki/revoke serial_number=<OLD>` + **`vault read pki/crl/rotate`**. CRL CronJob propagates ≤15 min.
8. **Shred local key:** `shred -u tls.key relay.csr`.

### C. Rotate gateway/server cert, intermediate, or root CA
Use `mjbl-CA-host-rotation-checklist.md` — follow OVERLAP→SWITCH→RETIRE (never retire-then-mint; a broken chain fails every mTLS handshake fleet-wide). Trust anchors (root, intermediate) propagate to every consumer BEFORE the leafs that chain to them.
- **Server/gateway cert (§3, routine 90d):** last rotated **2026-08-06** (serial `56:cb:c9:b0…`, expires **2026-11-04**; old `64:56:3f:54…` revoked as key-compromised). **Prefer `pki/sign` + a locally-generated key over `pki/issue`** — `pki/issue` makes Vault generate the private key and writes it onto the CA host. Then **delete+create** the `mjbl-tls-server` Secret (not `bootstrap-secrets.sh`, if an annotation must be removed) → `rollout restart` → verify the served serial **and run the canary selftest before revoking** → `vault write pki/revoke` + `pki/crl/rotate` + `refresh-crl.sh`.
  - ⚠️ **`mjbl-CA-host-rotation-checklist.md` §3's example CN was WRONG** until 2026-08-06 (`agenttest.maruhanjapanbanklao.com`; production is `microloan.maruhanjapanbanklao.com`). **Always read the CN/SANs off the LIVE handshake** — never from a document. The gateway has **one** SAN and **no IP SAN**, unlike the relay.
  - Role constraints: `mjbl-platform-role` = **RSA-2048**, `max_ttl` exactly **2160h**. Client certs use `mjbl-branch-client-role` = **EC P-256**, `clientAuth` only.
  - NOTE: no cluster-side automation today — tracked as **k8s-config#119** (cert-manager + Vault issuer, `renewBefore: 720h`).
- **Intermediate CA (§2, ~3–5 yr):** mint new int, Root signs (`pathlen:0`, 3650d), `vault write pki/intermediate/set-signed`, rebuild overlap bundle (root + BOTH intermediates), propagate to every cluster ConfigMap, reissue gateway cert + trigger client renewal, keep old-int CRL until last old leaf expires, then retire.
- **Root CA (§1, ~10–20 yr, plan ≥2 yr early):** DISTRIBUTE new root FIRST (additive — every trust store trusts BOTH), then sign/cross-sign intermediate, switch issuance, verify, retire old root only after all consumers migrated.
- **CRL (§5):** `refresh-crl.sh` regenerates root + intermediate CRLs (30-day validity, weekly refresh, `mjbl-crl-refresh` CronJob pulls). Alert on `kube_job_status_failed{job_name=~"mjbl-crl-refresh.*"}`.

### D. Server-cert expiry monitoring + the scoped `cert-ops` token (Aug 2026)
Both production server certs were found **26 and 28 days from expiry, unwatched**, in the middle of
the renewal rollout — and the relay cert sits on the renewal critical path, so it expiring would
have taken out the very mechanism meant to keep the fleet alive. Both were rotated
(gateway → **2026-11-04**, relay → **2026-11-05**). Two controls came out of it:
- **`k8s-config/tools/cert-ops/mjbl-server-cert-renew.sh`** — `--check` (default) / `--renew`,
  installed as **`mjbl-server-cert-check.timer`** (daily `--check`). "Comfortable headroom" was the
  vague check that let three certs drift; a timer with a number is the fix.
- **`k8s-config/vault/cert-ops.policy.hcl`** — a scoped policy replacing the root token for routine
  cert ops. Grants `pki/sign/mjbl-platform-role`, `pki/sign/mjbl-branch-client-role`, `pki/revoke`,
  `pki/crl/rotate` (read+update), read-only `pki/cert/*`, `pki/certs`, `pki/roles/*`.
  **DENIES** `pki/issue/*`, `pki/root/*`, `pki/config/*`, `pki/intermediate/*`, `pki/tidy*`,
  `sys/*`, `enroll/*` — so a leaked cert-ops token cannot mint a key it holds, re-sign the
  intermediate, or reach the enrollment token store.

## Gotchas & hard-won lessons
- **`vault revoke` ≠ enforced.** The post-mortem's whole lesson: revocation is a multi-hop, pull-based, eventually-consistent chain. Any hop can fail silently. Always complete all 3 hops AND verify a revoked cert is actually refused on a fresh handshake.
- **IaC drift broke the security control.** The `pki/crl/rotate` grant was committed in `signer/mjbl-enroll.policy.hcl` but never `vault policy write`'d to live Vault → every revoke logged `crl_status:403 / crl_published:false` and the CRL never updated. A grant in git is NOT a grant in Vault. Reconcile repo ↔ live.
- **nginx caches `ssl_crl` in memory until reload** and **TLS 1.3 verifies the client cert post-handshake** — a kept-alive connection is not re-checked mid-stream. A correct CRL only bites on the next handshake / after a gateway roll.
- **🚨 `pki/crl/rotate` is a READ — the write does NOT work, anywhere.** `vault read pki/crl/rotate` → 200 `{"success":true}`. `vault write pki/crl/rotate force=true` → **405 unsupported operation**, measured 2026-08-06 on the PROD CA host with the root token *and* the cert-ops token, so it is an endpoint limitation, not a policy denial. Earlier docs (this skill included) claimed the write "also works in the runbooks" — **it never did**; it fails silently, and any script without a `|| vault read` fallback leaves the CRL un-rebuilt while the revoke appears to succeed. That is precisely the 2026-06 incident signature (`crl_status:403 / crl_published:false`). The signer already does it correctly (`GET pki/crl/rotate`); only the human-facing docs were wrong.
- **NEVER `kubectl apply` a TLS Secret** — it embeds `tls.key` in the `last-applied-configuration` annotation (this is exactly how the relay key leaked into a transcript). Always re-create imperatively; verify no annotation. Never `kubectl get secret … -o yaml/json` (base64-dumps the key) and never `cat`/`echo` `tls.key`.
- **🚨 NEVER print an annotation VALUE on a Secret — print annotation NAMES only.** The check this skill used to recommend, `-o jsonpath='{.metadata.annotations}'`, prints nothing when the annotation is ABSENT but dumps the whole value — i.e. **the base64 private key** — when it is PRESENT. That is the exact case the check exists to detect, so the documented check leaks the key it is looking for. **This bit for real on 2026-08-06** against `mjbl-tls-server`, forcing an unplanned gateway key rotation (k8s-config#115). Use:
  ```bash
  kubectl -n NS get secret S -o go-template='{{range $k,$v := .metadata.annotations}}{{$k}}{{"\n"}}{{end}}'
  ```
- **`create --dry-run=client -o yaml | kubectl apply -f -` IS an apply.** Rendering with `create` proves nothing; the **write verb** is what writes the annotation. `bootstrap-secrets.sh` did exactly this and silently embedded `service.key` on every run for two months, while a runbook asserted it "uses `create`, not `apply`". Fixed in k8s-config#114 (`apply --server-side` + a post-apply guard that fails if the annotation reappears). **Lesson: verify the claim, don't restate it.**
- **A written-down audit that is never run is worth nothing.** The relay runbook's own follow-up said "audit the gateway server cert the same way" — it sat unactioned for two months and would have caught the above immediately.
- **`/etc/ssl/mjbl/` on the OPS host (192.168.1.25) is STALE.** Its `root-ca.crt` / `intermediate-ca.crt` are *different certificates* with the *same subject names* (dated May 2026) from what Vault issues against today. Verifying a fresh cert against them fails with a misleading `error 20 unable to get local issuer certificate`. Use the **CA host's** copy or the chain Vault just returned, and compare by **SHA-256 fingerprint, not subject name**.
- **Reproduce the wire chain length.** The gateway serves **2** certs (leaf+intermediate, no root); the relay serves **3**. `jq -r '.data.ca_chain[]'` yields 3 — trim for the gateway. Check the live handshake before installing.
- **`!`-paste indents heredoc delimiters and breaks scripts.** Feed scripts to the CA host via `ssh ca 'sudo -n bash -s' < file` (or a quoted heredoc) rather than pasting.
- **Operator kubeconfig discipline:** prod ops MUST `export KUBECONFIG=~/.kube/mjbl-prod.config`. A non-prod default context sent force-jobs to the wrong cluster during the post-mortem — a red herring that cost diagnosis time.
- **Don't use the root token for routine cert ops** (steps sign/revoke pull `root_token` from `.vault-init.json`) — deferred hardening is a scoped issuance token.
- **Durable fix for instant revocation is OCSP** (per-handshake, no roll-per-revoke, no propagation lag) — planned in `mjbl-gateway-ocsp-plan.md`, not yet shipped.
- **Nothing tracks server-cert expiry — check it explicitly.** In Aug 2026 the gateway (T+26d), relay (T+28d) and revocation canary (T+32d) had ALL drifted under 35 days with nothing alerting, and were found only by manually inspecting a live handshake while investigating something unrelated. The client-cert auto-renewal work renews **device** certs only; **nothing renews these**. Treat **<30 days as act-now**:
  ```bash
  for t in "10.88.101.142:2399 microloan.maruhanjapanbanklao.com" \
           "10.88.101.143:8443 enroll.vte.mjblao.local"; do set -- $t
    echo -n "$2  "; echo | openssl s_client -connect $1 -servername $2 2>/dev/null | openssl x509 -noout -enddate; done
  kubectl -n mjbl-mtls-gateway get secret revocation-canary -o jsonpath='{.data.valid\.crt}' \
    | base64 -d | openssl x509 -noout -subject -enddate     # no provisioning script exists for this one
  ```

## Current expiry inventory (as of 2026-08-06)

| Consumer | Serial | Expires |
|---|---|---|
| gateway `microloan.maruhanjapanbanklao.com` | `56:cb:c9:b0…` | **2026-11-04** |
| relay `enroll.vte.mjblao.local` | `3d:47:c0:16…` | **2026-11-04** |
| revocation canary (valid) | `36:e1:97:ae…` | **2026-11-04** |
| MJBL Intermediate CA | — | 2036-05-31 |
| MJBL Root CA | — | 2046-05-29 |

⚠️ **All three leaf consumers expire the same day** — an artefact of rotating them together
during the Aug 2026 incident. Either offset one deliberately at the next rotation, or land
**k8s-config#119** first, which makes co-expiry irrelevant.

## Related skills
- `internal-ca` — the 2-tier PKI bootstrap (Root + Intermediate + Vault PKI + OCSP/CRL servers + `nuke.sh`) this lifecycle operates on.
- `mtls` — client-cert issuance, `ssl_verify_client` enforcement, and CRL-based revocation wiring the gateway depends on.
