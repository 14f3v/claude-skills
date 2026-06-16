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
- Revoke: `vault write pki/revoke serial_number=<serial>`. Publish: `vault write pki/crl/rotate force=true` (or `vault read pki/crl/rotate`). `auto_rebuild` DEFERS CRL regen, so the explicit rotate is mandatory after a revoke. **NOTE:** Vault 2.0 dropped `pki/crl/rotate` as a *write* in the internal-ca demo (405) — but the PROD CA host honors it (`vault read pki/crl/rotate` is the proven call; helper scripts use it).
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
1. **Hop 1 — Vault** (`! ssh ca`): `vault write pki/revoke serial_number=<serial>` then `vault write pki/crl/rotate force=true` (rebuilds Vault's CRL — `auto_rebuild` would otherwise defer it).
2. **Hop 2 — CA host publish:** run `/opt/mjbl-demo/scripts/refresh-crl.sh` on the CA host (rebuilds root CRL via openssl, pulls intermediate CRL from Vault, writes the `:8888` docroot + `/etc/ssl/mjbl/crl-bundle.pem`). The systemd timer does this automatically; run it by hand to not wait.
3. **Hop 3 — Cluster:** CronJob `mjbl-crl-refresh` (ns `mjbl-mtls-gateway`) fetches `:8888`, patches the `mjbl-tls-trust` ConfigMap, rolls nginx (≤15 min on the slow path, ~2–3 min on the tuned `*/2` schedule). Force: `kubectl create job --from=cronjob/mjbl-crl-refresh enforce-now -n mjbl-mtls-gateway` or `enforce-crl-now.sh`.
- `/tmp/mjbl_revoke_device.sh <serial>` does hops 1+2 for you; still confirm hop-3 propagated.
- **Verify enforcement:** force a NEW handshake from the revoked device and confirm refusal at the TLS layer (handshake fail / 400). nginx caches `ssl_crl` in memory until reload, and TLS 1.3 verifies the client cert post-handshake — a kept-alive connection is NOT re-checked, so a correct CRL only bites on the next handshake / after the gateway roll.
- Full detail + the signer audit-log smoking gun (`crl_status:403 / crl_published:false`) in `mjbl-mtls-revocation-postmortem.md`.

### B. Rotate the enroll-relay TLS cert (routine 90d or on key compromise)
Executed 2026-06-05 (new serial `48:3e:8d:78…`). Full runbook: `mjbl-relay-cert-rotation-runbook.md`.
1. **Local ops host:** `openssl genpkey RSA:2048` + CSR with `subjectAltName=DNS:enroll.vte.mjblao.local,DNS:enroll.maruhanjapanbanklao.com,IP:10.88.101.143`. Key NEVER leaves the ops host.
2. **Capture OLD serial** for the later revoke: `kubectl -n mjbl-enroll get secret enroll-relay-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial`.
3. **Sign on CA host** (`! ssh ca`): `scp` the CSR up; `vault write pki/sign/mjbl-platform-role csr=@relay.csr common_name=enroll.vte.mjblao.local alt_names=... ip_sans=10.88.101.143 ttl=2160h`; append `ca_chain[]` to `tls.crt`; `scp` cert back; record NEW serial.
4. **Re-create the Secret IMPERATIVELY** (the leak fix): `kubectl -n mjbl-enroll delete secret enroll-relay-tls` then `kubectl create secret generic … --from-file=tls.crt --from-file=tls.key --from-file=mjbl-root.crt`. NEVER `kubectl apply` a Secret manifest — it writes a `last-applied-configuration` annotation embedding `tls.key`. Verify no annotation: `kubectl -n mjbl-enroll get secret enroll-relay-tls -o jsonpath='{.metadata.annotations}'` prints empty.
5. **Roll the relay GitOps-clean:** bump `mjbl.internal/config-revision` in `deployments/mjbl-mtls-enrollment/production/deployment.fleet.yaml` → k8s-config PR → user merges → ArgoCD auto-syncs (~1 min, `maxUnavailable: 0`).
6. **Verify:** `echo | openssl s_client -connect 10.88.101.143:8443 -servername enroll.vte.mjblao.local | openssl x509 -noout -serial -dates` → expect NEW serial.
7. **Revoke OLD serial** (`! ssh ca`): `vault write pki/revoke serial_number=<OLD>` + `vault write pki/crl/rotate force=true`. CRL CronJob propagates ≤15 min.
8. **Shred local key:** `shred -u tls.key relay.csr`.

### C. Rotate gateway/server cert, intermediate, or root CA
Use `mjbl-CA-host-rotation-checklist.md` — follow OVERLAP→SWITCH→RETIRE (never retire-then-mint; a broken chain fails every mTLS handshake fleet-wide). Trust anchors (root, intermediate) propagate to every consumer BEFORE the leafs that chain to them.
- **Server/gateway cert (§3, routine 90d):** `vault write pki/issue/mjbl-platform-role` → stage into `/etc/ssl/mjbl/` → per-cluster `bootstrap-secrets.sh` (re-renders `mjbl-tls-server` Secret + rollout) → verify handshake serves new serial → optionally `nuke.sh serial <old>` + `refresh-crl.sh`. NOTE: no cluster-side automation today — re-run bootstrap per cluster.
- **Intermediate CA (§2, ~3–5 yr):** mint new int, Root signs (`pathlen:0`, 3650d), `vault write pki/intermediate/set-signed`, rebuild overlap bundle (root + BOTH intermediates), propagate to every cluster ConfigMap, reissue gateway cert + trigger client renewal, keep old-int CRL until last old leaf expires, then retire.
- **Root CA (§1, ~10–20 yr, plan ≥2 yr early):** DISTRIBUTE new root FIRST (additive — every trust store trusts BOTH), then sign/cross-sign intermediate, switch issuance, verify, retire old root only after all consumers migrated.
- **CRL (§5):** `refresh-crl.sh` regenerates root + intermediate CRLs (30-day validity, weekly refresh, `mjbl-crl-refresh` CronJob pulls). Alert on `kube_job_status_failed{job_name=~"mjbl-crl-refresh.*"}`.

## Gotchas & hard-won lessons
- **`vault revoke` ≠ enforced.** The post-mortem's whole lesson: revocation is a multi-hop, pull-based, eventually-consistent chain. Any hop can fail silently. Always complete all 3 hops AND verify a revoked cert is actually refused on a fresh handshake.
- **IaC drift broke the security control.** The `pki/crl/rotate` grant was committed in `signer/mjbl-enroll.policy.hcl` but never `vault policy write`'d to live Vault → every revoke logged `crl_status:403 / crl_published:false` and the CRL never updated. A grant in git is NOT a grant in Vault. Reconcile repo ↔ live.
- **nginx caches `ssl_crl` in memory until reload** and **TLS 1.3 verifies the client cert post-handshake** — a kept-alive connection is not re-checked mid-stream. A correct CRL only bites on the next handshake / after a gateway roll.
- **`pki/crl/rotate` is a READ on the prod CA host** (the proven call is `vault read pki/crl/rotate`; `force=true` via write also works in the runbooks). In the internal-ca demo (Vault 2.0) the *write* returns 405 — don't confuse the two environments; swallow 405 only in demo scripts.
- **NEVER `kubectl apply` a TLS Secret** — it embeds `tls.key` in the `last-applied-configuration` annotation (this is exactly how the relay key leaked into a transcript). Always re-create imperatively; verify no annotation. Never `kubectl get secret … -o yaml/json` (base64-dumps the key) and never `cat`/`echo` `tls.key`.
- **`!`-paste indents heredoc delimiters and breaks scripts.** Feed scripts to the CA host via `ssh ca 'sudo -n bash -s' < file` (or a quoted heredoc) rather than pasting.
- **Operator kubeconfig discipline:** prod ops MUST `export KUBECONFIG=~/.kube/mjbl-prod.config`. A non-prod default context sent force-jobs to the wrong cluster during the post-mortem — a red herring that cost diagnosis time.
- **Don't use the root token for routine cert ops** (steps sign/revoke pull `root_token` from `.vault-init.json`) — deferred hardening is a scoped issuance token.
- **Durable fix for instant revocation is OCSP** (per-handshake, no roll-per-revoke, no propagation lag) — planned in `mjbl-gateway-ocsp-plan.md`, not yet shipped.

## Related skills
- `internal-ca` — the 2-tier PKI bootstrap (Root + Intermediate + Vault PKI + OCSP/CRL servers + `nuke.sh`) this lifecycle operates on.
- `mtls` — client-cert issuance, `ssl_verify_client` enforcement, and CRL-based revocation wiring the gateway depends on.
