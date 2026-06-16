---
description: Build, enroll, distribute, or claim-QR the agency_v2 device app. Wraps the mjbl-client-provisioning skill (MJBL mTLS platform).
argument-hint: "[task]  e.g. build-apk | enroll | distribute | claim-qr"
---

Use the **mjbl-client-provisioning** skill as the authoritative source for the agency_v2 / microloan Flutter device client on the MJBL mTLS platform. The skill indexes the runbooks under `/home/mjbl/*` (this host is the mTLS remote runner) — treat those as the source of truth.

Context from $ARGUMENTS: interpret the task —
- `build-apk` / `release` → cut the signed mTLS-on APK (`android-apk-release.yml`; tag `v*` or workflow_dispatch; `MTLS_ENABLED=true` enforced) — see `/home/mjbl/mjbl-agency-v2-pilot-runbook.md` §1.
- `enroll` → the Device-ID → mint one-time token → branch+token → on-device CSR → signed chain flow — pilot-runbook §2 + `/home/mjbl/mjbl-device-delivery-runbook.md`.
- `distribute` → Firebase App Distribution (project `mjbl-inhouse`, tester group `pilot`) — `/home/mjbl/mjbl-agency-v2-firebase-app-distribution-runbook.md`.
- `claim-qr` → the rotating-QR mass-provisioning flow — `/home/mjbl/mjbl-claim-qr-enrollment-design.md`.
- a DNS / handshake symptom → the `.local`→mDNS gotcha (use IP `10.88.101.143` or the `enroll.maruhanjapanbanklao.com` SAN).
If empty, summarize the skill (build flags, Model-A enrollment, release+distribute, claim-QR, the .local/Android gotchas) and ask which task they need.

Read the specific /home/mjbl runbook the skill points to BEFORE executing any prod-touching step, and respect the prod gates: CA-host changes go via `! ssh ca`, k8s-config merges are user-gated, ArgoCD prod writes are user-gated/denied to the agent. Validate app changes locally first: `export PATH=/home/mjbl/flutter-sdk/bin:$PATH; flutter analyze && flutter test` in `/home/mjbl/agency_v2`.

RULES: be accurate — VERIFY facts against the actual source docs (Read them; grep `/home/mjbl/agency_v2/lib/services/mtls.dart` and `.github/workflows/`). Do NOT invent IPs/paths/service names/App IDs. Use the exact figures from the runbooks (`MTLS_ENABLED` default false, enroll relay `10.88.101.143:8443`, gateway `microloan.maruhanjapanbanklao.com:2399`, App ID `1:718049361610:android:…`, fss pinned 9.2.x). Never bundle a client key/p12/passphrase in the APK; only the public `root-ca.crt`.
