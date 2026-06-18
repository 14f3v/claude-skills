---
description: Issue a STANDALONE serverAuth cert for an internal service (NON-gateway) from the MJBL CA — e.g. a Rancher/admin UI on a separate, isolated cluster. Wraps the mjbl-ca-operations skill (MJBL mTLS platform). Does NOT touch the gateway, /etc/ssl/mjbl, or the gateway role.
argument-hint: "<fqdn> [--ip <ip>] [--role mjbl-internal-server-role]   e.g. drk8s.vte.mjblao.local --ip 10.99.1.160"
---

Use the **mjbl-ca-operations** skill — specifically its "Standalone (non-gateway) server-cert issuance" procedure and the bundled `scripts/issue-standalone-server-cert.sh`. This issues a serverAuth leaf for an internal service that must NOT disturb the mTLS gateway.

Target FQDN (and optional IP) from $ARGUMENTS — the first token is the CN/SAN, e.g. `drk8s.vte.mjblao.local --ip 10.99.1.160`.

Hard rules (gateway-safe — do not deviate):
- **NEVER use `issue-server-cert.sh`** here. That one stages into `/etc/ssl/mjbl` and is meant for the gateway's *full* SAN list — running it for one unrelated FQDN clobbers the live gateway cert. Use `issue-standalone-server-cert.sh` (writes only to `--out`, never propagates, never mutates a role).
- Prefer **CSR-sign**: generate the key + CSR on the TARGET host so the private key never reaches the CA, then pass `--csr`.
- Use a **dedicated internal role** (`mjbl-internal-server-role`) so the gateway's `mjbl-platform-role` is untouched. If it doesn't allow the FQDN's domain, the script fails clean — extend that internal role (never the gateway role), or create it (see the skill's procedure).
- Issuance needs Vault auth: use a **short-lived, scoped token** (sign + read on `mjbl-internal-server-role`) via `--token-file` — never the root token. Confirm Vault is **unsealed** first (`vault status`).

Run on the CA host via the prod gate (feed the script over stdin, never `!`-paste a heredoc):
`ssh ca 'sudo -n bash -s -- <fqdn> --role mjbl-internal-server-role --csr /tmp/<svc>.csr --ip <ip> --out /tmp/<svc>-out --token-file /tmp/<scoped>.token' < scripts/issue-standalone-server-cert.sh`

Then pull back the **public** `fullchain.crt` (leaf+intermediate) + `ca-chain.crt` (the `--out` dir is root-owned `700` — `sudo cat` the public certs), install them with the key on the target host, and verify the chain to **MJBL Root** + that the key/cert modulus match before wiring it in. Respect the platform prod gates: CA-host changes go via `! ssh ca`, k8s-config merges + ArgoCD prod writes are user-gated.
