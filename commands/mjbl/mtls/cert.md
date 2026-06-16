---
description: Cert revocation & rotation on the MJBL mTLS platform (device 3-hop revoke, relay/gateway/CA rotation). Wraps the mjbl-cert-lifecycle skill (MJBL mTLS platform).
argument-hint: "[op]  e.g. revoke-device | rotate-relay | rotate-ca"
---

Use the **mjbl-cert-lifecycle** skill as the authoritative source for certificate revocation and rotation on the MJBL mTLS platform. The skill indexes the runbooks under `/home/mjbl/*` (this host is the mTLS remote runner) — treat those as the source of truth:
- `/home/mjbl/mjbl-relay-cert-rotation-runbook.md`
- `/home/mjbl/mjbl-CA-host-rotation-checklist.md`
- `/home/mjbl/mjbl-mtls-revocation-postmortem.md`

Context from $ARGUMENTS: the operation to run.
- `revoke-device` (or a serial / device id) → the **3-HOP** device revocation chain: (1) `vault revoke` + `pki/crl/rotate`, (2) `refresh-crl.sh` on the CA host publishes `:8888` + `crl-bundle.pem`, (3) cluster CronJob `mjbl-crl-refresh` rolls the gateway. `vault revoke` ALONE is NOT enough — verify the revoked cert is actually refused on a NEW handshake.
- `rotate-relay` → enroll-relay TLS cert rotation (local keygen + CSR + `pki/sign/mjbl-platform-role`, imperative Secret re-create, config-revision bump → ArgoCD, verify new serial on `10.88.101.143:8443`, revoke old serial).
- `rotate-ca` / `rotate-server` / `rotate-intermediate` / `rotate-root` → the CA-host rotation checklist (OVERLAP→SWITCH→RETIRE; trust anchors propagate before leafs).
- `refresh-crl` / `enforce-crl` → republish + force-propagate the CRL.
If empty, summarize the skill (the 3-hop revoke chain + the rotation procedures) and ask which operation they need.

Read the specific /home/mjbl runbook the skill points to BEFORE executing any prod-touching step, and respect the prod gates: CA-host changes go via `! ssh ca` (feed scripts as `ssh ca 'sudo -n bash -s' < file` — `!`-paste breaks heredocs), k8s-config merges are user-gated, ArgoCD prod writes are user-gated/denied to the agent. NEVER `kubectl apply` a TLS Secret or dump `tls.key` (the relay-key leak vector); re-create Secrets imperatively.
