---
name: mjbl-ca-operations
description: This skill should be used when the user asks to operate, rotate, or harden the live MJBL production CA — "check vault status / unseal vault", "refresh the CRL", "rotate the root/intermediate CA", "rotate the gateway server cert", "rotate vault token / move keys off-host", "publish a CRL", "set up OCSP for the gateway", "harden the CA host", "revoke a serial on the CA host", "issue a standalone serverAuth cert for an internal service (non-gateway — e.g. a Rancher/admin UI on a separate, isolated cluster)", or any PKI/Vault/OCSP/CRL operation on the CA host (10.88.1.116). This is the MJBL mTLS platform — the live deployed PKI ecosystem on this host. It indexes the authoritative runbooks under /home/mjbl and distills the live prod facts.
version: 0.2.0
---

# MJBL CA Operations — Vault PKI / OCSP / CRL / rotation / hardening

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname root-ca, the MJBL mTLS *remote runner*) holds the authoritative runbooks. This skill is the operational index + distilled live facts — READ the referenced docs before any prod-touching step:
> - `/home/mjbl/mjbl-internal-CA-implementation.md` — the canonical 2-tier PKI build (Phases 0–9): Root + Intermediate, Vault PKI engine, OCSP responder `:2560`, CRL server `:8888`, `refresh-crl.sh`, `nuke.sh`, `verify-all.sh` (18-check). Exact configs, paths, verify gates.
> - `/home/mjbl/mjbl-internal-CA-implementation-x-client-certs.md` — mTLS follow-on: `clientAuth` client certs, PKCS#12 bundling, `ssl_verify_client`, CRL-based client revocation, `verify-mtls.sh` (13-check).
> - `/home/mjbl/mjbl-CA-host-rotation-checklist.md` — THE prod rotation runbook. Golden Rule (OVERLAP→SWITCH→RETIRE), cadence table, §1 root / §2 intermediate / §3 server cert / §4 client / §5 CRL / §6 OCSP / §7 Vault secrets / §8 verify gate + propagation matrix.
> - `/home/mjbl/mjbl-prod-hardening-checklist.md` — what's left to harden, P0→P2. The two that matter: Vault secret hygiene (keys off-host + AppRole + auto-unseal) and Fleet wiring.
> - `/home/mjbl/mjbl-gateway-ocsp-plan.md` — design+plan for real-time per-handshake client-cert revocation at the gateway (`ssl_ocsp on`), the DMZ↔CA firewall constraint, responder-placement decision.

## When to use
- "Is Vault unsealed?" / "unseal vault" / "check vault status" / Vault sealed after a CA-host reboot (issuance + CRL refresh silently halt until unsealed).
- "Refresh / publish the CRL", a CRL `nextUpdate` is approaching, or a revoked device isn't being rejected (CRL not propagated through all hops).
- "Rotate the root CA" / "rotate the intermediate" / "rotate the gateway server cert" / "rotate the OCSP responder cert" / "rotate the Vault token or unseal keys."
- "Revoke a cert / serial on the CA host" (the signer/operator-portal path also exists; this is the CA-host `nuke.sh` path).
- "Issue a standalone server cert" / "issue a serverAuth cert for an internal service" — a cert for a host that is **NOT** the gateway (e.g. a Rancher/admin UI on a separate, isolated cluster). Use the dedicated standalone issuer (`scripts/issue-standalone-server-cert.sh`), **never** the gateway tool.
- "Harden the CA" / "get keys off the host" / "set up AppRole" / "auto-unseal" / "wire Fleet."
- "Set up OCSP at the gateway" / real-time per-handshake revocation design.
- Any direct PKI/Vault/OpenSSL operation on the CA host that touches trust material.

## Architecture / live facts (the deployed prod reality)
- **CA host:** `mjbl-ca-crl`, IP **10.88.1.116**, internal zone. Single source of truth — every cluster + device holds only **copies** of the public material. Access from this runner via `! ssh ca` (sudo -n, passwordless). Build-OS adaptations baked in: **Ubuntu 20.04 / Vault 2.0 / nginx 1.18** (the implementation guide targets fresh Ubuntu 24.04; the prod host runs the 20.04 variant — see the internal-ca skill gotchas G2–G6).
- **PKI:** 2-tier. Root CA (RSA-4096, 7300d, self-signed, in system trust + every device trust store) → Intermediate CA (RSA-4096, 3650d, `pathlen:0`) → 90-day leaf certs. CA dir tree `/opt/mjbl-ca/{root,intermediate}/{certs,crl,private,csr,newcerts}` + `index.txt`/`serial`/`crlnumber`. Demo/ops repo `/opt/mjbl-demo/` (`ca/`, `ansible/`, `scripts/`, `crl-serve/crl/`). Hand-off serving dir `/etc/ssl/mjbl/` (`fullchain.crt`, `service.key`, `crl-bundle.pem`).
- **Vault:** **2.0.1, Raft storage** (not dev mode in prod). Holds the Intermediate as the online signing engine (`pki/`). Sealed on every reboot — **manual `operator unseal` ×3** today (auto-unseal is a P0 gap). `vault status && vault token lookup` before any issuance.
- **Vault role separation (issuance):** `vault list pki/roles` should show exactly two —
  - **`mjbl-platform-role`** — `serverAuth` (gateway/server certs), RSA. `server_flag=true client_flag=false`.
  - **`mjbl-branch-client-role`** — `clientAuth` (branch/device certs). The live prod **branch role issues EC P-256** (`key_type=ec key_bits=256`) leaf keys, distinct from the RSA platform/server role.
- **OCSP responder:** `openssl ocsp` on **`:2560`** (delegated-signer, `OCSPSigning` EKU). Note: this responder reads `index.txt`, NOT synced with Vault revocation by default — `nuke.sh` revokes via both pathways to keep them aligned (internal-ca gotcha G10).
- **CRL HTTP server:** **`:8888`** (docroot `/opt/mjbl-demo/crl-serve/crl/`). Serves **both** `root-ca.crl` and `intermediate.crl` (a historical gap was root-ca.crl not being served — verify both).
- **`refresh-crl.sh`** (on CA host): regenerates **Root CRL** (openssl `-gencrl`) **and** pulls the **Intermediate CRL from Vault** (`curl /v1/pki/crl/pem`), rebuilds `crl-bundle.pem`, copies into both `/etc/ssl/mjbl/` (nginx `ssl_crl`) **and** the `:8888` docroot. 30-day validity, weekly refresh.
- **Gateway (consumer, not on the CA host):** DMZ mTLS gateway in the prod cluster, ns **`mjbl-mtls-gateway`**, MetalLB LB **10.88.101.142:2399** (relay enrollment plane is separate: relay LB 10.88.101.143:8443, signer `:8444` on the CA host). nginx enforces `ssl_verify_client on` + `ssl_crl /etc/ssl/mjbl/crl-bundle.pem`. Cluster pulls CRL via the **`mjbl-crl-refresh` CronJob** (Sun 03:00 UTC) → re-patches ConfigMap `mjbl-tls-trust` → rolls the gateway (≤15 min). The gateway is **firewalled off the CA host** — that's why the CRL is *pulled* and served over `:8888`.
- **Audit logs (CA host):** `/var/log/mjbl-{pki-audit,nuke-audit,enrollment,server-cert,crl-refresh}.log`.

## Key procedures (condensed — read the runbook for full steps)
**Vault status / unseal** (`hardening §P0`, rotation §0): `! ssh ca 'vault status && vault token lookup'`. If sealed → `vault operator unseal` ×3 (keys currently in `/root/vault-init.json` — P0: get them off-host). Sealed Vault = no issuance, no CRL refresh.

**CRL refresh / publish** (rotation §5): run `refresh-crl.sh` on the CA host → confirm `:8888` serves **both** root + intermediate (`curl -fsS http://localhost:8888/crl/{root-ca,intermediate}.crl | head -1`). Cluster picks it up via the CronJob; force with `kubectl -n mjbl-mtls-gateway create job --from=cronjob/mjbl-crl-refresh <name>`. **`vault READ pki/crl/rotate`** to roll Vault's CRL — it is a **READ, not a WRITE** (`vault write … pki/crl/rotate` → **405**). Verify freshness: `openssl crl -in crl-bundle.pem -noout -lastupdate -nextupdate`.

**Revoke a cert/serial on the CA host** (rotation §3/§4): `MJBL_AUTO=1 nuke.sh serial <serial>` then `refresh-crl.sh`. Full enforcement = **3 hops**: (1) vault revoke + `vault READ pki/crl/rotate`; (2) **`refresh-crl.sh` on the CA host** (easy to miss); (3) cluster CronJob (or force-job) rolls nginx. Verify the device is rejected at the TLS layer (400 / handshake fail).

**Server-cert rotation** (rotation §3, routine 90d): `vault write -format=json pki/issue/mjbl-platform-role common_name=… ip_sans=… ttl=2160h` → `jq` key + `.data.certificate,.data.ca_chain[]` into `/etc/ssl/mjbl/` → propagate per cluster (`bootstrap-secrets.sh` / `deploy-server-cert.sh`) → verify the handshake serves the new serial. **No cluster-side auto-renew yet** (propagation gap). ⚠️ This is the **gateway** cert tool — see the next entry for non-gateway services.

**Standalone (non-gateway) server-cert issuance** — for an internal service that must NOT disturb the gateway (e.g. a Rancher/admin UI on a separate, isolated cluster). Use **`scripts/issue-standalone-server-cert.sh`** (bundled in this skill; install to `/opt/mjbl-demo/scripts/` on the CA host). It is the *gateway-safe* counterpart to `issue-server-cert.sh`: it writes **only** to a chosen `--out` dir (hard-refuses `/etc/ssl/mjbl`, `/opt/mjbl-ca`, `/opt/mjbl-demo`), never propagates to the gateway, never mutates a role, and supports **`--csr`** (sign mode → the private key never leaves the target host). Steps:
1. Generate the key + CSR **on the target host** — `openssl req -new -newkey rsa:2048 -nodes -keyout svc.key -out svc.csr -subj "/CN=<fqdn>" -addext "subjectAltName=DNS:<fqdn>[,IP:<ip>]"` (keeps the key off the CA).
2. Use/create a **dedicated internal role** so the gateway's `mjbl-platform-role` is untouched — `vault write pki/roles/mjbl-internal-server-role allowed_domains="<internal-domain>" allow_subdomains=true allow_ip_sans=true server_flag=true client_flag=false key_type=rsa key_bits=2048 ttl=2160h max_ttl=2160h country=LA organization=MJBL ou="PKI Infrastructure"`.
3. Mint a **short-lived, scoped token** (policy = `create/update` on `pki/sign/mjbl-internal-server-role` + `read` on the role) into a file — never the root token; Vault must be unsealed.
4. `ssh ca 'sudo -n bash -s -- <fqdn> --role mjbl-internal-server-role --csr /tmp/svc.csr --ip <ip> --out /tmp/out --token-file /tmp/scoped.token' < scripts/issue-standalone-server-cert.sh`.
5. Pull back the **public** `fullchain.crt` (leaf+intermediate) + `ca-chain.crt` (read root-owned `--out` via `sudo cat`), install with the key on the target, and verify chain→MJBL Root + key/cert modulus match before wiring it in. *(First real use: the `drk8s.vte.mjblao.local` DR-Rancher cert, 2026-06-18.)*

**Intermediate rotation** (rotation §2, ~3–5yr): mint new int key+CSR, Root signs (`pathlen:0`, 3650d) → import to Vault (`pki/intermediate/set-signed` or new `pki_int_v2/`) → rebuild bundle **root + BOTH intermediates** → propagate → reissue server cert + trigger client renewal → keep old int CRL until last old leaf expires → retire.

**Root rotation** (rotation §1, ⚠️ heaviest, additive-trust-first): mint new root → **distribute new root to EVERY trust store FIRST** (additive: old+new) → cross-sign/sign new intermediate → switch issuance → verify → retire old only after all consumers trust new + all leafs migrated. Never retire-then-mint.

**OCSP rotation** (rotation §6): reissue delegated-signer (`OCSPSigning` EKU) before TTL → restart responder `:2560` → verify `openssl ocsp … → good`.

**Vault secret rotation** (rotation §7): rotate root token → short-lived/AppRole tokens for issuance; never bake `mjbl-root-token` into prod scripts; rotate unseal/recovery keys; re-confirm the two-role separation.

**Post-rotation gate** (rotation §8): `verify-all.sh` (18-check) + `verify-mtls.sh` (13-check) exit 0; live mTLS from a real client → `{"verified":"SUCCESS",…}`; a revoked cert rejected on every cluster; comfortable `notAfter`/`nextUpdate` headroom; audit logs show the event.

**Hardening** (hardening checklist, do P0 first): (P0) Vault unseal keys + root token off the CA host; scoped **AppRole** (issue+revoke on `pki/*`) instead of root token; **auto-unseal** (Transit/cloud-KMS); **wire Fleet** GitRepo for the gateway. (P1) Raft snapshots + `/opt/mjbl-ca` backup; NetworkPolicy; PDB; alert on CRL CronJob failure; logs→SIEM. (P2) offline Root; cert-manager+Vault issuer; in-cluster OCSP reachability.

**Gateway OCSP** (ocsp plan): `ssl_ocsp on;` (nginx ≥1.19) = per-handshake live revocation, but **hard-fail** (responder down = handshake fails = fleet-lockout class) and the DMZ gateway can't reach the CA — recommended path is an **in-cluster responder with scoped live Vault `/pki/ocsp` access** + the revocation self-test guardrail. Phased: 0 (guardrail done) → decide placement → stand up → staged enable.

## Gotchas & hard-won lessons
- **`pki/crl/rotate` is a READ, not a WRITE.** `vault write … pki/crl/rotate` → **405**. Use `vault READ pki/crl/rotate`. (Cost two CRL-propagation incidents.)
- **CRL revocation is multi-hop — `vault revoke` alone is NOT enough.** You must also run **`refresh-crl.sh` on the CA host** (hop 2, easy to forget) and let/force the cluster CronJob roll nginx (hop 3). nginx caches `ssl_crl` in memory **until reload** — a kept-alive connection isn't re-checked; a fresh handshake is needed.
- **`:8888` must serve BOTH `root-ca.crl` and `intermediate.crl`.** Root-ca.crl was once silently not served — always `curl` both.
- **Vault is sealed on every reboot** — manual unseal ×3. A CA-host reboot silently halts all issuance + CRL refresh until someone unseals. (Auto-unseal is the P0 fix.)
- **OCSP responder (`:2560`) and Vault revocation are NOT auto-synced** — the openssl responder reads `index.txt`; `vault write pki/revoke` won't update it. `nuke.sh` revokes via both pathways.
- **OVERLAP→SWITCH→RETIRE, never retire-then-mint.** A broken chain fails every mTLS handshake at the TLS layer before any HTTP response — whole branches lock out instantly. Trust anchors (root, intermediate) propagate BEFORE the leafs that chain to them.
- **Server-cert rotation has a propagation gap** — no cluster-side auto-renew; re-run `bootstrap-secrets.sh`/`deploy-server-cert.sh` per cluster.
- **Never run `issue-server-cert.sh` for a non-gateway cert.** It is built for THE gateway's multi-SAN cert: it stages straight into `/etc/ssl/mjbl/{service.key,fullchain.crt}` (the live serving cert) and expects the *full* gateway SAN list — issuing one unrelated FQDN with it overwrites the gateway cert and breaks the gateway on the next `deploy-server-cert.sh`. For any standalone internal service use **`scripts/issue-standalone-server-cert.sh`** (writes only to `--out`, never propagates, never mutates a role; `--csr` keeps the key off the CA). Pair it with a **dedicated `mjbl-internal-server-role`** so the gateway's `mjbl-platform-role` is never touched.
- **Heredoc-indent / `!`-paste hazard from this runner:** feeding scripts to the CA host via interactive `!` can indent heredoc delimiters and break them, and once caused 3 accidental cert signs. Feed scripts via `ssh ca 'sudo -n bash -s' < file`.
- **Vault 2.0 quirks** (prod host is on the 20.04/Vault-2.0 build): import via `pki/issuers/import/bundle` (not `pki/config/ca pem_bundle=`); role `default_ttl` ignored (use `ttl`); HashiCorp `focal` apt repo empty (use `jammy` codename). See the internal-ca skill G2–G6.
- **Gateway is firewalled off the CA host (DMZ↔internal).** Any "let the gateway reach the CA/OCSP/Vault directly" plan hits this wall — it's the reason for the pull-based CRL + `:8888`.
- **Self-merge of k8s-config / ArgoCD prod writes are denied to the agent.** CA-host changes go via `! ssh ca`; k8s-config merges + ArgoCD force-syncs are **user-gated**.

## Related skills
- **internal-ca** — the build-from-scratch skill (Phases 0–9) that produced this PKI; canonical configs + the G1–G12 gotcha list. Source for the original templates.
- **mtls** — the client-cert / `ssl_verify_client` follow-on (clientAuth, PKCS#12, client revocation).
- **mjbl-enrollment-plane** — the relay/signer device-enrollment path (relay 10.88.101.143:8443, signer `:8444`) — the leaf-issuance side that this CA backs.
- **mjbl-gateway-operations** — the DMZ mTLS gateway consumer (ns `mjbl-mtls-gateway`, LB 10.88.101.142:2399, CRL CronJob).
