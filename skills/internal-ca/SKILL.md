---
name: internal-ca
description: This skill should be used when the user asks to "set up an internal CA", "bootstrap a Certificate Authority", "build a 2-tier PKI", "create an internal Root CA and Intermediate CA", "set up Vault PKI", or any variant of standing up internal X.509 certificate infrastructure on a Linux host. Builds a Root + Intermediate + service-cert pipeline with HashiCorp Vault PKI, OCSP responder, CRL HTTP server, Ansible deploy automation, and a 3-mode revocation ("nuke") script. Designed for demo/lab use with explicit production-hardening pointers.
version: 0.2.0
---

# Internal CA — 2-tier PKI Bootstrap

You are setting up an internal Certificate Authority on a Linux host (default-tested: Ubuntu 20.04/24.04). The output is a working PKI that issues 90-day service certs from an Intermediate CA, signed by a 20-year Root CA in the host's trust store, with revocation, audit, and Ansible-driven deployment.

This skill is the entry point. If the user wants to **add mutual TLS** on top (server-trusts-client), hand off to the [[mtls]] skill after Phase 9.

---

## When to act vs ask first

**Just do it (auto-mode signals):**
- The user says "cook it", "ship it", "run end-to-end", "let's start", "/effort max"
- An explicit auto-mode reminder is active in the conversation
- The user supplied a guide markdown file and references it

**Ask one batched question first (when ambiguous):**
- Target host details unclear (OS, role, sudo)
- Organization fields (`C=`, `O=`, `OU=`) — these go into every cert
- Service common name + IP/DNS for the first cert
- Whether Vault is already running or this skill should start it

Default values if user doesn't specify: `C=XX O=Org OU="PKI Infrastructure"`, Root CN `Org Root CA`, Intermediate CN `Org Intermediate CA`, service CN matches host.

---

## Phase map

| Phase | What it produces | Verify gate |
|---|---|---|
| 0 | Passwordless sudo (optional), packages installed (openssl, nginx, jq, ansible-via-pip3, vault, softhsm2) | `which openssl nginx jq vault ansible-playbook` |
| 1 | Root CA: 4096 RSA, 7300 days, self-signed, in `/usr/local/share/ca-certificates/` system trust store | `openssl verify -CAfile root.crt root.crt` + chain visible to `curl --cacert` |
| 2 | Intermediate CA: 4096 RSA, 3650 days, `pathlen:0`, signed by Root, full chain verifies | `openssl verify -CAfile root -untrusted intermediate.crt intermediate.crt` |
| 3 | First service cert: 90 days, DNS+IP SANs, `serverAuth` EKU | chain verify + cert subject = expected CN |
| 4 | NGINX TLS at `https://<cn>` with fullchain + OCSP stapling | `curl https://<cn>` returns 200; cert in handshake matches |
| 5 | Vault PKI engine mounted, intermediate bundle imported, role created | `vault write pki/issue/<role> common_name=...` returns cert |
| 6 | Ansible playbook that issues from Vault and reloads NGINX | dry-run playbook + visible new serial |
| 7 | OCSP responder on `:2560`, CRL HTTP server on `:8888` | `openssl ocsp -url ...` returns `good`; `curl :8888/crl/...` returns CRL bytes |
| 8 | `nuke.sh` 3-mode revocation script: `serial`, `service`, `all` | dry-run of each mode + audit log entries |
| 9 | `verify-all.sh` 18-check smoke test | exit 0, all OK |

After Phase 9, the demo is fully functional. Hand off to the **mtls** skill if the user wants to add client cert authentication.

---

## Filesystem convention

Use this layout unless the user explicitly asks for different paths. It's what the existing audit/scripts/Ansible vars assume.

```
/opt/<org>-ca/
├── root/{certs,crl,csr,newcerts,private}/   index.txt  serial  crlnumber
└── intermediate/{certs,crl,csr,newcerts,private}/   index.txt  serial  crlnumber

/opt/<org>-demo/
├── ca/{root,intermediate}/   openssl-*.cnf
├── ansible/{inventory,playbooks,vars}/
└── scripts/   nuke.sh  refresh-crl.sh  verify-all.sh

/etc/ssl/<org>/   fullchain.crt  service.key  intermediate-ca.crt  root-ca.crt
/usr/local/share/ca-certificates/<org>-root-ca.crt   (system trust anchor)

/var/log/<org>-pki-audit.log     ← append-only, lineinfile-driven
/var/log/<org>-nuke-audit.log    ← append-only, written by nuke.sh
```

`<org>` is a lowercase short tag (e.g. `mjbl`). Substitute consistently — these paths are referenced from Ansible vars, NGINX config, OCSP responder, and the verify script.

---

## OpenSSL configs — canonical templates

### Root CA — `openssl-root.cnf`

```
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /opt/<org>-ca/root
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
RANDFILE          = $dir/private/.rand
private_key       = $dir/private/root-ca.key
certificate       = $dir/certs/root-ca.crt
crlnumber         = $dir/crlnumber
crl               = $dir/crl/root-ca.crl
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 3650
preserve          = no
policy            = policy_strict

[ policy_strict ]
countryName             = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied

[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_ca
prompt              = no

[ req_distinguished_name ]
C  = XX
O  = Org
OU = PKI Infrastructure
CN = Org Root CA

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign

[ crl_ext ]
authorityKeyIdentifier = keyid:always
```

### Intermediate CA — `openssl-intermediate.cnf`

Same `[ca]`/`[CA_default]` block pointed at `/opt/<org>-ca/intermediate/`, plus:

```
[ v3_service_cert ]
basicConstraints       = CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
crlDistributionPoints  = URI:http://crl.<org>.internal:8888/crl/intermediate.crl
authorityInfoAccess    = OCSP;URI:http://ocsp.<org>.internal:2560
```

### Per-service SAN config (`/tmp/<svc>-san.cnf`)

```
[ req ]
default_bits       = 2048
prompt             = no
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = XX
O  = Org
CN = <service-cn>

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = <service-cn>
IP.1  = <service-ip>
```

---

## Critical gotchas — known-bad patterns to avoid

These bit us during the first cook. Always apply.

### G1. Verify gate "issuer == subject" comparison must strip prefixes

`openssl x509 -noout -issuer` emits `issuer=C = XX, O = Org, CN = ...`. `-subject` emits `subject=...`. A naive `[ "$ISSUER" = "$SUBJECT" ]` always fails. Strip:

```bash
ISSUER=$(openssl x509 -in root.crt -noout -issuer | sed 's/^issuer=//')
SUBJECT=$(openssl x509 -in root.crt -noout -subject | sed 's/^subject=//')
[ "$ISSUER" = "$SUBJECT" ] && echo "ok self-signed"
```

### G2. Vault 2.0 dropped `pki/config/ca pem_bundle=`

Use the modern endpoint:

```bash
BUNDLE=$(cat intermediate-ca.crt intermediate.key)
vault write pki/issuers/import/bundle pem_bundle="${BUNDLE}"
```

### G3. Vault 2.0 removed `pki/crl/rotate`

Returns 405. CRLs auto-rotate now. Swallow in scripts:

```bash
vault write -force pki/crl/rotate >/dev/null 2>&1 || true
```

### G4. Vault 2.0 role config ignores `default_ttl`

Only `ttl` is honored. Role creation warns but still works. Drop `default_ttl=` from `vault write pki/roles/<name>` calls.

### G5. HashiCorp apt repo for `focal` (Ubuntu 20.04) is empty

`Packages` file has zero length. Swap to the `jammy` codename — Go-statically-linked binaries are portable across glibc versions:

```bash
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
```

### G6. Ubuntu 20.04 apt `ansible` is 2.9 — can't load `community.*` collections

Install via pip3 instead. On focal, `pip3` doesn't enforce PEP 668, so no `--break-system-packages` flag:

```bash
sudo pip3 install ansible
# Binary lands at /usr/local/bin/ansible-playbook
```

### G7. Ansible playbook PEM concat must preserve newlines

Vault's JSON cert response has no trailing `\n`. Naive `cat service.crt intermediate-ca.crt > fullchain` produces `END CERTIFICATE----------BEGIN CERTIFICATE-----` glued together (breaks PEM parsing). Use `awk 1` (which adds newlines) and append `\n` in the copy step:

```yaml
- name: Write certificate
  copy:
    content: "{{ vault_response.json.data.certificate }}\n"
    dest: "{{ cert_dest_dir }}/service.crt"

- name: Build fullchain
  shell: |
    awk 1 {{ cert_dest_dir }}/service.crt {{ cert_dest_dir }}/intermediate-ca.crt \
      > {{ cert_dest_dir }}/fullchain.crt
```

### G8. `ansible-playbook -q` doesn't exist on ansible-core 2.13+

Use `-v` (or omit). The old short `-q` flag was removed.

### G9. Daemon launching under Claude Code's Bash sandbox

`setsid nohup vault server -dev … &` returns exit 144 with no output. `systemd-run` same. Use Claude Code's native `run_in_background: true` parameter on the Bash tool call instead. For real production, write a `systemd` unit (`mjbl-vault-dev.service`) and `systemctl enable --now` it.

### G10. OCSP responder vs Vault revocation are NOT synced

The OCSP responder we run is `openssl ocsp` reading `/opt/<org>-ca/intermediate/index.txt`. A `vault write pki/revoke` updates Vault's *internal* CRL but does NOT touch `index.txt` — so the openssl OCSP responder will keep reporting `good` for a Vault-revoked serial. Production fix: use Vault's built-in OCSP (`pki/ocsp`) or build a syncer that mirrors `vault read pki/cert/<serial>` revocation state into `index.txt`. The `nuke.sh` script revokes via both pathways simultaneously to keep them aligned.

### G11. Passwordless sudo bootstrap

If the user runs Claude Code without TTY, `sudo` prompts fail. Bootstrap once via:

```
# User runs this themselves (TTY-bound prompt):
echo "<user> ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/90-<user>-nopasswd
sudo visudo -c -f /etc/sudoers.d/90-<user>-nopasswd
```

Then all subsequent Bash tool calls work without prompting.

### G12. Country code is ISO 3166-1 alpha-2

Two letters. **Not** a US state code, **not** spelled out. If the user's org is in Laos, that's `LA`. Hong Kong is `HK`. UK is `GB`. Don't autocorrect a 2-letter code you don't recognize — it's almost certainly correct.

---

## Phase-by-phase execution sketch

The phases below are the canonical sequence. Each block embeds a verify gate; don't move to the next phase until the previous gate passes. Use `set -e` in shell blocks.

### Phase 0 — Host bootstrap

```bash
# (after sudoers bootstrap per G11)
sudo apt update
sudo apt install -y openssl nginx jq curl python3 softhsm2
# HashiCorp repo: see G5 (use jammy on focal)
sudo apt install -y vault
# Ansible via pip3 (see G6)
sudo pip3 install ansible

# Create directory skeleton
sudo mkdir -p /opt/<org>-ca/{root,intermediate}/{certs,crl,csr,newcerts,private}
sudo mkdir -p /opt/<org>-demo/{ca/{root,intermediate},ansible/{inventory,playbooks,vars},scripts}
sudo chmod 700 /opt/<org>-ca/{root,intermediate}/private
for tier in root intermediate; do
  sudo touch /opt/<org>-ca/$tier/index.txt
  echo 1000 | sudo tee /opt/<org>-ca/$tier/serial /opt/<org>-ca/$tier/crlnumber
done
```

### Phase 1 — Root CA

Write `/opt/<org>-demo/ca/root/openssl-root.cnf` (template above), then:

```bash
sudo openssl genrsa -out /opt/<org>-ca/root/private/root-ca.key 4096
sudo chmod 400 /opt/<org>-ca/root/private/root-ca.key

sudo openssl req -config /opt/<org>-demo/ca/root/openssl-root.cnf \
  -key /opt/<org>-ca/root/private/root-ca.key \
  -new -x509 -days 7300 -sha256 -extensions v3_ca \
  -out /opt/<org>-ca/root/certs/root-ca.crt

# Install in system trust store
sudo cp /opt/<org>-ca/root/certs/root-ca.crt /usr/local/share/ca-certificates/<org>-root-ca.crt
sudo update-ca-certificates
```

**Verify Gate 1** (apply G1):

```bash
SUBJECT=$(sudo openssl x509 -in /opt/<org>-ca/root/certs/root-ca.crt -noout -subject | sed 's/^subject=//')
ISSUER=$(sudo openssl x509 -in /opt/<org>-ca/root/certs/root-ca.crt -noout -issuer | sed 's/^issuer=//')
[ "$SUBJECT" = "$ISSUER" ] && echo "ok self-signed Root CA"
```

### Phase 2 — Intermediate CA

```bash
sudo openssl genrsa -out /opt/<org>-ca/intermediate/private/intermediate-ca.key 4096
sudo chmod 400 /opt/<org>-ca/intermediate/private/intermediate-ca.key

sudo openssl req -config /opt/<org>-demo/ca/intermediate/openssl-intermediate.cnf \
  -new -sha256 \
  -key /opt/<org>-ca/intermediate/private/intermediate-ca.key \
  -out /opt/<org>-ca/intermediate/csr/intermediate-ca.csr

sudo openssl ca -config /opt/<org>-demo/ca/root/openssl-root.cnf \
  -extensions v3_intermediate_ca -days 3650 -notext -md sha256 \
  -in /opt/<org>-ca/intermediate/csr/intermediate-ca.csr \
  -out /opt/<org>-ca/intermediate/certs/intermediate-ca.crt -batch
```

**Verify Gate 2:**

```bash
sudo openssl verify \
  -CAfile /opt/<org>-ca/root/certs/root-ca.crt \
  /opt/<org>-ca/intermediate/certs/intermediate-ca.crt
```

### Phase 3 — First service cert

Write `/tmp/<svc>-san.cnf` (template above with substituted CN+IP), then:

```bash
sudo mkdir -p /opt/<org>-ca/intermediate/certs/<svc>
sudo openssl genrsa -out /opt/<org>-ca/intermediate/certs/<svc>/service.key 2048

sudo openssl req -new -sha256 -key /opt/<org>-ca/intermediate/certs/<svc>/service.key \
  -out /opt/<org>-ca/intermediate/certs/<svc>/service.csr \
  -config /tmp/<svc>-san.cnf

sudo openssl ca -config /opt/<org>-demo/ca/intermediate/openssl-intermediate.cnf \
  -extensions v3_service_cert -days 90 -notext -md sha256 \
  -extfile /tmp/<svc>-san.cnf -extensions req_ext \
  -in /opt/<org>-ca/intermediate/certs/<svc>/service.csr \
  -out /opt/<org>-ca/intermediate/certs/<svc>/service.crt -batch
```

### Phase 4 — NGINX TLS + OCSP stapling

```bash
sudo mkdir -p /etc/ssl/<org>
sudo bash -c 'awk 1 /opt/<org>-ca/intermediate/certs/<svc>/service.crt \
  /opt/<org>-ca/intermediate/certs/intermediate-ca.crt > /etc/ssl/<org>/fullchain.crt'
sudo cp /opt/<org>-ca/intermediate/certs/<svc>/service.key /etc/ssl/<org>/service.key
sudo cp /opt/<org>-ca/intermediate/certs/intermediate-ca.crt /etc/ssl/<org>/intermediate-ca.crt
sudo cp /opt/<org>-ca/root/certs/root-ca.crt /etc/ssl/<org>/root-ca.crt
sudo chmod 600 /etc/ssl/<org>/service.key
```

NGINX `sites-available/<org>-platform`:

```nginx
server {
    listen 443 ssl;
    server_name <service-cn> <service-ip>;
    ssl_certificate     /etc/ssl/<org>/fullchain.crt;
    ssl_certificate_key /etc/ssl/<org>/service.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_stapling           on;
    ssl_stapling_verify    on;
    ssl_trusted_certificate /etc/ssl/<org>/root-ca.crt;

    location / { return 200 '{"service":"<service-cn>","ok":true}'; add_header Content-Type application/json; }
}
```

### Phase 5 — Vault PKI (apply G2, G3, G4)

```bash
# Vault dev mode launched via run_in_background: true (see G9)
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<org>-root-token"

vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki

BUNDLE="$(sudo cat /opt/<org>-ca/intermediate/certs/intermediate-ca.crt \
                  /opt/<org>-ca/intermediate/private/intermediate-ca.key)"
vault write pki/issuers/import/bundle pem_bundle="${BUNDLE}"

vault write pki/roles/<org>-platform-role \
  allowed_domains="<org>.internal" \
  allow_subdomains=true \
  allow_ip_sans=true \
  max_ttl="2160h" \
  ttl="2160h" \
  key_type="rsa" key_bits=2048 \
  server_flag=true client_flag=false \
  organization="<Org>" country="XX"
```

### Phases 6–9 — Ansible playbook, OCSP/CRL servers, nuke.sh, verify-all.sh

For these, lean on the canonical guide structure. Key files:

**`scripts/refresh-crl.sh`:**

```bash
#!/bin/bash
set -e
sudo openssl ca -config /opt/<org>-demo/ca/intermediate/openssl-intermediate.cnf \
  -gencrl -out /opt/<org>-ca/intermediate/crl/intermediate-ca.crl
echo "CRL refreshed"
```

**`scripts/nuke.sh`** modes (apply G3, G8):

```bash
# Three modes:
#   serial <SERIAL>   - revoke one cert by serial
#   service <NAME>    - revoke all certs for a service
#   all               - revoke entire intermediate (catastrophic)
# All modes:
#   1. openssl ca -revoke + refresh-crl.sh
#   2. vault write pki/revoke serial_number=<...>
#   3. vault write -force pki/crl/rotate >/dev/null 2>&1 || true   (G3)
#   4. lineinfile to /var/log/<org>-nuke-audit.log
# Confirmation gate unless MJBL_AUTO=1
# When invoking ansible-playbook: DO NOT pass -q (G8)
```

**`scripts/verify-all.sh`** — 18 checks:
- root cert self-signed (G1 method)
- intermediate signed by root, pathlen=0
- system trust store contains root
- service cert chain verifies
- NGINX listening on 443
- `curl https://<cn>` returns expected JSON
- OCSP responder returns `good` for active serial
- CRL HTTP server returns CRL bytes
- vault status reachable
- vault PKI role exists
- `vault write pki/issue/...` returns cert with correct issuer
- Ansible playbook syntax-check passes
- nuke.sh exists + executable
- refresh-crl.sh produces CRL with current `Last Update`
- audit log files exist
- index.txt of intermediate is parseable
- (2 more situation-specific)

---

## Production hardening — what to surface but NOT execute

When the user finishes Phase 9 of the demo, surface these as a deferred to-do list (do not auto-execute):

| Demo | Production move |
|---|---|
| Vault dev mode (in-memory) | Vault Raft cluster ≥3 nodes, auto-unseal via cloud KMS or HSM, immutable snapshots |
| Root key on disk (`/opt/<org>-ca/root/private/`) | Offline air-gapped Root + HSM (YubiHSM2 minimum, ideally enterprise HSM) + signing ceremony |
| Intermediate key on disk | YubiHSM2 / PKCS#11 (SoftHSM2 stub already in Phase 0) |
| Replace `127.0.0.1` IP SAN | Real static ISP IP or service mesh DNS |
| `MJBL_AUTO=1` to skip nuke confirmation | Strict confirmation + 4-eyes approval |
| `openssl` OCSP responder (G10) | Vault built-in OCSP, or write index.txt syncer |
| Single CRL distribution point | Geo-distributed, must-staple where supported |
| 90-day cert TTL | Either: shrink to ≤24h with auto-renew, or add ACME/SCEP for renewal automation |

---

## Memory hygiene

Before starting a fresh CA bootstrap on a new machine, check whether a prior session left memory state for the same `<org>` tag. If so:

- Read `~/.claude/projects/-home-<user>/memory/project-<org>-internal-ca.md` for prior adaptations
- Read `~/.claude/projects/-home-<user>/memory/reference-<org>-ca-guide.md` for guide pointer

Carry forward the gotcha list (G1–G12) — those apply to most Ubuntu+Vault combinations.

---

## Handoff to `mtls` skill

After Phase 9 verify-all passes, if the user mentions:
- "client cert", "mTLS", "mutual TLS"
- "branch authentication", "device cert", "per-device identity"
- "server should know which client"
- Provides another markdown with phases A–E

… invoke the [[mtls]] skill. It assumes everything this skill built is in place.
