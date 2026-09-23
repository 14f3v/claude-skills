---
description: Operate the MJBL CRLE lending engine (crle API + cbs_fn SPA) — same-origin serving, AD login failures, the GitOps pipeline and its traps. Wraps the mjbl-crle-platform skill.
argument-hint: "[topic]   e.g. login | deploy | ad | secrets | gateway | ingress | ci | <symptom>"
---

Use the **mjbl-crle-platform** skill for the CRLE application: the Go/Gin API (`crle`) and the
Angular SPA (`cbs_fn`), both in namespace `crle` on prod `rkek8s`, served **same-origin** through
two channels — `http://10.88.101.144:8010` (api-gateway site) and `https://crle.vte.mjblao.local`
(Ingress).

Key reflexes before acting:
- **Login returns HTTP 500 for every failure** in bind → search → re-bind. Read the log line, not
  the status code. `data 52e` = service account; `Referral … uatmjbl.local` = wrong base DN;
  `Entries empty` = username does not exist; `authentication failed` = chain works, bad password.
- **`prod.crle` is auto-sync (prune+selfHeal)**, and the app runs the OD-penalty job **at pod
  startup**. Once `FN_OD_PENALTY_CALC` is granted, any release that restarts the pod charges fees —
  suspend auto-sync first.
- **Never give the SPA its own hostname/IP** — that breaks the same-origin property the app depends
  on (relative URLs + `withCredentials`, against an app advertising `AllowOrigins:["*"]`).
- Gateway `proxy_pass` resolves hostnames at **nginx startup**; the upstream Services must exist
  before the site is applied.

ArgoCD prod writes (sync, app create) are **user-authorized**; reads are fine.

Interpret $ARGUMENTS:
