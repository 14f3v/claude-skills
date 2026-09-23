---
name: mjbl-crle-platform
description: This skill should be used when the user asks about the MJBL CRLE application — "crle", "the lending engine", "Customized Retail Lending Engine", "cbs_fn", "the CRLE frontend", "OD penalty", "penalty-fetch / penalty-prepare / penalty-authorize", "createLoanAccount", "crle.vte.mjblao.local", or "10.88.101.144:8010" — AND for its operational faults — "crle login returns 500", "AD / LDAP bind fails", "LDAP Referral uatmjbl.local", "data 52e", "the SPA shows a blank page", "assets 404", "Oracle connection invalid port", "ImagePullBackOff on crle", or any CI/CD question about the core-banking-mis/crle and mjbl-digital/cbs_fn repos (GHES Actions on k8s-arc, the GITOPS_PAT hand-off, v* release tags). Covers the two-component topology in ns `crle` on prod rkek8s, the same-origin serving model behind the mjbl-api-gateway site and the Ingress, the GitOps pipeline, and every silent-failure trap found while building it.
version: 0.1.0
---

# MJBL CRLE — lending engine (API + SPA)

> Two components, **one namespace**, **one origin**. Built 2026-09-23 as a GitOps+CD
> exercise: a repo with a committed binary, no Dockerfile, no CI and no deployment
> became a released, reconciled workload. Related: `mjbl-k8s-production` (the cluster),
> `mjbl-k8s-facility` (ArgoCD). Manifests: `k8s-config` `deployments/crle/` + `deployments/cbs-fn/`.

## Topology

| | crle (API) | cbs-fn (SPA) |
|---|---|---|
| Repo | `github.vte.mjblao.local/core-banking-mis/crle` | `…/mjbl-digital/cbs_fn` |
| Stack | Go 1.25 / Gin | Angular 21 |
| Image | `containers.github.vte.mjblao.local/core-banking-mis/crle:<tag>` | `…/mjbl-digital/cbs_fn:<tag>` |
| Service | `crle.crle.svc:3000` | `cbs-fn.crle.svc:80` |
| Replicas | **1 — load-bearing** | 2 |
| ArgoCD app | `prod.crle` — **automated** (prune+selfHeal) | `prod.cbs-fn` — register-only |

Both in ns **`crle`** on prod `rkek8s`. Secrets are out-of-band: `crle-env`, `github-pat`
(cloned from any existing ns; all authenticate as `digital`).

## 🚨 Two channels, different jobs

```
Ingress   https://crle.vte.mjblao.local   SPA at /  +  API at /auth,/crle,/health   (UI lives here)
Gateway   http://10.88.101.144:8010       API ONLY  — /auth,/crle,/health; all else 404
```

Every API call in the SPA (`src/app/services/restapi.ts`) is a **relative** URL with
`withCredentials: true`, so the **Ingress must serve both from one origin** — crle sets
`AllowOrigins:["*"]` *with* `AllowCredentials:true`, a pair browsers reject outright for
credentialed requests. **Never give the SPA its own hostname/IP.**

The gateway site served the SPA too until 2026-09-23; it is now API-only by design. Do not
re-add a `location /` there expecting the UI on the VIP.

⚠️ **CORS is LIVE on the gateway channel**, not dormant. With no SPA in that server block, any
browser calling the API there is by definition cross-origin and the fail-closed
`map $http_origin $crle_cors_origin` allowlist decides the outcome. Nothing needs it today
(the SPA calls the API on the Ingress origin), but a browser client pointed at `:8010` must have
its origin added or be refused. Server-to-server callers are unaffected.

`/` has **no Angular route** (`app.routes.ts` leaves the empty path commented out), so the
Ingress redirects it via `nginx.ingress.kubernetes.io/app-root: /home`. A typo like `/dashbord`
still renders blank — that needs a `**` route in the app and cannot be fixed at the edge (the
SPA answers 200 for every path via `try_files`).

## Login (AD) — every failure is an HTTP 500

`POST /auth/login` → service-account bind → user search → re-bind as the user. **All** failures
return 500, so read the log line, not the status:

| Log | Cause |
|---|---|
| `service bind failed … data 52e` | service account wrong — **must be UPN** `crle@vte.mjblao.local`, not bare `crle` |
| `LDAP 10 "Referral" … 'uatmjbl.local'` | wrong base DN compiled in (pre-v0.1.1) |
| `AdService.go:57 … Entries empty` | search OK; **that username does not exist** in `vte.mjblao.local` |
| `authentication failed` | user found, **password** wrong — whole chain works |

Known-good reference is **Rancher's own AD config** against the same server:
`kubectl get authconfigs.management.cattle.io activedirectory` →
`10.88.1.113:389`, tls false, `panda@vte.mjblao.local`, base `dc=vte,dc=mjblao,dc=local`,
`sAMAccountName`.

⚠️ `maker` is **not** a user here — it was the service account for a *different* directory
(`10.92.0.111`) in the old committed `.env`. ⚠️ Never test-bind `panda`: a wrong password
increments AD's lockout counter and breaks Rancher's own login.

**The base DN is compiled in**, so the manifest never tells you what is deployed:

```bash
CID=$(docker create --platform linux/amd64 <image> /noop)
docker export "$CID" | tar -xO app/crle > /tmp/b; docker rm -f "$CID"
strings -a /tmp/b | grep -oE 'DC=[A-Za-z,=]+' | sort -u    # v0.1.1 -> DC=vte,DC=mjblao,DC=local
```

## Secret traps (`crle-env`, 21 keys)

- **dotenv quoting does not survive a Secret.** `AD_SERVICE_ACCOUNT="crle"` in a `.env` is
  stripped by `godotenv` but **not** by Kubernetes — the app bound as the literal 6-char
  `"crle"` → `data 52e`. Store values **unquoted**.
- **`CBS_DB_PASSWORD` is stored PERCENT-ENCODED.** `db/CbsConnection.go` does raw
  `fmt.Sprintf("oracle://%s:%s@%s:%s/%s")`, so a `#` in the password truncates the DSN at the
  URL fragment → `invalid port`. `url.Parse` decodes the escape, so the driver still gets the
  true password. **Do not reuse that value verbatim elsewhere.** Rotating to a URL-safe
  password removes the workaround.
- **`PORT` is pinned in the Deployment `env:`**, which overrides `envFrom`. A blank `PORT`
  panics the process, and the image's `/app/.env` lists it as an empty key.
- The image ships `/app/.env` with **all keys, no values** — three `godotenv.Load()` sites
  panic without the file, one of them a package `init()` (`soap/CBSRTSoapMessage.go:18`).
- ⚠️ The app **logs the DSN** in its fatal error on connect failure → credentials reach Loki.

## 🚨 Startup behaviour that constrains deploys

`services.InitJobSchedule()` runs the **OD-penalty job once at startup**, not at its
`07:00 Mon–Fri` schedule — observed firing at 13:08 on a pod start. With `strategy: Recreate`,
**every pod restart executes a penalty run**. Today it dies on
`PLS-00302: FN_OD_PENALTY_CALC must be declared` (the `REPORTS` account lacks the grant), which
is acting as an accidental safety catch. **Once that grant exists, every auto-synced release
charges fees.** Suspend auto-sync first:

```bash
kubectl -n argocd patch application prod.crle --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

`replicas: 1` is a hard constraint for the same reason (in-process cron + pod-local `scs`
sessions). Never add an HPA. `ConnectOracleCBS()` `log.Fatal`s **before** the listener, so no
Oracle ⇒ CrashLoopBackOff — expected, not a probe-tuning problem.

## CI/CD

Both repos: `verify-artifact`/build → push to GHES Packages → on a `v[0-9]+.[0-9]+.[0-9]+`
tag only, rewrite `deployments/*/production/production.fleet.yaml` in `k8s-config@main`.
A push to `main` publishes `dev-<sha7>` and does **not** promote.

**Use no third-party actions.** All three tried failed differently:
`setup-buildx-action` (65 MB from github.com, silent timeout), `login-action` (unreachable
api.github.com), vendored `build-push-action` (blocked cross-org by `access_level: organization`
— `visibility: internal` is necessary but **not sufficient**). Only appliance-bundled
`actions/checkout` is safe.

Other traps paid for:
- `file(1)` is **not** in `actions-runner-dind` → read the ELF header with `od` instead.
- `DOCKER_BUILDKIT=1` is required — the Dockerfile uses `COPY --chmod` (crle's binary is
  tracked mode 0644) and the legacy builder rejects it.
- npm must come from Nexus (`http://10.88.101.197:8081/repository/npm-proxy/`) with
  `--network=host`; the CI node has no route to npmjs.org.
- **Nexus has no `go` proxy**, which is why crle's binary is committed. `go mod vendor` would
  make an offline source build possible with zero Nexus changes.
- `GITOPS_PAT` is an org secret with **SELECTED** visibility — a new repo must be added to its
  repository list or the gitops job 404s.
- crle is in org `core-banking-mis`, so it needed its **own ARC RunnerDeployment**
  (`tools/arc/runnerdeployment-mjbl-cbmis.yaml`); org runners never cross orgs.
- Registry push uses the **per-run `GITHUB_TOKEN`**, deliberately not a long-lived `GHCR_PAT`.
- The estate's `sed -i "s|image: .*|…|g"` matches **any** line containing `image: `, including
  comments. Anchor on `^[[:space:]]*image:[[:space:]]` and assert exactly one match.
- Tag rulesets: use `rules: [creation, deletion]` only and `bypass_mode: always`. Adding
  `update`/`non_fast_forward` breaks pushes with `fatal error in commit_refs` on GHES 3.15.

## Gateway / Ingress gotchas

- `proxy_pass` with a **static hostname resolves once at nginx startup**. Both `crle` and
  `cbs-fn` Services must exist before the gateway site is applied, or the new pod dies with
  `host not found in upstream`. `maxUnavailable: 0` means old pods keep serving — a **stalled
  rollout, not an outage** — but it blocks every later gateway change.
- Adding a site is a **6-file** change, not the 5 the bundle README used to list: the sixth is
  `map $server_port $site` in `base/00-shared.conf`, or the site logs `site="-"` forever.
- `cert-manager.io/cluster-issuer: mjbl-internal-ca` — **not** `rancher-ca`, which has never
  existed on rkek8s and left a cert `Ready=False` for ~56 days.
- ⚠️ `crle.vte.mjblao.local` needs an **A record → 10.88.101.140**; a hosts entry covers one
  machine only. A `Ready` certificate is not evidence of reachability.

## Verification

```bash
for u in http://10.88.101.144:8010 https://crle.vte.mjblao.local; do
  curl -sk -o /dev/null -w "$u/health -> %{http_code}\n" $u/health          # 200 {"Status":"UP"}
  curl -sk -o /dev/null -w "$u/home   -> %{http_code}\n" $u/home            # 200, SPA
  curl -sk -o /dev/null -w "$u/       -> %{http_code}\n" $u/                # 302 -> /home
done
kubectl -n crle get deploy,svc,ingress
kubectl -n crle logs deploy/crle --tail=40 | grep -E 'Oracle|NewSearchRequest|bind'
```

## Known open items (app-side)

`login-bg.png` referenced by `login.css` but absent from `cbs_fn`; no `**` wildcard route;
`restapi.ts` sets a `Cookie` header (a forbidden header browsers drop — auth actually rides on
`withCredentials`); auth failures return 500 instead of 401; `DEBUG=TRUE` runs zap's
development logger in production.
