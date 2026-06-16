---
description: Operate the live MJBL production CA — Vault PKI, OCSP/CRL, CA-host rotation, prod hardening. Wraps the mjbl-ca-operations skill (MJBL mTLS platform).
argument-hint: "[task]  e.g. vault-status | crl-refresh | rotate-ca | rotate-server-cert | hardening | ocsp"
---

Use the **mjbl-ca-operations** skill as the authoritative source for CA / Vault / PKI / OCSP / CRL / rotation / hardening operations on the MJBL mTLS platform. The skill indexes the runbooks under `/home/mjbl/*` (this host is the mTLS remote runner) — treat those as the source of truth: `mjbl-internal-CA-implementation.md`, `mjbl-internal-CA-implementation-x-client-certs.md`, `mjbl-CA-host-rotation-checklist.md`, `mjbl-prod-hardening-checklist.md`, `mjbl-gateway-ocsp-plan.md`.

Context from $ARGUMENTS: the task to perform on the CA host (10.88.1.116). Map it to the right runbook section —
- `vault-status` / `unseal` → check `vault status && vault token lookup`; unseal ×3 if sealed (rotation §0, hardening P0).
- `crl-refresh` / `publish-crl` → `refresh-crl.sh` + confirm `:8888` serves BOTH root + intermediate; `pki/crl/rotate` is a **READ** not a write (rotation §5).
- `revoke` → 3-hop revoke (`nuke.sh serial` → `refresh-crl.sh` → cluster CronJob); verify TLS-layer rejection (rotation §3/§4).
- `rotate-ca` / `rotate-root` / `rotate-intermediate` → OVERLAP→SWITCH→RETIRE, additive-trust-first (rotation §1/§2).
- `rotate-server-cert` → `vault issue pki/issue/mjbl-platform-role` → stage `/etc/ssl/mjbl/` → propagate per cluster (rotation §3).
- `rotate-vault` / `keys-off-host` / `approle` → Vault secret hygiene (rotation §7, hardening P0).
- `hardening` → walk the P0→P2 checklist; lead with keys-off-host + AppRole + auto-unseal + Fleet.
- `ocsp` → the gateway real-time-revocation design + responder-placement decision (ocsp plan).

If empty, summarize the skill's "Architecture / live facts" (CA host, 2-tier PKI, Vault 2.0.1 Raft, the `mjbl-platform-role` serverAuth / `mjbl-branch-client-role` EC-P-256 clientAuth split, OCSP `:2560`, CRL `:8888`) and ask which task they need.

Read the specific /home/mjbl runbook the skill points to BEFORE executing any prod-touching step, and respect the prod gates: CA-host changes go via `! ssh ca` (feed scripts as `ssh ca 'sudo -n bash -s' < file`, never `!`-paste heredocs), k8s-config merges are user-gated, ArgoCD prod writes are user-gated/denied to the agent. Never retire trust material before the new material is distributed and proven (a broken chain locks out every branch at the TLS layer).
