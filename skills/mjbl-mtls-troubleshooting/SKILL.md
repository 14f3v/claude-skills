---
name: mjbl-mtls-troubleshooting
description: This skill should be used when something on the MJBL mTLS platform is BROKEN and the user asks to "debug enrollment", "could not reach the enrollment server", "device won't enroll", "enrollment hangs / times out", "revoked device still works / still logs in", "device rejected at the gateway", "HandshakeException / no alternative certificate subject name", "the signer/relay isn't responding", "why is mTLS failing", or any symptom→cause→fix diagnosis of an enrollment or mutual-TLS failure on the live MJBL mTLS device-auth platform deployed on this host. It is the go-to diagnostic playbook (decision tree) that maps a symptom to its layer and the exact verification step, then routes to the owning plane skill.
version: 0.1.0
---

# MJBL mTLS Troubleshooting — Diagnostic Playbook (symptom → cause → fix)

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname root-ca, the MJBL mTLS *remote runner*) holds the authoritative runbooks. This skill is the operational index + distilled live facts — READ the referenced docs before any prod-touching step:
> - `/home/mjbl/mjbl-mtls-revocation-postmortem.md` — the 2026-06-09 incident: revoked devices kept authenticating because the signer's Vault AppRole lacked `pki/crl/rotate` (the `crl_status:403 / crl_published:false` smoking gun). Source of the 3-hop CRL lesson + the contributing-factor list that drives the revocation branch of this tree.
> - `/home/mjbl/mjbl-mtls-enrollment/signer/mjbl_enroll_signer.py` — the SIGNER source: exact wire contracts, validation order, audit fields, and the `_read_json` body-read code path (the one silent-hang failure mode).
> - `/home/mjbl/agency_v2/lib/services/mtls.dart` — the client `EnrollmentException` hierarchy + `exceptionForStatus()` HTTP→exception map (what the *device* shows for each failure layer).
> - Cross-cutting — every sibling `mjbl-*` skill owns the *fix* for its layer; this skill is the triage front door. See **Related skills**.

## When to use
- A device shows **"could not reach the enrollment server"** / enrollment hangs / times out.
- Enrollment returns a **specific** error (token rejected, branch refused, replay, rate-limited) and you need to map it to a cause.
- A **revoked device still authenticates** at the gateway ("I revoked it but it's still logging in").
- A device is **rejected at the gateway** that shouldn't be (`HandshakeException`, `no alternative certificate subject name`, `verify=FAILED`, HTTP 400).
- The **signer or relay** appears down / unreachable, or you need to prove *whether the request even arrived*.
- General "mTLS is broken, where do I start" triage before diving into one plane's skill.

## First cut — which LAYER is it? (read the error string, don't guess)
The single most important triage step: **a transport failure and an application reject look totally different on the device.** The client (`mtls.dart`) maps them deterministically:

| Device shows / `EnrollmentException` | HTTP / cause | Layer | Means |
|---|---|---|---|
| **"Could not reach the enrollment server"** = `EnrollNetworkException` | **NO HTTP status** — `SocketException`, `HandshakeException`, or client timeout | **transport / DNS / TLS** | The request **never got a clean HTTP response**. This is NOT a 403/allowlist. → run the **"could not reach" decision tree** below. |
| `EnrollBadRequestException` | **400 / 413** | app (signer) | malformed request, bad CSR, **CN mismatch**, oversized body. |
| `EnrollAuthException` | **401** | app (signer) | invalid/expired token → mint a fresh one. |
| `EnrollForbiddenException` | **403** | app (signer) | **branch not on allowlist**, or token doesn't match this branch/device. (Has a clean HTTP response — so it is *not* "could not reach".) |
| `EnrollReplayException` | **409** | app (signer) | token already used (single-use replay) → fresh token. |
| `EnrollRateLimitException` | **429** | relay | per-(src-ip+branch) rate limit (`RATE_LIMIT_PER_MIN=30`) → back off. |
| `EnrollUnavailableException` | **502 / 504** | relay→signer | signer down / `signer_tls_error` / timeout → retryable; check the signer. |
| `EnrollServerException(code)` | other 5xx | signer | unexpected; read the signer journal. |
| `EnrollMalformedResponseException` | 200 but bad body | app | signer returned 200 with missing/invalid `chain` — read the signer source. |

**Rule of thumb:** a *specific* error code (401/403/409/429/…) means the request **reached the signer and was cleanly rejected** — the audit log WILL have a line. "Could not reach" means it did **not** get a clean response — and a real reject would have logged. That distinction is the whole tree.

## Decision tree A — "could not reach the enrollment server" (transport-level)
This is `EnrollNetworkException`, NOT 403/allowlist. Work the layers outward.

**(1) Is the relay even healthy? (from an allowlisted source — `! ssh ca` or an internal node)**
```bash
getent hosts enroll.vte.mjblao.local              # → expect 10.88.101.143 (internal DNS). Empty = DNS gap.
openssl s_client -connect 10.88.101.143:8443 -servername enroll.vte.mjblao.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName     # cert valid? SANs incl. both FQDNs + IP 10.88.101.143?
curl -sf --resolve enroll.maruhanjapanbanklao.com:8443:10.88.101.143 \
  https://enroll.maruhanjapanbanklao.com:8443/healthz           # relay up?  (TCP :8443 open?)
```
If TCP `:8443` is closed or the cert is expired/SAN-wrong → relay-side problem (deploy/cert-rotation; see `mjbl-enrollment-plane` / `mjbl-cert-lifecycle`).

**(2) Does the request actually REACH the signer?** (the most decisive test)
```bash
! ssh ca 'sudo tail -f /var/log/mjbl-enrollment.log'      # watch WHILE the device retries
! ssh ca 'journalctl -u mjbl-enroll-signer -f'            # same audit mirrored
```
- **NO new line while the device retries** → it never arrived: **network / DNS / firewall / relay** problem (go back to step 1, and step 3). A real reject (401/403/409) *always* writes an audit line.
- **A `sign`/`access` line DOES appear** → it arrived; the failure is the signer's response or a body-read stall (step 4), or the device is mis-reading the response.

**(3) The `.local` / mDNS trap (very common on tablets).** `enroll.vte.mjblao.local` is a `.local` name → Android's resolver may route it to **mDNS / multicast** (version-dependent — e.g. 12 vs 13 behave differently) and never hit your unicast DNS, so the connect fails even though the relay is up. **Workaround:** build with `--dart-define=MTLS_ENROLL_BASE=https://10.88.101.143:8443` (the relay cert carries **IP SAN 10.88.101.143**) or `https://enroll.maruhanjapanbanklao.com:8443` (the other SAN). Prereq: internal DNS must resolve the `.local` name to the relay LB. (See `mjbl-client-provisioning`.)

**(4) Signer SILENT after receiving — the body-read hang.** The signer's `_read_json` does `raw = self.rfile.read(Content-Length)` with **no socket read timeout** (`ThreadingHTTPServer` sets none). A client that sends a large `Content-Length` header but a short/stalled body **hangs that worker thread indefinitely — no log line, no audit event** — and the device eventually times out → shows "could not reach". This is the **only** code path that hangs instead of returning a clean 4xx/5xx. Symptom-match: device timeout/"could not reach" with an `access`-but-no-completion pattern or **nothing** in the audit/journal for that attempt, plus possibly a thread that never returns. It's daemon-threaded (won't take the signer fully down) but a flood of stalled bodies starves threads. **Fix when touched:** set a per-request socket timeout before the read (source in `signer/mjbl_enroll_signer.py`).

**(5) Allowlist ≠ "could not reach".** An off-allowlist branch yields a clean **403** (`EnrollForbiddenException`, audit `reason=branch_not_allowed`/`ip_not_allowed`), **not** a transport error. If the symptom really is "could not reach", the allowlist is a red herring — but if you've reclassified it as a 403, check it:
```bash
! ssh ca 'sudo cat /opt/mjbl-enroll/allowlist'    # one UPPERCASE, case-sensitive branch code per line
```
Branch allowlist is **case-sensitive + UPPERCASE** (device upper-cases the branch). Source-IP allowlist `SIGNER_ALLOW` must list the **internal** node IPs (relay SNATs to its node, e.g. `10.88.1.26/27`) — never the DMZ; a missed internal IP → 403 `ip_not_allowed`. (See `mjbl-enrollment-plane`.)

## Decision tree B — "revoked device still works / still logs in"
**This is almost always a missed CRL hop — `vault revoke` alone does NOT enforce.** It was the exact 2026-06-09 incident. Revocation is a **3-hop, pull-based, eventually-consistent** chain; any hop can fail silently.

1. **Did the signer's CRL rotate succeed?** Read the signer audit log for the revoke event — the smoking gun from the post-mortem:
   ```bash
   ! ssh ca 'sudo grep "\"event\":\"revoke\"" /var/log/mjbl-enrollment.log | tail'
   ```
   `"crl_status":403, "reason":"crl_rotate_failed", "crl_published":false` ⇒ Vault `pki/revoke` succeeded but `pki/crl/rotate` was **denied** ⇒ the live `mjbl-enroll` AppRole policy is **missing the `pki/crl/rotate` (read) grant** (committed in `signer/mjbl-enroll.policy.hcl` but never `vault policy write`'d — **IaC drift**). Fix: apply the policy, then force `vault read pki/crl/rotate` to backfill.
2. **Hop 2 — CA-host publish:** run `/opt/mjbl-demo/scripts/refresh-crl.sh` on the CA host (the timer does it ~1 min; run by hand to not wait). Confirm `:8888` serves a fresh **intermediate** CRL with the new serial:
   ```bash
   ! ssh ca 'curl -fsS http://localhost:8888/crl/intermediate.crl | openssl crl -noout -lastupdate -nextupdate'
   ```
3. **Hop 3 — Cluster:** CronJob `mjbl-crl-refresh` (ns `mjbl-mtls-gateway`, `*/2`) pulls `:8888` → patches ConfigMap `mjbl-tls-trust` → rolls nginx. Force it: `kubectl -n mjbl-mtls-gateway create job --from=cronjob/mjbl-crl-refresh crl-now-$(date +%s)` (or `enforce-crl-now.sh` ~30 s).
4. **Re-handshake to verify.** nginx caches `ssl_crl` in memory **until reload**, and TLS 1.3 verifies the client cert **post-handshake** — a **kept-alive connection isn't re-checked**. The revoked cert only bites on a **NEW** handshake (close/reopen the app). Under TLS 1.3 a refused client cert returns **400**, not 000 — the self-test asserts that.
5. **Wrong-cluster red herring:** prod ops MUST `export KUBECONFIG=~/.kube/mjbl-prod.config` (or `--context rkek8s`). A non-prod default context silently no-ops your force-job (cost diagnosis time in the incident).

Full chain + fix detail: `mjbl-cert-lifecycle` (procedure A) and the post-mortem. Self-test `mjbl-revocation-selftest` CronJob (`*/5`) proves a revoked canary is refused — check its last run for a standing alert.

## Decision tree C — device rejected at the gateway that shouldn't be
- `HandshakeException: no alternative certificate subject name matches` / TLS SAN error → the device is pointed at the **wrong API base**. `agenttest.maruhanjapanbanklao.com` is **RETIRED**; the gateway server cert SAN is `microloan…` only. Default `MTLS_API_BASE` is already `https://microloan.maruhanjapanbanklao.com:2399` — don't reintroduce `agenttest`.
- `verify=FAILED` / 400 with no app response, device IS enrolled → the device cert chain doesn't verify (expired leaf, or it chains to an old intermediate/root after a rotation), OR it's legitimately revoked (tree B in reverse). Check the gateway access log (`mtls_audit`: CN + serial + `verify=SUCCESS/FAILED` + TLS version) to see exactly which serial and why.
- Device cert **expired** (90-day branch role TTL) → app should route back to re-enroll via AppGate; renewal = operator re-enroll (long-press the login version chip → Re-enroll). After a re-enroll (new serial, same CN) the app must null `_cachedContext` + reinstall `HttpOverrides.global` or restart. (See `mjbl-client-provisioning`.)
- `_cachedContext` immutability: it's frozen for the app lifetime — a fresh chain won't be picked up until the context is rebuilt/app restarted.

## Decision tree D — signer / relay appears down
```bash
! ssh ca 'sudo systemctl status mjbl-enroll-signer --no-pager'
! ssh ca 'curl -sf --cacert /opt/mjbl-ca/root/certs/root-ca.crt https://10.88.1.116:8444/healthz'   # {"status":"ok"}
KUBECONFIG=~/.kube/mjbl-prod.config kubectl -n mjbl-enroll get deploy,svc,pods -o wide
```
- Relay → signer `502 signer_tls_error`: the relay verifies the signer cert with `check_hostname=True` against the **IP-literal** `SIGNER_URL` → the **signer cert must carry IP SAN `10.88.1.116`**; a CN/DNS-only cert fails the handshake.
- Relay pods `CrashLoopBackOff` / `bad base64 decode` after a deploy: the `enroll-relay-tls` Secret was clobbered by the placeholder — re-apply kustomization FIRST, bootstrap the Secret **imperatively LAST**.
- Vault **sealed** (after a CA-host reboot) → issuance + CRL refresh silently halt: `! ssh ca 'vault status'`; unseal ×3. (See `mjbl-ca-operations`.)

## Gotchas & hard-won lessons (the landmines this tree encodes)
- **"Could not reach" is transport, not a 403.** A clean 401/403/409/429 always reaches the signer and **audits**; "could not reach" (`EnrollNetworkException`) means SocketException/HandshakeException/timeout — *no* clean HTTP response. Mis-triaging this sends you hunting the allowlist for a DNS/mDNS/firewall problem.
- **A missing audit line is itself a signal** — if the device retries and **nothing** lands in `/var/log/mjbl-enrollment.log`, the request never arrived (network/DNS) **or** it hit the body-read hang. A real reject always logs.
- **The `.local` mDNS trap** is the single most common tablet enrollment failure — switch `MTLS_ENROLL_BASE` to the IP or the public FQDN SAN.
- **The body-read hang is the ONLY silent code path** — every other failure returns a clean 4xx/5xx and audits. If it hangs with no log, suspect `_read_json`.
- **Revocation is 3 hops, not 1** — and the root cause of the real incident was **IaC drift** (the `pki/crl/rotate` grant was in git but never applied to live Vault). A grant in a `.hcl` is not a grant in Vault.
- **nginx caches `ssl_crl` until reload + TLS 1.3 checks the cert post-handshake** — a correct CRL only bites on a NEW handshake; a kept-alive connection is never re-checked.
- **Wrong kubeconfig = silent no-op.** Prod ops MUST pin `~/.kube/mjbl-prod.config`; the default context is a different cluster.
- **Under TLS 1.3 a refused client cert returns `400`, not `000`** — don't read 400 as a generic app error during revocation testing.
- **Prod gates while debugging:** CA-host inspection/changes go via `! ssh ca` (the agent can't reach the CA host directly); `k8s-config` merges are user-gated; ArgoCD prod writes/force-sync are user-gated/denied (reads OK). **Never** `kubectl apply` a TLS Secret or `kubectl get secret … -o yaml/json` (leaks `tls.key`).

## Related skills
This skill triages; the fix lives in the plane that owns the layer:
- **`mjbl-enrollment-plane`** — signer (`:8444`) + relay (`:8443`): mint/sign/revoke/allowlist, the body-read hang, source-IP/branch allowlist 403s, relay deploy/cert.
- **`mjbl-cert-lifecycle`** — the 3-hop revocation enforcement chain + cert rotation (the "revoked device still works" fix in full).
- **`mjbl-client-provisioning`** — the agency_v2 device app: `.local`/mDNS, `EnrollmentException` mapping, `HandshakeException`/SAN, re-enroll & `_cachedContext` rebuild, `MTLS_ENABLED` build-time flip.
- **`mjbl-ca-operations`** — Vault sealed/unseal, CRL publish (`:8888`), the `pki/crl/rotate` 405 quirk, OCSP, gateway-firewall constraint.
- **`mjbl-mtls-platform`** — the top-level ecosystem map / KB index if you need to (re)locate a component before triaging.
