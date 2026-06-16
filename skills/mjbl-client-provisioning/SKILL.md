---
name: mjbl-client-provisioning
description: This skill should be used when the user asks to "build the agency_v2 APK", "cut a release", "enroll a device/tablet", "distribute the app to testers/pilot", "set up Firebase App Distribution", "wire claim-QR enrollment", "flip a branch to mTLS", "fix the enroll.vte.mjblao.local DNS issue", or anything about the agency_v2 / microloan Flutter device client on the MJBL mTLS platform (the live deployed ecosystem on this host). Covers build-time dart-defines, on-device Model-A enrollment, the signed mTLS-on release pipeline, Firebase distribution, claim-QR, and the .local-DNS / Android-version landmines.
version: 0.1.0
---

# MJBL Client Provisioning — agency_v2 device app (Flutter/Android)

> **Knowledge base / truth-of-source.** This host (`/home/mjbl`, hostname root-ca, the MJBL mTLS *remote runner*) holds the authoritative runbooks. This skill is the operational index + distilled live facts — READ the referenced docs before any prod-touching step:
> - `/home/mjbl/mjbl-agency-v2-pilot-runbook.md` — Phase-H go-live: build the signed mTLS-on APK, Device-ID→mint→branch+token enroll flow, staged rollout, 3-hop revoke, rollback.
> - `/home/mjbl/mjbl-mtls-client-provisioning.md` — server/PKI counterpart of the app; Model A (on-device keygen + CSR), the two disjoint pipelines, the `_buildSecurityContext()` code contract, Do/Don't, failure-layer cheatsheet.
> - `/home/mjbl/mjbl-mtls-client-context-productions.md` — conceptual client-cert lifecycle, demo-vs-prod, what the gateway sees (`$ssl_client_*` / `X-Client-*` headers), enrollment-endpoint protection.
> - `/home/mjbl/mjbl-device-delivery-runbook.md` — end-to-end tablet delivery (intake→MDM→APK→token→first-run enroll→acceptance→handover), RACI, BUILT-vs-NOT-BUILT honesty contract, per-device checklist.
> - `/home/mjbl/mjbl-agency-v2-firebase-app-distribution-runbook.md` — CI auto-distribution of the signed APK to testers (Firebase `mjbl-inhouse`, App ID, tester group, SA-JSON secret).
> - `/home/mjbl/mjbl-claim-qr-enrollment-design.md` — claim-QR (WhatsApp-Web-style) mass-provisioning: binding flips from `(branch,uuid)` to `branch`-only; signer/BFF/portal/device contracts.
> - `/home/mjbl/mjbl-agency-v2-device-serial-mdm-roadmap.md` — identify a device by its true hardware serial (MDM-gated; EMM injects serial via managed-config; app code deferred).
> - source: `/home/mjbl/agency_v2/lib/services/mtls.dart` (`MtlsConfig` + `MtlsBootstrap`) — the live dart-defines, on-device EC keygen, secure-storage custody, `deviceUuid()` chokepoint.

## When to use
- Build / cut a release of the agency_v2 device app (signed, mTLS-on APK).
- Enroll a pilot tablet (Device-ID → mint one-time token → branch+token → on-device CSR → signed chain).
- Distribute the APK to testers/end-users via Firebase App Distribution.
- Wire or operate claim-QR enrollment (the QR mass-provisioning flow).
- Diagnose `HandshakeException` / "no alternative certificate subject name" / the `.local` enrollment-host failing to resolve on a device.
- Flip a branch to mTLS, or roll it back; understand `MTLS_ENABLED` is build-time, not runtime.
- Plan device-serial identity via MDM (deferred, EMM-gated).

## Architecture / live facts

**App.** `agency_v2` Flutter app — repo `mjbl-digital/agency_v2`; local checkout `/home/mjbl/agency_v2`; Flutter SDK at `/home/mjbl/flutter-sdk` (3.33.0, matches CI). Build pkg `com.agency.mjbl.dev.agency_v2`. Local validate: `export PATH=/home/mjbl/flutter-sdk/bin:$PATH; flutter analyze && flutter test` (~2 min).

**Build-time dart-defines** (`MtlsConfig` in `lib/services/mtls.dart`; all `--dart-define`, NOT runtime toggles):
| Define | Default | Meaning |
|---|---|---|
| `MTLS_ENABLED` | `false` | `true` = mTLS-on. Release CI **enforces** `true` (refuses to ship the legacy accept-all-certs path). |
| `MTLS_API_BASE` | `https://microloan.maruhanjapanbanklao.com:2399` | steady-state DMZ gateway. (`agenttest…` is RETIRED — server SAN is `microloan` only.) |
| `MTLS_ENROLL_BASE` | `https://enroll.vte.mjblao.local:8443` | device-facing enrollment relay (cluster LB / MetalLB VIP `10.88.101.143`). |
| `IS_PROD` | (web build arg) | web `ci-pipeline.yml` sets `IS_PROD=true` → same-origin API; GitOps-pushes the image to `k8s-config` `deployments/microloan/production/microloan-app.fleet.yaml`. |
| `APP_VERSION` | pubspec | version chip; v* tag (minus `v`) wins. |

**Enrollment = Model A** (key born on-device, never transmitted): on first run AppGate detects no cert → enrollment screen shows a **Device ID**. App generates an **EC P-256** keypair on-device (`CryptoUtils.generateEcKeyPair(curve:'prime256v1')`, `pointycastle`), builds a **PKCS#10 CSR** (`X509Utils.generateEccCsrPem`, `basic_utils`) with `CN=<branch>.<uuid>.mjbl.internal`, POSTs `{token,branch,uuid,csr}` over one-way TLS to `${enrollBase}/enroll` → relay → signer `vault write pki/sign/mjbl-branch-client-role` → returns **chain only** (leaf+Intermediate, public). **No p12, no passphrase, no key ever crosses the wire.**

**Trust pinning.** `rootCaAsset = assets/certs/root-ca.crt` (public Root CA, bundled). `SecurityContext(withTrustedRoots:false)` → exclusive trust on the MJBL Root CA only.

**Key custody.** On-device key + returned chain stored in `flutter_secure_storage` **9.2.2** with `AndroidOptions(encryptedSharedPreferences:true)`. **Pin fss at 9.2.x — owner's v10 drops `encryptedSharedPreferences` which `mtls.dart` needs.** Key is at-rest-encrypted but runtime-**extractable** (software) — that's Phase 1; hardware-bound StrongBox keys = Phase 2 (same CSR contract).

**Device identity.** `MtlsBootstrap.deviceUuid()` (`lib/services/mtls.dart`) chain: cached `kDeviceUuid` → `DeviceIdentity.androidId()` (`Settings.Secure.ANDROID_ID`) → random `Uuid().v4()`; each passed through `sanitizeDeviceId()` (strips chars outside `[A-Za-z0-9-_]` — the **dot-strip** is load-bearing: the signer's `/revoke` does `rsplit('.',1)` to recover the branch from the CN, so the id MUST be dot-free). Write-through freezes the first-resolved id.

**CI pipelines** (`.github/workflows/`):
- `android-apk-release.yml` — trigger: push `v*` tag OR `workflow_dispatch`. Guard step refuses unless `MTLS_ENABLED=true`. Builds the signed mTLS-on APK (Android keystore from `ANDROID_KEYSTORE_*` secrets) → uploads `dist/*` artifact → **distributes to Firebase App Distribution**.
- `ci-pipeline.yml` — web build (`IS_PROD=true`) → GitOps push to `k8s-config` microloan-app production overlay → ArgoCD auto-syncs.
- `android-apk-dev.yml` — side-effect-free dev/debug build (defaults mTLS-off; used for compile checks).
- `ci-mtls-guard.yml` — analyze/test gate on PRs.

**Firebase App Distribution.** Project `mjbl-inhouse` (number `718049361610`); App ID `1:718049361610:android:cb34d553…`; registered for pkg `com.agency.mjbl.dev.agency_v2` (App Distribution hard-rejects a mismatched package). Tester group alias default **`pilot`** (live workflow default; the older runbook draft said `mjbl-pilot` — the workflow default is `pilot`, overridable via the `tester_group` dispatch input). Credentials: repo **variable** `FIREBASE_ANDROID_APP_ID` + repo **secret** `FIREBASE_SERVICE_ACCOUNT_JSON` (distribute step self-skips if unset). Distribution-only — NO `google-services.json` / Firebase SDK in the app.

**Gateway / PKI plane** (where the device connects, all BUILT & e2e-verified): DMZ gateway `microloan.maruhanjapanbanklao.com:2399` (LB `10.88.101.142`, backend `10.88.101.141`); CA host `mjbl-ca-crl` `10.88.1.116` (signer `:8444`, relay LB `10.88.101.143:8443`); Vault role `mjbl-branch-client-role` (clientAuth-only, EC P-256, `ttl=2160h`/90d); scoped AppRole `mjbl-enroll` (sign+revoke, issue denied); conditional CRL CronJob `mjbl-crl-refresh` in ns `mjbl-mtls-gateway` (`*/15`, ≤15 min). Gateway `/_local/identity` → `{"verified":"SUCCESS","cn":…}`; cert-less → HTTP 400. Forwarded headers: `X-Client-Verify`, `X-Client-CN`, `X-Client-DN`, `X-Client-Serial`, `X-Client-Fingerprint`, `X-Client-Not-After` (note `X-Client-Verify`, **not** `…Verified`).

## Key procedures

**Build & distribute a release (signed, mTLS-on).** (pilot-runbook §1, firebase-runbook §5)
1. Tag: `git tag v1.1.x && git push origin v1.1.x` — OR Actions → "Android APK (mTLS) — release" → Run workflow. Bump versionCode each release.
2. Guard asserts `MTLS_ENABLED=true`; build bakes in `MTLS_API_BASE` + `MTLS_ENROLL_BASE`; post-build gate asserts no client key shipped + root anchor present.
3. Distribute step uploads to Firebase App ID, notifies tester group `pilot`. Note: `android-apk-release.yml` lives off `main` historically → `workflow_dispatch` can 404 on non-default branches; **tags always work**.

**Enroll a pilot tablet.** (pilot-runbook §2, device-delivery §4)
1. Install signed mTLS-on APK → first run lands on enrollment screen showing **Device ID**.
2. Operator mints a one-time token from an allowlisted host: `curl -sS https://10.88.1.116:8444/mint -H "Authorization: Bearer <SIGNER_ADMIN_TOKEN>" -H "content-type: application/json" -d '{"branch":"<BR>","uuid":"<DEVICE_ID>","ttl_seconds":3600}'`. Branch must be in `/opt/mjbl-enroll/allowlist` else 403. Helper: `/tmp/mjbl_mint.sh` (reads admin token from `/opt/mjbl-enroll/admin_token`, never printed).
3. Give the token to the user (single-use, short-TTL). On tablet: enter branch + token → **Enroll device**. Device generates key+CSR, posts to relay→signer, stores chain.
4. Verify: app login + one business call over mTLS; gateway `/_local/identity` → `verified:SUCCESS` with the exact `<branch>.<DeviceID>.mjbl.internal` CN.

**Claim-QR enrollment** (mass provisioning). (claim-qr-design) Operator portal renders a short-TTL (2–5 min), single-use, auto-rotating QR encoding `{token,branch}`; tablet scans (PR #12 `parseEnrollmentQr` already reads it), self-asserts its UUID in the CSR; signer binds the UUID at first `/sign` and CAS-consumes the token; portal polls `/api/claim/:claimId` (~2.5 s) and advances on `claimed`. Binding flips `(branch,uuid)` → `branch`-only. Keep the per-device `(branch,uuid)` flow as the secure/remote option alongside.

**Flip a branch to mTLS / rollback.** (pilot-runbook §4, §7) "Flip" = distribute the mTLS-on signed APK to that branch's devices; rollback = redistribute the mTLS-off (`MTLS_ENABLED=false`) APK — app reverts to legacy direct-to-LAN, no enrollment needed. Stage: one device → one day → one branch → hold.

**Revoke a device (3 hops — easy to get wrong).** (pilot-runbook §7, device-delivery §6)
1. Vault: `vault write pki/revoke serial_number=<serial>` then `vault read pki/crl/rotate` (it's a **READ** — `vault write …/rotate` returns HTTP 405).
2. CA host (CRITICAL): `/opt/mjbl-demo/scripts/refresh-crl.sh` (pulls Vault's CRL to `:8888` docroot + `/etc/ssl/mjbl/crl-bundle.pem`). Without this the gateway never sees the revocation.
3. Gateway: CronJob rolls nginx ≤15 min, or force `kubectl -n mjbl-mtls-gateway create job --from=cronjob/mjbl-crl-refresh crl-now-$(date +%s)`. `/tmp/mjbl_revoke_device.sh <uuid>` does hops 1+2. New handshakes rejected after the roll; a kept-alive conn isn't re-checked (close/reopen app).

## Gotchas & hard-won lessons
- **`enroll.vte.mjblao.local` is a `.local` name.** Android's resolver may route `.local` to **mDNS/multicast** (version-dependent) and never hit your unicast DNS → enrollment connect fails even though the relay is up. Use the **IP `10.88.101.143`** or the **`enroll.maruhanjapanbanklao.com`** SAN (the relay cert carries both `enroll.vte.mjblao.local` and `enroll.maruhanjapanbanklao.com`) via `--dart-define=MTLS_ENROLL_BASE=…`. Prereq: internal DNS resolves the `.local` name to the relay LB.
- **`MTLS_ENABLED` is build-time, not a runtime switch.** No in-app toggle; "flip" / "rollback" = distribute a different APK.
- **`agenttest.maruhanjapanbanklao.com` is RETIRED** — the gateway server cert SAN is `microloan…` only. Pointing there → `HandshakeException: no alternative certificate subject name matches`. Default is already `microloan`; don't reintroduce `agenttest`.
- **Never bundle a client key / p12 / passphrase / token in the APK or on the NAS.** An APK is a ZIP (`unzip` exposes `assets/` plaintext); a bundled key makes every install the same identity → kills per-device revocation/audit/blast-radius. Only the **public** `root-ca.crt` is bundled.
- **Pin `flutter_secure_storage` at 9.2.x.** Owner fork's v10 drops `encryptedSharedPreferences`, which `mtls.dart` requires.
- **Device id must be dot-free.** The signer's `/revoke` recovers branch via `rsplit('.',1)`; `sanitizeDeviceId()` is the sole client-side guardian once an id could come from an EMM string. Don't weaken the strip.
- **`pki/crl/rotate` is a READ, not a WRITE** (`vault write` → HTTP 405). Forgetting **hop 2** (`refresh-crl.sh`) is the classic revocation miss — the gateway keeps accepting a revoked cert because the `:8888` CRL is static.
- **CN rebuild after renewal:** `_cachedContext` is immutable for the app lifetime; after a re-enroll (new serial, same CN) null it + re-read storage + re-install `HttpOverrides.global` (or restart). Renewal = operator re-enroll (long-press the login version chip → Re-enroll); auto-`/renew` is deferred.
- **Device-serial identity is MDM-gated.** Android 10+ blocks `Build.getSerial()` for a normal app; the only path is an EMM (Miradore/Esper cloud, or Headwind on-prem) injecting the serial via managed-config (`device_serial` key) read by `RestrictionsManager`. App code is deferred; provision the managed-config **before** first enrollment (the write-through cache freezes the id).
- **Firebase rejects a package mismatch** — the app must be registered for `com.agency.mjbl.dev.agency_v2`, not the microloan package; ignore the stray `~/google-services.json` (it's for `com.maruhanjapanbanklao.microloan`).

## Related skills
- `internal-ca` — the 2-tier Vault PKI under everything (Root + Intermediate, roles, CRL, nuke.sh).
- `mtls` — client-cert issuance + NGINX `ssl_verify_client` enforcement (the server side the device authenticates to).
