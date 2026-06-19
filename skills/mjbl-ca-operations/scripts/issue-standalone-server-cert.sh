#!/usr/bin/env bash
# issue-standalone-server-cert.sh — issue a STANDALONE serverAuth cert for an internal service
# (e.g. a Rancher UI, an internal admin app) from Vault, WITHOUT touching the mTLS gateway,
# /etc/ssl/mjbl, the gateway's staged cert, or any propagation path. Artifacts go ONLY to --out.
#
# Why this exists: issue-server-cert.sh is purpose-built for THE gateway cert (it stages into
# /etc/ssl/mjbl and is meant to be re-run with the full gateway SAN list). For one-off internal
# services that must NOT disturb the gateway, use this instead.
#
#   Usage:
#     issue-standalone-server-cert.sh <fqdn> [fqdn2 ...] --out <dir> [options]
#       <fqdn...>          first = CN, all = SANs (one cert covers all listed names)
#   Options:
#     --out <dir>          REQUIRED. destination dir for artifacts (refuses mTLS/CA dirs)
#     --csr <file>         sign this CSR via pki/sign (private key stays external — preferred for
#                          network-isolated targets). Omit to let Vault generate the key (pki/issue).
#     --ip <ip[,ip...]>    IP SANs
#     --ttl <dur>          default 2160h (90d)
#     --role <name>        Vault role (default: mjbl-platform-role)
#     --token-file <path>  read the (scoped, short-lived) Vault token from this file (never echoed)
#     --vault-addr <url>   default https://127.0.0.1:8200
#     --vault-cacert <f>   default /opt/vault/tls/vault.crt
#     --dry-run            issue + validate into --out but do not append to the audit log
#
#   Auth: VAULT_ADDR/VAULT_CACERT default to the local Vault; the token comes from --token-file,
#   env VAULT_TOKEN, or the vault CLI token helper (~/.vault-token). This tool NEVER mutates a role.
#   Run ON the CA host as root. Does NOT touch /etc/ssl/mjbl and does NOT propagate anywhere.
#   Output files in <dir>: cert.crt, fullchain.crt (leaf+issuing_ca), ca-chain.crt (intermediate+root),
#   and service.key (ONLY when Vault generated the key, i.e. no --csr).
set -euo pipefail

ROLE="mjbl-platform-role"; OUT=""; CSR=""; IPS=""; TTL="2160h"; ALLOW_NEW=0; DRYRUN=0; TOKFILE=""; NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2;;
    --csr) CSR="${2:?}"; shift 2;;
    --ip)  IPS="${2:?}"; shift 2;;
    --ttl) TTL="${2:?}"; shift 2;;
    --role) ROLE="${2:?}"; shift 2;;
    --token-file) TOKFILE="${2:?}"; shift 2;;
    --vault-addr) VAULT_ADDR="${2:?}"; shift 2;;
    --vault-cacert) VAULT_CACERT="${2:?}"; shift 2;;
    --dry-run) DRYRUN=1; shift;;
    -*) echo "unknown flag: $1" >&2; exit 1;;
    *) NAMES+=("$1"); shift;;
  esac
done

export VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
export VAULT_CACERT="${VAULT_CACERT:-/opt/vault/tls/vault.crt}"
# Token: prefer a --token-file (read internally, never echoed); else env VAULT_TOKEN; else the
# vault CLI token helper (~/.vault-token). Lets the operator hand off a scoped, short-lived token.
[ -n "$TOKFILE" ] && export VAULT_TOKEN="$(cat "$TOKFILE")"
[ -n "$OUT" ] || { echo "ERROR: --out <dir> is required" >&2; exit 1; }
[ "${#NAMES[@]}" -ge 1 ] || { echo "ERROR: at least one <fqdn> is required" >&2; exit 1; }
# Hard guard: never write into the gateway / CA material dirs.
case "$OUT" in
  /etc/ssl/mjbl*|/opt/mjbl-ca*|/opt/mjbl-demo*) echo "ERROR: refusing to write into an mTLS/CA dir: $OUT" >&2; exit 1;;
esac

ROOT_CA="/opt/mjbl-ca/root/certs/root-ca.crt"
INT_CA="/opt/mjbl-ca/intermediate/certs/intermediate-ca.crt"
CN="${NAMES[0]}"; SANS="$(IFS=,; echo "${NAMES[*]}")"
log(){ echo "$(date -u +%FT%TZ) $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

for n in "${NAMES[@]}"; do
  echo "$n" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' || die "invalid FQDN: $n"
done

# Confirm the role permits each name (exact or subdomain suffix match against allowed_domains).
# This tool NEVER mutates a role — if a name isn't allowed it stops and tells you how to fix it.
ALLOWED="$(vault read -format=json "pki/roles/$ROLE" | jq -r '(.data.allowed_domains // []) | join(",")')"
allowed_ok(){ local f="$1" d; for d in ${ALLOWED//,/ }; do [ "$f" = "$d" ] && return 0; [ "${f%.$d}" != "$f" ] && return 0; done; return 1; }
for n in "${NAMES[@]}"; do
  allowed_ok "$n" || die "'$n' is not permitted by role '$ROLE' (allowed_domains: [$ALLOWED]).
       Pass --role <a role that allows it>, or have an operator extend that role's allowed_domains.
       (This tool will not mutate a role.)"
done

mkdir -p "$OUT"; chmod 700 "$OUT"
if [ -n "$CSR" ]; then
  [ -f "$CSR" ] || die "CSR not found: $CSR"
  log "signing CSR ($CSR)  CN=$CN  SANs=$SANS  role=$ROLE  (key stays external)"
  RESP="$(vault write -format=json "pki/sign/$ROLE" csr=@"$CSR" common_name="$CN" alt_names="$SANS" ${IPS:+ip_sans="$IPS"} ttl="$TTL")"
else
  log "issuing  CN=$CN  SANs=$SANS  role=$ROLE  (Vault-generated key)"
  RESP="$(vault write -format=json "pki/issue/$ROLE" common_name="$CN" alt_names="$SANS" ${IPS:+ip_sans="$IPS"} ttl="$TTL")"
  echo "$RESP" | jq -r .data.private_key > "$OUT/service.key"; chmod 400 "$OUT/service.key"
fi
echo "$RESP" | jq -r .data.certificate                      > "$OUT/cert.crt"
echo "$RESP" | jq -r '.data.certificate, .data.issuing_ca'  > "$OUT/fullchain.crt"
echo "$RESP" | jq -r '.data.ca_chain[]?'                    > "$OUT/ca-chain.crt" || true
[ -s "$OUT/ca-chain.crt" ] || cat "$INT_CA" "$ROOT_CA" > "$OUT/ca-chain.crt"
chmod 444 "$OUT/cert.crt" "$OUT/fullchain.crt" "$OUT/ca-chain.crt"

# validate before declaring success
openssl x509 -in "$OUT/cert.crt" -noout -text | grep -q "TLS Web Server Authentication" || die "issued cert is not serverAuth"
if openssl x509 -in "$OUT/cert.crt" -noout -text | grep -q "TLS Web Client Authentication"; then die "issued cert unexpectedly carries clientAuth"; fi
openssl verify -CAfile "$ROOT_CA" -untrusted "$INT_CA" "$OUT/fullchain.crt" >/dev/null || die "chain does not verify to the root"
if [ -f "$OUT/service.key" ]; then
  km="$(openssl rsa -in "$OUT/service.key" -noout -modulus | openssl md5)"
  cm="$(openssl x509 -in "$OUT/cert.crt"  -noout -modulus | openssl md5)"
  [ "$km" = "$cm" ] || die "key/cert modulus mismatch"
fi

SUBJ="$(openssl x509 -in "$OUT/cert.crt" -noout -subject)"
SERIAL="$(openssl x509 -in "$OUT/cert.crt" -noout -serial | cut -d= -f2)"
ENDDATE="$(openssl x509 -in "$OUT/cert.crt" -noout -enddate | cut -d= -f2)"
[ "$DRYRUN" = 1 ] || echo "$(date -u +%FT%TZ) | STANDALONE-SERVER-CERT | cn=$CN | sans=$SANS | serial=$SERIAL | expires=$ENDDATE | out=$OUT" >> /var/log/mjbl-standalone-cert.log

log "OK — standalone serverAuth cert issued (gateway and /etc/ssl/mjbl untouched)"
echo "  subject : $SUBJ"
echo "  serial  : $SERIAL"
echo "  expires : $ENDDATE"
echo "  output  : $OUT  (cert.crt, fullchain.crt, ca-chain.crt$([ -f "$OUT/service.key" ] && echo ', service.key'))"
