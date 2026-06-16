---
description: Operate the MJBL device-enrollment plane — mint/sign/revoke/allowlist, signer+relay logs, relay deploy, relay cert rotation. Wraps the mjbl-enrollment-plane skill (MJBL mTLS platform).
argument-hint: "[action]  e.g. mint | allowlist | logs | deploy | rotate-relay"
---

Use the **mjbl-enrollment-plane** skill as the authoritative source for the device-enrollment plane (SIGNER on CA host `10.88.1.116:8444` + cluster RELAY on `10.88.101.143:8443`) on the MJBL mTLS platform. The skill indexes the runbooks under `/home/mjbl/*` (this host is the mTLS remote runner) — treat those as the source of truth: `mjbl-mtls-enrollment/DEPLOY.md`, the signer/relay source, `mjbl-relay-cert-rotation-runbook.md`, `mjbl-enrollment-app-golive-plan.md`.

Context from $ARGUMENTS: the requested action.
- `mint` — mint a one-time enrollment / claim token (`POST /mint`, admin-bearer); confirm branch + uuid (omit uuid for a claim/QR token) and that the branch is on the allowlist.
- `allowlist` — list/add/remove a branch (`/allowlist` or the on-disk `/opt/mjbl-enroll/allowlist`).
- `revoke` — revoke a device cert (`POST /revoke`) and remember the 3-hop CRL propagation (signer rotate → CA-host `refresh-crl.sh` → cluster `mjbl-crl-refresh` CronJob).
- `logs` / `status` — read `/var/log/mjbl-enrollment.log`, `journalctl -u mjbl-enroll-signer`, `/healthz`, and the relay pods.
- `deploy` — build/push `enroll-relay:<bumped-tag>`, apply the Fleet manifests, bootstrap the Secret LAST.
- `rotate-relay` — follow `mjbl-relay-cert-rotation-runbook.md` (local keygen → `pki/sign` → imperative Secret re-create → config-revision bump → revoke old).
If empty, summarize the plane's live facts (hosts/IPs/ports/endpoints/allowlists) from the skill and ask which action they need.

Read the specific /home/mjbl runbook the skill points to BEFORE executing any prod-touching step, and respect the prod gates: CA-host changes (`:8444` mint/revoke/allowlist, Vault, signer systemd) go via `! ssh ca` — the agent cannot reach the CA host directly; k8s-config merges (the `config-revision` bump, manifest changes) are user-gated; ArgoCD prod writes are user-gated/denied to the agent. Never `kubectl apply` the `enroll-relay-tls` Secret or `kubectl get secret … -o yaml/json` (leaks `tls.key`). If a device reports "could not reach the enrollment server" with NO matching line in the audit log/journal, suspect the body-read-hang (signer `_read_json` has no socket read timeout) before anything else.
