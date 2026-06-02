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

## Optional Phase F — TLS-terminating gateway (proxy_pass to backend)

Once mTLS works with the synthetic `location /` from Phase C, the natural next step is to make NGINX a real **mTLS gateway**: terminate TLS + verify client cert at the edge, proxy to a plaintext HTTP backend on a trusted internal network. The backend reads the client's verified identity from headers — no token or session needed.

### F.1 Architecture

```
Client (mTLS) ──HTTPS──> NGINX ──HTTP──> Backend (10.x.y.z:80)
                          │
                          ├─ verifies client cert against Root+Intermediate
                          ├─ checks CRL bundle
                          └─ injects X-Client-* headers (cannot be spoofed)
```

The internal hop is plaintext on purpose — internal network is trusted; backend would not implement TLS for every endpoint. Identity propagation via headers means the backend trusts what NGINX vouches for, **provided** the backend is not directly reachable from outside.

### F.2 NGINX config template

Replace the synthetic `location /` from Phase C with:

```nginx
upstream <org>_backend {
    server <backend-ip>:80;
    keepalive 16;
}

server {
    listen 443 ssl;
    server_name <service-cn> <service-ip>;

    # Server cert + mTLS (unchanged from Phase C)
    ssl_certificate     /etc/ssl/<org>/fullchain.crt;
    ssl_certificate_key /etc/ssl/<org>/service.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_verify_client      on;
    ssl_client_certificate /etc/ssl/<org>/client-ca-bundle.crt;
    ssl_verify_depth       2;
    ssl_crl                /etc/ssl/<org>/crl-bundle.pem;
    ssl_stapling           on;
    ssl_stapling_verify    on;
    ssl_trusted_certificate /etc/ssl/<org>/root-ca.crt;

    # Local liveness — does NOT hit backend (monitoring probe)
    location = /health {
        return 200 '{"healthy":true,"role":"mtls-gateway","client":"$ssl_client_s_dn"}';
        add_header Content-Type application/json;
    }

    # Identity echo — useful for debugging mTLS without backend dependency
    location = /_local/identity {
        return 200 '{"verified":"$ssl_client_verify","dn":"$ssl_client_s_dn","serial":"$ssl_client_serial","fingerprint":"$ssl_client_fingerprint"}';
        add_header Content-Type application/json;
    }

    # Everything else -> backend
    location / {
        proxy_pass http://<org>_backend;
        proxy_http_version 1.1;

        # Standard proxy hygiene
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;

        # mTLS-derived identity — overrides anything client tried to send
        proxy_set_header X-Client-Verify      $ssl_client_verify;
        proxy_set_header X-Client-DN          $ssl_client_s_dn;
        proxy_set_header X-Client-Serial      $ssl_client_serial;
        proxy_set_header X-Client-Fingerprint $ssl_client_fingerprint;
        proxy_set_header X-Client-Not-After   $ssl_client_v_end;

        # Keepalive to upstream
        proxy_set_header Connection "";

        # Timeouts
        proxy_connect_timeout 5s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;

        # Buffer sizes (raise for SPA bundles like Flutter web — 9 MB main.dart.js etc.)
        proxy_buffers         16 16k;
        proxy_buffer_size     16k;
    }
}
```

### F.3 Verification

Adapt the Phase C verify script — the synthetic `/` is gone, so the "client identity visible" check moves to `/_local/identity`:

```bash
# Local liveness (no backend dependency)
curl -sk --cacert <root> --cert <client> --key <client-key> \
  https://<service-cn>/health
# expect: {"healthy":true,...,"client":"CN=..."}

# Identity echo (use this in verify-mtls.sh instead of grepping "/")
curl -sk --cacert <root> --cert <client> --key <client-key> \
  https://<service-cn>/_local/identity
# expect: {"verified":"SUCCESS","dn":"CN=...","serial":"...","fingerprint":"..."}

# Proxied path (hits backend)
curl -sk --cacert <root> --cert <client> --key <client-key> \
  https://<service-cn>/
# expect: backend's actual response (HTML, JSON, etc.)

# Negative case unchanged: no cert → HTTP 400; revoked cert → HTTP 400
```

If you migrated from Phase C synthetic JSON, your existing `verify-mtls.sh` "Client DN exposed" check will fail because it greps for `"client_dn"` in `/` response. Patch it to hit `/_local/identity` and grep `verified.*SUCCESS`.

### F.4 Security caveats — must apply in production

| Concern | Demo OK | Production must |
|---|---|---|
| Backend reachability | Backend on shared LAN — anyone on the LAN can hit it directly, bypassing mTLS | Backend listens **only** on its private interface (`bind 10.x.y.z:80`) or behind firewall rules that only allow the NGINX IP. mTLS at the gateway is bypassable if backend has any other open port. |
| Header spoofing | `proxy_set_header X-Client-* $ssl_client_*` overrides client values — safe **if** every external request goes through this NGINX | If backend has any other ingress (LB, sidecar), each ingress must overwrite/strip `X-Client-*` identically. Otherwise: backend reads `X-Client-DN` from a request that bypassed NGINX. |
| Plaintext internal hop | HTTP between NGINX and backend | If internal network is untrusted (multi-tenant cloud, shared VPC), use HTTPS upstream with `proxy_pass https://...` + `proxy_ssl_*` directives. Or service mesh (mTLS sidecar-to-sidecar). |
| Identity normalisation | `$ssl_client_s_dn` is the full RFC 2253 DN — backend has to parse it | Extract CN cleanly via a `map` block: `map $ssl_client_s_dn $client_cn { default ""; "~CN=(?<cn>[^,]+)" $cn; }` then `proxy_set_header X-Client-CN $client_cn;`. (On NGINX 1.21.4+, `$ssl_client_s_dn_cn` is built-in.) |
| Connection limits / DoS | None | `limit_req_zone`, `limit_conn_zone`, `client_max_body_size` per location. |
| Audit log | Default `combined` format doesn't include client identity | Custom `log_format mtls '$remote_addr - $ssl_client_s_dn - $request - $status'` + dedicated `access_log` for the mTLS gateway. |

### F.5 Extract a clean `X-Client-CN` via `map` (NGINX < 1.21.4)

On NGINX 1.21.4+, you can use `$ssl_client_s_dn_cn` directly. On older NGINX (e.g. 1.18 on Ubuntu 20.04 — see G-mtls-3), the full DN is the only thing you get. To hand the backend a clean CN-only header, use a `map` block.

**Maps must live at `http` context** — not inside `server`. The cleanest place is a small file under `/etc/nginx/conf.d/`, which Ubuntu's default `nginx.conf` includes from the `http` block. Don't put it in `sites-available/` (which is included inside the `server` context).

`/etc/nginx/conf.d/<org>-maps.conf`:

```nginx
# Extract individual RDNs from $ssl_client_s_dn (RFC 2253 form).
# Required on NGINX < 1.21.4 which has no built-in $ssl_client_s_dn_<rdn> vars.
# Example subject: CN=macbook.branch.<org>.internal,OU=Branch Clients,O=Org,C=XX

map $ssl_client_s_dn $client_cn {
    default                  "";
    "~CN=(?<cn>[^,]+)"       $cn;
}

# Repeat for other RDNs if backend needs them:
# map $ssl_client_s_dn $client_ou { default ""; "~OU=(?<ou>[^,]+)" $ou; }
# map $ssl_client_s_dn $client_o  { default ""; "~O=(?<o>[^,]+)"   $o;  }
```

Then in your gateway site (Phase F.2), add the proxy header right next to `X-Client-DN`:

```nginx
proxy_set_header X-Client-DN  $ssl_client_s_dn;
proxy_set_header X-Client-CN  $client_cn;         # ← clean, just the CN
```

And include `$client_cn` in the local identity echo so you can verify the extraction without touching the backend:

```nginx
location = /_local/identity {
    return 200 '{"verified":"$ssl_client_verify","cn":"$client_cn","dn":"$ssl_client_s_dn","serial":"$ssl_client_serial","fingerprint":"$ssl_client_fingerprint"}';
    add_header Content-Type application/json;
}
```

`nginx -t && systemctl reload nginx`. Then:

```bash
curl -sk --cacert <root> --cert <client> --key <key> \
  https://<service-cn>/_local/identity
# expect: "cn":"<extracted-cn-only>", "dn":"<full-DN>"
```

### F.6 Gateway access logging (mTLS audit trail)

Default NGINX `combined` log format omits client cert info — useless for an mTLS audit trail. Set up a dedicated log format that captures **who** (client CN, serial), **what** (request + status), **how fast** (request + upstream time), and **how** (TLS version + cipher) per request.

Add to `/etc/nginx/conf.d/<org>-maps.conf` (same file as the CN map — both must be at `http` context):

```nginx
log_format mtls_audit '$remote_addr - "$client_cn" [$time_local] '
                      '"$request" $status $body_bytes_sent '
                      'rt=$request_time urt=$upstream_response_time '
                      'serial=$ssl_client_serial verify=$ssl_client_verify '
                      'tls=$ssl_protocol/$ssl_cipher '
                      'ua="$http_user_agent"';
```

In the `server { listen 443 ssl; }` block (Phase F.2), add right after `server_name`:

```nginx
access_log /var/log/nginx/<org>-access.log mtls_audit;
error_log  /var/log/nginx/<org>-error.log warn;
```

And inside `location = /health` add `access_log off;` — health probes are chatty and low-value, they pollute the audit trail. Identity-echo (`/_local/identity`) and proxied paths should stay logged.

#### Sample output

```
127.0.0.1 - "macbook.branch.mjbl.internal" [21/May/2026:10:27:48 +0000] "GET / HTTP/1.1" 200 5631 rt=0.002 urt=0.000 serial=1002 verify=SUCCESS tls=TLSv1.3/TLS_AES_256_GCM_SHA384 ua="MJBL-Demo-Client/1.0"
127.0.0.1 - ""                              [21/May/2026:10:27:48 +0000] "GET / HTTP/1.1" 400 246  rt=0.000 urt=-     serial=-    verify=NONE                  tls=TLSv1.3/...  ua="anonymous-attacker"
127.0.0.1 - "macbook.branch.mjbl.internal" [21/May/2026:10:27:48 +0000] "GET / HTTP/1.1" 400 224  rt=0.000 urt=-     serial=1001 verify=FAILED:certificate revoked tls=TLSv1.3/... ua="revoked-client-v1"
```

Every rejection has its own line with the failure reason in the `verify=` field — easy to detect compromised-cert use, expired certs, or unauthorized clients hitting the door.

#### Useful monitoring queries

```bash
# Live tail
tail -F /var/log/nginx/<org>-access.log

# Count by verify status (look for spikes of FAILED or NONE)
awk '{for(i=1;i<=NF;i++) if($i ~ /^verify=/) print $i}' \
  /var/log/nginx/<org>-access.log | sort | uniq -c

# Unique client CNs that authenticated successfully
grep 'verify=SUCCESS' /var/log/nginx/<org>-access.log \
  | awk -F'"' '{print $2}' | sort -u

# All rejected attempts (revoked, no-cert, expired)
grep -E 'verify=(NONE|FAILED)' /var/log/nginx/<org>-access.log

# Slowest requests (top N by total time)
grep -oE 'rt=[0-9.]+' /var/log/nginx/<org>-access.log \
  | sort -t= -k2 -rn | head -10

# Requests by a specific client CN
grep '"branch-001.<device>.<org>.internal"' /var/log/nginx/<org>-access.log

# Per-hour request count (basic activity heatmap)
awk '{split($4, a, ":"); print a[2]":"a[3]}' /var/log/nginx/<org>-access.log \
  | sort | uniq -c
```

#### JSON variant for SIEM ingestion

The text format is great for `tail` + `grep` + `awk`. For SIEM (ELK, Loki, Splunk, Datadog), use a parallel JSON-formatted log:

```nginx
log_format mtls_audit_json escape=json
  '{'
    '"time":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"client_cn":"$client_cn",'
    '"client_dn":"$ssl_client_s_dn",'
    '"client_serial":"$ssl_client_serial",'
    '"verify":"$ssl_client_verify",'
    '"request":"$request",'
    '"status":$status,'
    '"body_bytes":$body_bytes_sent,'
    '"request_time":$request_time,'
    '"upstream_time":"$upstream_response_time",'
    '"upstream_addr":"$upstream_addr",'
    '"tls_protocol":"$ssl_protocol",'
    '"tls_cipher":"$ssl_cipher",'
    '"user_agent":"$http_user_agent"'
  '}';
```

Either replace `mtls_audit` with `mtls_audit_json`, or write both in parallel:

```nginx
access_log /var/log/nginx/<org>-access.log      mtls_audit;
access_log /var/log/nginx/<org>-access.json.log mtls_audit_json;
```

#### Logrotate

Audit logs need long-enough retention that you can investigate yesterday's anomaly. Default `nginx` logrotate gives 14 days — too short for security forensics. Write a dedicated config so audit logs survive longer than ordinary nginx logs:

`/etc/logrotate.d/<org>-nginx`:

```
/var/log/nginx/<org>-access.log
/var/log/nginx/<org>-error.log
{
    daily
    rotate 30                          # 30 days demo; 365+ for prod compliance
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid)
    endscript
}
```

Test with `sudo logrotate -d /etc/logrotate.d/<org>-nginx` (dry run, no rotation actually happens).

#### Production considerations

| Concern | Demo OK | Production must |
|---|---|---|
| Local-only storage | Fine for demo | **Ship logs off-host** — local disk is the wrong place for the only copy of an audit trail. Use `syslog:server=<host>` in `access_log` directive, or run a Vector/Promtail/Fluentbit sidecar to ship to SIEM. |
| Retention | 30 days | Often **≥ 1 year** for compliance (PCI-DSS, ISO 27001, SOC 2). Local logrotate is not the right answer — write to immutable storage (S3 with Object Lock, dedicated SIEM). |
| PII in logs | User-Agent is harmless | If the application embeds PII in URLs (`/users/<email>?token=...`), the access log captures it. Use `set $loggable_uri $request;` + a `map` to strip sensitive query params before logging. |
| Log injection | None in this demo | A malicious `User-Agent` or CN containing `\n` could inject a fake log line. NGINX's `escape=default` (the default) escapes characters, but verify if you change the format. |
| Disk full = no writes | Could happen on long demos | Monitor `/var/log/nginx/` free space; alert at 80%. NGINX will return 500 if it can't write logs and `access_log` doesn't have `if=` to make it optional. |
| Health probe noise | Already handled (`access_log off` on `/health`) | Same for any other liveness/readiness path your LB hits. |

### F.7 Backend trust contract

Document this clearly for backend developers — they need to know which headers are trustworthy:

```
TRUSTED headers (set by mTLS gateway, cannot be spoofed by external client):
  X-Client-Verify       'SUCCESS' if mTLS handshake passed
  X-Client-DN           full RFC 2253 subject DN
  X-Client-Serial       cert serial (hex string) - use as device identifier
  X-Client-Fingerprint  SHA1 fingerprint of presented cert
  X-Client-Not-After    cert expiry timestamp

Backend MUST reject the request if X-Client-Verify != "SUCCESS".
Use X-Client-Serial or X-Client-Fingerprint as the device identifier in
audit logs — survives CN changes, unique per cert.

Do NOT trust any other X-Client-* header (not set by gateway, may be client-supplied).
```

---

## After E — when scaling

Adding `iphone.branch.<org>.internal`, `laptop.branch.<org>.internal`, etc. = **just re-run Phase A with a different CN**. No NGINX changes, no CRL bundle rebuild needed (Intermediate CA + trust bundle already cover all clients signed by it). Each device gets its own .p12.

Revoke per device via `nuke.sh serial <client-serial>` (from the [[internal-ca]] skill — the same script handles client cert serials, no changes needed). Run `refresh-crl.sh` + rebuild the CRL bundle + reload NGINX after each revocation.

---

## Phase G — Domain-classified client certs (Approach A)

When the deployment grows beyond "one OU for everyone" and you need to mark which **business domain** each client belongs to (Agency / Microloan / Payment / Branch / Ops / Support / etc.), extend with **Approach A: OU-based classification on the existing single Intermediate CA**.

**What it gets you:** the subject DN of each client cert carries `OU=<Domain>`, exposed in `$ssl_client_s_dn` at the gateway. The gateway can extract it via a `map` and either pass it as `X-Client-Domain` for backend-layer authorization or apply per-location allow-lists at the edge.

**What it does NOT change:**
- The CA hierarchy stays Root → single Intermediate (no new keys, no new CRLs)
- Trust bundle (`client-ca-bundle.crt`) stays the same
- CRL bundle and CRL distribution stay the same — all clients across all domains share the same Intermediate CRL
- In-cluster CRL refresh CronJob: zero change. Same Service `crl-upstream`, same script, same `grep -c 'BEGIN X509 CRL' == 2` invariant.

**Forward-compatible with Approach D** (sub-Intermediate per domain): when one domain eventually needs cryptographic isolation (typically `Payment` under banking regulator scrutiny), spin up a parallel sub-Intermediate, concatenate it into the trust bundle, add its CRL to the CRL bundle. Other domains keep using the shared Intermediate; no migration of existing certs.

### Layout on the bare-metal CA VM

```
/opt/<org>/ca/domains.allowlist                ← whitelist of legal OU values
                                                 (one per line; case-insensitive lookup; comments OK)

/opt/<org>/ca/intermediate/certs/clients/
├── _registry.tsv                              ← append-only TSV: timestamp/domain/device/serial/issued_by/status
└── <domain-lower>/                            ← per-domain dir
    ├── <device-id>-<serial>.key               ← mode 0400
    ├── <device-id>-<serial>.csr
    ├── <device-id>-<serial>.crt
    ├── <device-id>-<serial>.p12               ← mode 0600, ship to device
    ├── <device-id>-<serial>.meta              ← issuance details
    └── <device-id>.current                    ← text file with the active serial

/opt/<org>/scripts/
├── issue-client-cert.sh                       ← <device-id> <domain> [--validity-days N]
└── revoke-client-cert.sh                      ← <device-id> <domain> [--serial N]
```

### Issue script — what it does internally

1. Validates device-id format (`^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$` — DNS-label-safe)
2. Looks up domain in `/opt/<org>/ca/domains.allowlist` (case-insensitive → canonical case)
3. Reads next serial from `/opt/<org>/ca/intermediate/serial`
4. Generates 4096-bit RSA key
5. CSR with subject: `/C=XX/O=<Org>/OU=<Domain>/CN=<device-id>.<domain-lower>.<org>.internal`
6. Signs via `openssl ca -extensions v3_client_cert` — uses the existing extension section in `openssl-intermediate.cnf` (clientAuth EKU + CRL DP + OCSP AIA — **no new extension section needed**)
7. Builds PKCS#12 bundle (key + leaf + intermediate)
8. Writes serial-suffixed artifacts + updates `.current` marker + appends to `_registry.tsv`

Re-issuance for an existing device-id is allowed: new serial, old serial stays valid until explicitly revoked (rolling-rotation overlap window).

### Gateway-side OU extraction (optional but recommended)

Add to the http-context configmap (`mjbl-maps.conf` in K8s or `conf.d/<org>-maps.conf` on bare-metal):

```nginx
map $ssl_client_s_dn $client_domain {
    default                "";
    "~OU=(?<ou>[^,]+)"     $ou;
}
```

In the server block, propagate or enforce:

```nginx
# Forward the domain to backend (TLS-layer-verified, trustable):
proxy_set_header X-Client-Domain $client_domain;

# Or enforce at the gateway:
location /api/microloan/ {
    if ($client_domain != "Microloan") { return 403; }
    proxy_pass http://microloan_backend;
}
```

### Registry audit

```
$ sudo column -t -s $'\t' /opt/<org>/ca/intermediate/certs/clients/_registry.tsv
timestamp             domain     device_id    serial  issued_by  status
2026-06-02T10:52:59Z  Microloan  test-001     1004    mjbl       active
2026-06-02T11:30:14Z  Payment    teller-jdoe  1005    mjbl       active
2026-06-08T14:22:01Z  Microloan  test-001     1004    mjbl       revoked-20260608
```

### G-mtls-8 — OU is a label, not a boundary

The OU field is just text signed by the CA. Anyone with the Intermediate CA's signing key could mint a cert with any OU. This is fine for OU as **classification metadata for routing/audit**, but DO NOT use OU alone as the cryptographic boundary for high-stakes authorization (money movement, key release). For that, move the relevant domain to a sub-Intermediate (Approach D) so the chain itself proves the classification.

### Trigger phrases for this phase

User says: "domain-classified", "OU-based client certs", "per-business-domain certs", "Agency / Microloan / Payment client cert", "add a new business domain", "issue client cert for X domain" → this phase.

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
