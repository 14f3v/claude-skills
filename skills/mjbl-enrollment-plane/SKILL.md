---
name: mjbl-enrollment-plane
description: This skill should be used when the user asks to "mint an enrollment token", "enroll a device", "allowlist a branch", "revoke a device cert", "check the signer/relay", "look at the enrollment logs", "deploy/rebuild the enroll relay", "rotate the relay TLS cert", or otherwise operate the MJBL device-enrollment SIGNER (CA host :8444) + RELAY (cluster :8443) — the two-tier mTLS branch/device enrollment plane of the live MJBL mTLS platform on this host. Covers mint/sign/revoke/allowlist, audit logs, the source-IP + branch allowlists, relay deploy, and relay cert rotation.
version: 0.1.0
---

# MJBL Enrollment Plane — Signer (:8444) + Relay (:8443)

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname root-ca, the MJBL mTLS *remote runner*) holds the authoritative runbooks. This skill is the operational index + distilled live facts — READ the referenced docs before any prod-touching step:
> - `/home/mjbl/mjbl-mtls-enrollment/DEPLOY.md` — end-to-end deploy runbook (Vault policy/KV mount, signer+relay certs, systemd install, firewall, image build, Fleet manifests, acceptance test 9a–9e).
> - `/home/mjbl/mjbl-mtls-enrollment/signer/mjbl_enroll_signer.py` — the SIGNER source (the *only* component that touches Vault); exact wire contracts, validation order, audit fields, the body-read code path.
> - `/home/mjbl/mjbl-mtls-enrollment/signer/mjbl-enroll-signer.service` — the systemd unit (user, hardening, `EnvironmentFile`, `ReadWritePaths`).
> - `/home/mjbl/mjbl-mtls-enrollment/signer/signer.env.example` — every env key + its prod default (copied to `/opt/mjbl-enroll/signer.env`).
> - `/home/mjbl/mjbl-mtls-enrollment/relay/app.py` — the RELAY source (verbatim forwarder, rate-limiter, fail-closed map, env keys).
> - `/home/mjbl/mjbl-relay-cert-rotation-runbook.md` — relay TLS cert rotation (leak-safe: local keygen → CSR → `pki/sign` → imperative Secret re-create → config-revision bump → revoke old).
> - `/home/mjbl/mjbl-enrollment-app-golive-plan.md` — the agency_v2 Flutter client side (enroll UX, root pinning, error-code mapping to 401/409/403).

## When to use
- Mint a one-time enrollment / QR / claim token for a device (`POST /mint`).
- Add / list / remove a branch on the allowlist (`/allowlist`).
- Revoke a device cert + publish the CRL (`POST /revoke`), or list issued devices (`GET /devices`).
- Inspect enrollment audit logs / activity (signer audit log or `journalctl`).
- Deploy, rebuild, or roll the cluster relay; rotate the relay's server TLS cert.
- Diagnose "could not reach the enrollment server" on a device (often the body-read-hang gotcha, or the firewall/allowlist).

## Architecture / live facts
Two tiers; the RELAY holds **no secrets**, all authority is on the SIGNER (mirrors the CRL `:8888` pull model):

```
branch device ──TLS (device pins MJBL root)──► RELAY  (cluster ns mjbl-enroll, VIP 10.88.101.143:8443)
                                                  │  POST /enroll  ── forwards body verbatim ──►
                                                  ▼
                                                SIGNER (CA host 10.88.1.116:8444)  POST /sign
                                                  │  (the ONLY thing that touches Vault)
                                                  ▼
                                        Vault https://127.0.0.1:8200  pki/sign/mjbl-branch-client-role + KV-v2 'enroll'
```

**SIGNER** — `mjbl-mtls-enrollment/signer/`:
- systemd unit `mjbl-enroll-signer` on CA host `10.88.1.116` (jump-host only via `! ssh ca`); runs as user **`mjbl-enroll`**, pure-stdlib python3 (airgapped, no pip), `Type=simple`, heavily hardened (`ProtectSystem=strict`, `CapabilityBoundingSet=` empty, `SystemCallFilter=@system-service`).
- Binds `BIND_ADDR=0.0.0.0:8444` (TLS, serverAuth cert with **IP SAN 10.88.1.116**, chains to MJBL root). Bind is `0.0.0.0` but `SIGNER_ALLOW` is the access control.
- **Endpoints**: `POST /sign` (called by relay; unauthenticated at app layer — gated by source IP + token), `POST /mint`, `POST /revoke`, `GET /devices`, `GET /allowlist` + `POST /allowlist` + `DELETE /allowlist/<code>`, `GET /activity`, `GET /claim-status?claim_id=…`, `GET /healthz`. All except `/sign` and `/healthz` require `Authorization: Bearer <admin_token>`.
- Reads `/opt/mjbl-enroll/{signer.env, admin_token, allowlist, tls/{signer.crt,signer.key}, approle/{role_id,secret_id}}`.
- **Source-IP allowlist** `SIGNER_ALLOW=10.88.1.26,10.88.1.27,127.0.0.1` (internal-zone k8s nodes n04/n02 — relay egress after node SNAT — + localhost for operator `/mint`). Off-list source → **403** (`event=access reason=ip_not_allowed`). Mirrors the `:8888` nginx allow/deny; also enforced at host firewall (ufw) on `:8444`. **Whitelist INTERNAL nodes, never the DMZ.**
- **Branch allowlist** file `/opt/mjbl-enroll/allowlist`, one branch-code per line (`#` comments + blanks ignored), re-read live on every `/mint` and `/sign` (no restart). Off-list branch → **403** at `/mint` and again at `/sign` (defence in depth). Unreadable allowlist → fail-closed (no branch allowed).
- Calls Vault via **AppRole** (`role_id`/`secret_id` files → short-lived token). Policy `mjbl-enroll` grants `pki/sign/mjbl-branch-client-role` (update), `pki/revoke`, `pki/cert/*` (read), KV-v2 `enroll/data|metadata/tokens/*`; **`pki/issue/*` is DENIED** (Model A: device keeps its own key). Branch role = **EC P-256, clientAuth-only, ttl 2160h** (90d), `allowed_domains=[mjbl.internal]`. CN is server-built `"<branch>.<uuid>.mjbl.internal"`; signer pins `use_csr_sans=false`/`use_csr_common_name=false` so a device can't inject SANs.
- **Token store** = Vault KV-v2 mount `enroll/`. Single-use is atomic via CAS: `/mint` writes `cas=0` (create-only); `/sign` reads version → validates → CAS-writes `used:true` at that version *before* issuing (claim-then-sign).
- **Audit log** `/var/log/mjbl-enrollment.log` — append-only single-line JSON, secret-free: `ts,event,branch,uuid,cn,serial,src,outcome` (+ `reason`, `by` operator, `claim_id`, `metadata`). Events: `mint`, `sign`, `revoke`, `allowlist`, `devices`, `activity`, `access`, `startup`. Also mirrored to `journalctl -u mjbl-enroll-signer`.

**RELAY** — `mjbl-mtls-enrollment/relay/`:
- k8s Deployment `mjbl-enroll-relay`, namespace **`mjbl-enroll`**, on the prod cluster `rkek8s` (kubeconfig `~/.kube/mjbl-prod.config`), 2 replicas pinned to internal-zone nodes (`nodeSelector: network-zone=internal`).
- Service is a **MetalLB LoadBalancer**, VIP **`10.88.101.143:8443`** (DMZ pool, `externalTrafficPolicy: Cluster`, **no `loadBalancerSourceRanges`** — exposure is controlled at the signer/firewall, not here).
- Endpoints: `POST /enroll` (forwards body byte-identical to signer `/sign`), `GET/HEAD /healthz`. Env: `SIGNER_URL=https://10.88.1.116:8444`, `SIGNER_CA=/tls/mjbl-root.crt`, `TLS_CERT=/tls/tls.crt`, `TLS_KEY=/tls/tls.key`, `LISTEN_PORT=8443`, `RATE_LIMIT_PER_MIN=30` (per src-ip+branch, in-memory per-pod), `SIGNER_TIMEOUT=15`.
- Verifies the signer cert against the MJBL root with `check_hostname=True` against the IP-literal `SIGNER_URL` → signer cert **must** carry IP SAN `10.88.1.116`.
- Server cert: `enroll-relay-tls` Secret (keys `tls.crt`, `tls.key`, `mjbl-root.crt`), serverAuth, **RSA-2048**, SANs `enroll.vte.mjblao.local` + `enroll.maruhanjapanbanklao.com` + IP `10.88.101.143`, signed from `mjbl-platform-role`. Bootstrap/externally-managed (NOT in git, NOT kustomize-tracked).
- Image `mjcr.vte.mjblao.local/mjbl/enroll-relay:0.1.0` (`imagePullPolicy: IfNotPresent` — bump the tag on rebuild, never re-push the same tag).
- Manifests in k8s-config at `deployments/mjbl-mtls-enrollment/production/` (`namespace, configmap, tls-secret placeholder, deployment, svc, kustomization`). **ArgoCD app `mjbl-mtls-enrollment`** (auto-prune off; `enroll-relay-tls` excluded). Roll = bump `mjbl.internal/config-revision` annotation in `deployment.fleet.yaml` via PR (user-merged) → ArgoCD syncs (~1 min, `maxUnavailable: 0`).

**App side**: agency_v2 `MtlsConfig.enrollBase` → `https://enroll.maruhanjapanbanklao.com:8443` (public/NAT front of the relay VIP). Device pins the bundled MJBL root at enroll time (it has no client cert yet).

**Helper scripts** on the ops host: `/tmp/mjbl_mint.sh`, `/tmp/mjbl_revoke_device.sh`, `/tmp/mjbl_allowlist.sh` (mint reads the admin token from `/opt/mjbl-enroll/admin_token` on the CA host, never printed).

## Key procedures
All `:8444` calls must originate from an allowlisted source — the CA host (`! ssh ca`) or an internal node. See DEPLOY.md §9 for the full acceptance flow.

**Mint a token** (`/mint`, admin-bearer). On the CA host:
```bash
ADMIN=$(sudo cat /opt/mjbl-enroll/admin_token)
curl -sf --cacert /opt/mjbl-ca/root/certs/root-ca.crt \
  -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
  -d '{"branch":"br-vte-001","uuid":"<device-id>","ttl_seconds":900}' \
  https://10.88.1.116:8444/mint
# -> {"token","expires_at"}.  Omit "uuid" for a branch-scoped CLAIM token (mass enroll); response then also has "claim_id".
# DEFAULT ttl 900s (15m), MAX 86400s (24h). branch must be on the allowlist or -> 403.
```
The device then `POST /enroll`s `{token,branch,uuid,csr}` (CSR CN must equal `<branch>.<uuid>.mjbl.internal`, EC P-256) through the relay VIP. Replay of a spent token → **409**; off-allowlist → **403**; bad/expired token → **401**.

**Allowlist** (`/allowlist`, admin-bearer): `GET` lists, `POST {"branch":"…"}` adds, `DELETE /allowlist/<code>` removes. Or edit `/opt/mjbl-enroll/allowlist` directly (live re-read, no restart) — but the API path keeps an audit trail.

**Revoke a device** (`/revoke`, admin-bearer): body `{"serial":"…"}` OR `{"branch","uuid"}` (serial resolved from the audit log, last-writer-wins). The signer does Vault `pki/revoke` then **rotates the CRL via a Vault READ of `pki/crl/rotate`** (a write returns 405). Response carries `crl_published`. NOTE — gateway revocation needs **3 hops**, not just this: (1) this `/revoke` (vault revoke + CRL rotate); (2) run `/opt/mjbl-demo/scripts/refresh-crl.sh` on the CA host to republish to `:8888` + the nginx bundle; (3) the cluster CronJob `mjbl-crl-refresh` (ns `mjbl-mtls-gateway`) pulls the fresh `:8888` CRL → updates the ConfigMap → rolls nginx (≤15 min). nginx caches `ssl_crl` until reload; a kept-alive connection isn't re-checked.

**Logs / monitoring**:
```bash
sudo tail -n 50 /var/log/mjbl-enrollment.log         # structured audit (mint/sign/revoke/allowlist/access)
journalctl -u mjbl-enroll-signer -n 50 --no-pager    # signer operational log + same audit mirrored
sudo systemctl status mjbl-enroll-signer --no-pager
curl -sf --cacert /opt/mjbl-ca/root/certs/root-ca.crt https://10.88.1.116:8444/healthz   # {"status":"ok"}
```
Relay side (locally, `KUBECONFIG=~/.kube/mjbl-prod.config`): `kubectl -n mjbl-enroll get deploy,svc,pods -o wide`; relay `/healthz` via the VIP (resolve `enroll.maruhanjapanbanklao.com:8443:10.88.101.143`).

**Deploy / rebuild relay** (DEPLOY.md §6–7): build `mjcr.vte.mjblao.local/mjbl/enroll-relay:<bumped-tag>` → push → update the image tag in `deployment.fleet.yaml` → `kubectl apply -k deployments/mjbl-mtls-enrollment/production` → bootstrap `enroll-relay-tls` Secret **imperatively, LAST** (apply-k first, secret last — re-applying the kustomization after clobbers the real Secret with the placeholder → pods crash `bad base64 decode`).

**Rotate the relay TLS cert** (`mjbl-relay-cert-rotation-runbook.md`): local keygen (RSA-2048) + CSR (CN `enroll.vte.mjblao.local`, SANs both FQDNs + IP `10.88.101.143`) → `! ssh ca` `pki/sign/mjbl-platform-role` → **re-create the Secret imperatively** (`kubectl create secret`, NEVER `apply` — `apply` embeds `tls.key` in the `last-applied-configuration` annotation, the original leak) → bump `config-revision` (PR, user-merged) → verify new serial with `openssl s_client -connect 10.88.101.143:8443` → revoke the OLD serial + `vault write pki/crl/rotate force=true`. `shred -u` local key material when done.

## Gotchas & hard-won lessons
- **BODY-READ HANG (the one silent failure path).** The signer's `_read_json` does `raw = self.rfile.read(Content-Length)` with **no socket read timeout** (`ThreadingHTTPServer` sets none). A client that sends a large `Content-Length` header but a short/stalled body **hangs that worker thread indefinitely** — no log line, no audit event. The device just shows "could not reach the enrollment server." This is the *only* code path that hangs instead of returning a clean 4xx/5xx. Symptom-match: device timeout/"could not reach" with **nothing** in `/var/log/mjbl-enrollment.log` or journal for that attempt (a real reject always audits). Mitigation: it's daemon-threaded so it doesn't take the whole signer down, but a flood of stalled bodies starves threads. Fix when touched: set a per-request socket timeout before the read.
- **`pki/crl/rotate` is a READ in this Vault, not a write** — a write returns 405. The signer's `/revoke` already does `GET pki/crl/rotate`; manual scripts use `vault read` (or `vault write … force=true` only where the runbook explicitly shows it for immediate publish).
- **Revocation is 3 hops, not 1** — vault revoke alone doesn't pull a device off the gateway (see "Revoke" above). The CA-host `refresh-crl.sh` hop is the easy-to-miss one.
- **Whitelist INTERNAL nodes (10.88.1.26/27), never the DMZ** — relay pods SNAT to their internal node IP because the DMZ-pool VIP uses `externalTrafficPolicy: Cluster`. A missed internal IP silently breaks enrollment with a 403 `ip_not_allowed`. Same rule as the `:8888` CRL server.
- **Signer cert needs the IP SAN `10.88.1.116`** — the relay verifies with `check_hostname=True` against an IP-literal URL; a CN/DNS-only cert fails the handshake (relay → 502 `signer_tls_error`).
- **Secret bootstrap ordering** — apply the kustomization FIRST, then create `enroll-relay-tls` imperatively LAST. Re-applying `-k` after re-bootstrapping clobbers the real Secret with the placeholder.
- **NEVER `kubectl apply` the relay Secret, and NEVER `kubectl get secret … -o yaml/json`** — both can leak `tls.key` (`apply` via the last-applied annotation; `get -o yaml` base64-dumps it). Re-create imperatively; the rotation was forced precisely because an `apply` leaked the key once.
- **`IfNotPresent` + reused tag = stale image** — bump the tag on every relay rebuild or nodes keep the old layer.
- **OpenSSL 1.1.1 (the prod CA host) exits 0 on a tampered CSR** — the signer requires the explicit `verify OK` marker AND absence of `verify failure`, not just rc==0. Don't "simplify" `verify_csr_pop_and_cn` to trust the exit code; that silently bypasses proof-of-possession.
- **`use_csr_sans=false` / `use_csr_common_name=false` are load-bearing** — the CSR is fully device-controlled; the signer pins the CN server-side and ignores CSR SANs so a device can't mint `gateway.mjbl.internal`.

## Related skills
- `internal-ca` — the 2-tier PKI + Vault PKI engine the signer issues from.
- `mtls` — client-cert issuance + NGINX `ssl_verify_client` (the gateway the enrolled certs authenticate to).
