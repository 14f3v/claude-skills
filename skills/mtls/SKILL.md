---
name: mtls
description: This skill should be used when the user asks to "add mTLS", "enable mutual TLS", "issue client certificates", "make the server require client certs", "branch/device authentication via TLS", "set up server-trusts-client", or any variant of adding mutual TLS on top of an existing internal CA + NGINX HTTPS setup. Issues client certs with `clientAuth` EKU, bundles as PKCS#12 for endpoint install, enforces `ssl_verify_client` on NGINX with a Root+Intermediate trust bundle, and wires CRL-based revocation. Designed for use after the [[internal-ca]] skill has produced a working Root + Intermediate + NGINX TLS stack.
version: 0.2.0
---

# mTLS — Server Trusts Client (Add-on to Internal CA)

You are adding **mutual TLS** to an existing one-way TLS setup. Before mTLS, the server presents a cert and the client verifies it. After mTLS, the **server also demands a client cert**, verifies it against the same internal CA chain, and exposes the client's identity to the application layer.

This skill assumes the [[internal-ca]] skill has produced a working stack: Root CA in system trust store, Intermediate CA signing service certs, NGINX serving HTTPS with fullchain, and an `openssl ca` Intermediate config available. If those prerequisites aren't met, hand back to `internal-ca` first.

---

## When to act vs ask first

**Just do it (auto-mode signals):**
- "cook it", "ship it", "end-to-end", "/effort max"
- Auto-mode reminder is active
- User supplies a guide markdown referencing phases A–E

**Ask once if missing:**
- Which endpoint(s) are getting client certs (one per device — branch+device UUID)
- PKCS#12 passphrase delivery model (random per cert? shared? demo-fixed?)
- Whether the server backend needs the client identity propagated as a header (`X-Client-DN`)

Default conventions: one cert per endpoint with CN `<role>.branch.<org>.internal` (demo) or `<branch>.<device-uuid>.<org>.internal` (closer to production), passphrase `<org>-demo` for the .p12 (demo only — see G-mtls-5 for prod).

---

## What changes vs one-way TLS

```
Before:
  Client  → trusts server via Root CA (verifies fullchain in handshake)
  Server  → has no idea who client is
  Auth    → application layer only (cookies, API keys, OAuth, etc.)

After mTLS:
  Client  → trusts server (unchanged)
  Server  → demands client cert during handshake
  Server  → verifies client chain against Root+Intermediate
  Server  → reads $ssl_client_s_dn → exposes to backend
  Auth    → cryptographic device/branch identity + app-layer user auth
```

---

## Phase map

| Phase | What it produces | Verify gate |
|---|---|---|
| A | Client cert (4096 RSA, 90d, `clientAuth` EKU, signed by Intermediate) | chain verify + `serverAuth` absent + `clientAuth` present |
| B | PKCS#12 bundle for endpoint install | `openssl pkcs12 -noout` passes with passphrase |
| C | NGINX `ssl_verify_client on` + Root+Intermediate trust bundle | no-cert → 400 / SSL reject; valid cert → 200 with CN visible |
| D | Revocation via `openssl ca -revoke` + Root+Intermediate CRL bundle + v2 reissue | revoked cert → 400 at TLS layer; v2 → 200 |
| E | `verify-mtls.sh` end-to-end + delivery summary banner | 13/13 OK |

---

## Critical gotchas — known-bad patterns

These bit us during the first cook. Always apply.

### G-mtls-1. `ssl_client_certificate` needs Root **+** Intermediate, not just Root

If you point `ssl_client_certificate` at `/etc/ssl/<org>/root-ca.crt` alone, NGINX can't build a chain for client certs signed by the Intermediate — they'll be rejected with "400 The SSL certificate error" even though the cert is valid. Build a bundle:

```bash
sudo bash -c 'awk 1 /etc/ssl/<org>/root-ca.crt \
                    /etc/ssl/<org>/intermediate-ca.crt \
              > /etc/ssl/<org>/client-ca-bundle.crt'
sudo chmod 644 /etc/ssl/<org>/client-ca-bundle.crt
# nginx config:
#   ssl_client_certificate /etc/ssl/<org>/client-ca-bundle.crt;
```

### G-mtls-2. `ssl_crl` needs CRLs for **every** CA in the chain (CRL_CHECK_ALL)

NGINX/OpenSSL sets `X509_V_FLAG_CRL_CHECK_ALL` when `ssl_crl` is present. That means the CRL file must contain a CRL for the Root CA **and** the Intermediate CA. With only an Intermediate CRL, revoked client certs are silently still accepted. Fix:

```bash
# 1. Generate an empty Root CRL (Root has no revocations yet, but the file is required)
sudo openssl ca -config /opt/<org>-demo/ca/root/openssl-root.cnf \
  -gencrl -out /opt/<org>-ca/root/crl/root-ca.crl

# 2. Build the combined bundle for NGINX
sudo bash -c 'awk 1 /opt/<org>-ca/root/crl/root-ca.crl \
                    /opt/<org>-ca/intermediate/crl/intermediate-ca.crl \
              > /etc/ssl/<org>/crl-bundle.pem'

# 3. Point nginx at the bundle
#   ssl_crl /etc/ssl/<org>/crl-bundle.pem;
```

Re-build the bundle after every `refresh-crl.sh` run. Better still, fold the bundle build into `refresh-crl.sh` itself.

### G-mtls-3. NGINX 1.18 has no `$ssl_client_s_dn_cn`

`$ssl_client_s_dn_cn` (and other per-RDN variants) were added in **NGINX 1.21.4**. Ubuntu 20.04 ships 1.18 — using it produces `nginx: [emerg] unknown "ssl_client_s_dn_cn" variable`. On 1.18, use `$ssl_client_s_dn` (full RFC 2253 DN, includes CN as substring) or use a `map` block to extract CN. Check version first:

```bash
nginx -v 2>&1
# If < 1.21.4, use $ssl_client_s_dn
```

### G-mtls-4. `openssl x509 -text` emits **long** EKU names

Verify-gate grep patterns must use the long form:

```bash
# WRONG (won't match):
openssl x509 -text | grep "clientAuth"
openssl x509 -text | grep "serverAuth"

# RIGHT:
openssl x509 -text | grep "TLS Web Client Authentication"
openssl x509 -text | grep "TLS Web Server Authentication"
```

Also flip the negative-grep idiom — the chained `grep && exit || ok` inverts. Use proper `if grep; then fail; else ok; fi`.

### G-mtls-5. Demo .p12 passphrase is NOT production storage

`mjbl-demo`-style fixed passphrases are demo-only. Real production:
- Random passphrase per enrollment, server-generated
- Delivered once over a separate channel (out-of-band from the .p12)
- For hardware-backed key storage (Android Keystore, iOS Secure Enclave): **abandon .p12 entirely** — device generates keypair on-device, submits a CSR, receives only the cert back. SCEP (RFC 8894), EST (RFC 7030), or ACME are the standard enrollment protocols.

### G-mtls-6. NGINX caches CRL — file replacement is not enough

NGINX/OpenSSL load the CRL at config-load time and cache it in memory. Dropping a new `crl-bundle.pem` on disk does NOT make NGINX re-read it. After every CRL refresh, `nginx -s reload` (or `systemctl reload nginx`). Better still: switch from CRL to `ssl_ocsp on;` (available on 1.19+) for live revocation lookups.

### G-mtls-7. Revoked cert at TLS layer = HTTP 400, not handshake abort

When NGINX rejects a revoked client cert, the connection still completes the TCP+TLS handshake but NGINX returns a synthetic `400 The SSL certificate error` page. Tests should expect `HTTP 400`, not `connection refused` or `SSL alert`. (Some configs and some NGINX versions can be tuned to alert at handshake — `ssl_verify_client on` is the lenient mode; for strict, look at `optional_no_ca` vs `on`.)

---

## OpenSSL extensions — client cert profile

Append to the Intermediate CA's `openssl-intermediate.cnf` (idempotent — only if section is missing):

```ini
[ v3_client_cert ]
basicConstraints       = CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
keyUsage               = critical, digitalSignature
extendedKeyUsage       = clientAuth
crlDistributionPoints  = URI:http://crl.<org>.internal:8888/crl/intermediate.crl
authorityInfoAccess    = OCSP;URI:http://ocsp.<org>.internal:2560
```

Per-client SAN config (`/tmp/client-<name>.cnf`):

```ini
[ req ]
default_bits       = 4096
distinguished_name = req_distinguished_name
prompt             = no

[ req_distinguished_name ]
C  = XX
O  = Org
OU = Branch Clients
CN = <client-cn>
```

Notice: **no SAN block** — client certs don't need DNS/IP SANs (the identity *is* the cert subject, not its SANs).

---

## Phase-by-phase sketch

### Phase A — Issue client cert

```bash
sudo mkdir -p /opt/<org>-ca/intermediate/certs/clients/<name>

# (paste /tmp/client-<name>.cnf and v3_client_cert section into intermediate cnf — see G-mtls templates)

sudo openssl genrsa -out /opt/<org>-ca/intermediate/certs/clients/<name>/client.key 4096
sudo chmod 400 /opt/<org>-ca/intermediate/certs/clients/<name>/client.key

sudo openssl req -new \
  -key /opt/<org>-ca/intermediate/certs/clients/<name>/client.key \
  -out /opt/<org>-ca/intermediate/certs/clients/<name>/client.csr \
  -config /tmp/client-<name>.cnf

sudo openssl ca \
  -config /opt/<org>-demo/ca/intermediate/openssl-intermediate.cnf \
  -extensions v3_client_cert \
  -extfile /tmp/client-<name>.cnf \
  -days 90 -notext -md sha256 \
  -in /opt/<org>-ca/intermediate/certs/clients/<name>/client.csr \
  -out /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt -batch

sudo openssl x509 -in /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt -noout -serial \
  | cut -d= -f2 | sudo tee /opt/<org>-ca/intermediate/certs/clients/<name>/client.serial
```

**Verify Gate A** (apply G-mtls-4):

```bash
sudo openssl verify -CAfile /opt/<org>-ca/root/certs/root-ca.crt \
  -untrusted /opt/<org>-ca/intermediate/certs/intermediate-ca.crt \
  /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt

sudo openssl x509 -in /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt -noout -text \
  | grep -q "TLS Web Client Authentication" && echo "ok clientAuth EKU"

if sudo openssl x509 -in /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt -noout -text \
     | grep -q "TLS Web Server Authentication"; then
  echo "FAIL serverAuth must NOT be present"; exit 1
else
  echo "ok serverAuth absent"
fi
```

### Phase B — PKCS#12 bundle

```bash
sudo openssl pkcs12 -export \
  -in  /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt \
  -inkey /opt/<org>-ca/intermediate/certs/clients/<name>/client.key \
  -certfile /opt/<org>-ca/intermediate/certs/intermediate-ca.crt \
  -out /opt/<org>-ca/intermediate/certs/clients/<name>/<name>-client.p12 \
  -passout pass:<passphrase> \
  -name "<Org> Branch Client — <name>"

sudo openssl pkcs12 -in /opt/<org>-ca/intermediate/certs/clients/<name>/<name>-client.p12 \
  -passin pass:<passphrase> -noout && echo "ok .p12 valid"
```

### Phase C — Enable mTLS on NGINX (apply G-mtls-1, G-mtls-3)

Build the trust bundle, then update NGINX config:

```bash
sudo bash -c 'awk 1 /etc/ssl/<org>/root-ca.crt /etc/ssl/<org>/intermediate-ca.crt \
              > /etc/ssl/<org>/client-ca-bundle.crt'
sudo chmod 644 /etc/ssl/<org>/client-ca-bundle.crt
```

Edit `/etc/nginx/sites-available/<org>-platform` — add to the `server { listen 443 ssl; }` block:

```nginx
ssl_verify_client      on;
ssl_client_certificate /etc/ssl/<org>/client-ca-bundle.crt;
ssl_verify_depth       2;
```

And in the location block, expose identity (use `$ssl_client_s_dn` on 1.18, `$ssl_client_s_dn_cn` on 1.21.4+):

```nginx
location / {
    return 200 '{"client_dn":"$ssl_client_s_dn","verified":"$ssl_client_verify"}';
    add_header Content-Type application/json;
    add_header X-Client-DN   $ssl_client_s_dn;
    add_header X-Client-Cert $ssl_client_verify;
}
```

`sudo nginx -t && sudo systemctl reload nginx`.

**Verify Gate C:**

```bash
# 1. no cert → rejected (HTTP 400)
curl -sk --cacert /etc/ssl/<org>/root-ca.crt -o /dev/null -w "%{http_code}" \
  https://<service-cn>/health   # expect 400

# 2. valid cert → accepted, identity visible
sudo curl -sk --cacert /etc/ssl/<org>/root-ca.crt \
  --cert /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt \
  --key  /opt/<org>-ca/intermediate/certs/clients/<name>/client.key \
  https://<service-cn>/health   # expect 200 with client identity

# 3. full handshake verify code 0
sudo openssl s_client -connect <service-cn>:443 \
  -CAfile /etc/ssl/<org>/root-ca.crt \
  -cert /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt \
  -key  /opt/<org>-ca/intermediate/certs/clients/<name>/client.key \
  </dev/null 2>&1 | grep "Verify return code: 0 (ok)"
```

### Phase D — Revocation + CRL bundle + v2 reissue (apply G-mtls-2, G-mtls-6)

Revoke v1:

```bash
sudo openssl ca -config /opt/<org>-demo/ca/intermediate/openssl-intermediate.cnf \
  -revoke /opt/<org>-ca/intermediate/certs/clients/<name>/client.crt -batch

sudo bash /opt/<org>-demo/scripts/refresh-crl.sh
```

Build Root CRL (one-time) and combined CRL bundle:

```bash
sudo openssl ca -config /opt/<org>-demo/ca/root/openssl-root.cnf \
  -gencrl -out /opt/<org>-ca/root/crl/root-ca.crl

sudo bash -c 'awk 1 /opt/<org>-ca/root/crl/root-ca.crl \
                    /opt/<org>-ca/intermediate/crl/intermediate-ca.crl \
              > /etc/ssl/<org>/crl-bundle.pem'
sudo chmod 644 /etc/ssl/<org>/crl-bundle.pem
```

Add to NGINX (in the same server block as `ssl_verify_client`):

```nginx
ssl_crl /etc/ssl/<org>/crl-bundle.pem;
```

`sudo nginx -t && sudo systemctl reload nginx` (G-mtls-6 — reload is required).

Confirm revoked cert is now rejected at HTTP 400 (G-mtls-7).

Reissue v2 — same flow as Phase A with new key + CSR; the openssl ca index assigns a fresh serial.

### Phase E — Verification + delivery

`verify-mtls.sh` runs 13 checks: client chain valid, clientAuth EKU present, serverAuth absent, p12 valid, no-cert rejected, valid-cert accepted, DN exposed, handshake verify=0, Intermediate in chain, revoked serial in CRL, revoked cert rejected, Root CRL exists, CRL bundle has 2 CRLs.

Banner output: filenames to SCP to the endpoint device, passphrase, expiry, and platform-specific install one-liners (`security add-trusted-cert` for macOS, `keytool` for Linux, etc.).

---

## After E — when scaling

Adding `iphone.branch.<org>.internal`, `laptop.branch.<org>.internal`, etc. = **just re-run Phase A with a different CN**. No NGINX changes, no CRL bundle rebuild needed (Intermediate CA + trust bundle already cover all clients signed by it). Each device gets its own .p12.

Revoke per device via `nuke.sh serial <client-serial>` (from the [[internal-ca]] skill — the same script handles client cert serials, no changes needed). Run `refresh-crl.sh` + rebuild the CRL bundle + reload NGINX after each revocation.

---

## Production hardening pointers (do NOT execute by default)

When the user finishes Phase E demo, surface this list as a deferred to-do — do not auto-execute:

| Demo | Production move |
|---|---|
| Fixed `mjbl-demo` passphrase | Random per-device, server-generated, out-of-band delivery |
| Shared CN across devices (`macbook.branch.<org>.internal`) | Unique CN: `<branch-code>.<device-uuid>.<org>.internal` |
| .p12 delivered to endpoint | SCEP / EST / ACME enrollment with device attestation (Android Key Attestation, iOS DeviceCheck) |
| Software-imported key in keychain | Hardware-backed: key generated **inside** Android Keystore / iOS Secure Enclave, CSR submitted, only cert returned |
| RSA 4096 client keys | EC P-256 (required for iOS Secure Enclave anyway, much lighter on mobile) |
| `ssl_crl` on file + manual reload (G-mtls-6) | `ssl_ocsp on;` (NGINX 1.19+) for live lookups; or short-lived certs (≤24h) so revocation isn't a hot path |
| `openssl ca`-managed client certs | Separate Vault PKI role: `vault write pki/roles/<org>-branch-client-role server_flag=false client_flag=true allowed_common_names_regex="^<branch-pattern>$"` |
| No CN validation | Vault role with `allowed_common_names_regex`, `enforce_hostnames`, policy OIDs |
| Manual enrollment | Custom enrollment endpoint protected by enrollment token + device attestation + rate limiting + caller-identity audit log |
| No connection-reuse consideration | Short keepalive (`keepalive_timeout 60s`) so revocation propagates faster across HTTP/2 connections |
| App ignores `$ssl_client_s_dn` | Backend reads `X-Client-DN` header, maps to internal branch ID, applies authorization on top |

---

## Memory hygiene

Before starting on a new machine, check:
- `~/.claude/projects/.../memory/project-<org>-internal-ca.md` for the existing CA's adaptation list (the G-mtls-* gotchas may already be solved there)
- `~/.claude/projects/.../memory/reference-<org>-mtls-guide.md` for the canonical mTLS guide pointer

If the user is running this on the same machine as a prior cook, the Intermediate `index.txt` already has serials in it — new client cert serials will continue from there (e.g. if last server cert was 1000, first client cert is 1001).
