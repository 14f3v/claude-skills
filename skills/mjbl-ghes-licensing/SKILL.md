---
name: mjbl-ghes-licensing
description: This skill should be used when the user asks to extend, inspect, or replace the licence on the MJBL GitHub Enterprise Server appliance — "extend the GHES seats", "add a seat", "we bought another seat", "apply the new .ghl", "import the licence file", "how many GitHub seats are left", "are we at the seat limit", "who is consuming a seat", "which .ghl file is actually active", "when does the GitHub Enterprise licence expire", "the new staff account can't be created, no seats", "I uploaded the licence but nothing changed", "prove the licence change actually landed", "roll back a licence", or any licence, seat-count, seat-audit, or .ghl-import operation on the GHES appliance github.vte.mjblao.local (10.88.101.37, GHES 3.15.2, single node, admin over port 122). Covers the ghe-license CLI and its non-mutating dry run, the ghe-github-restart apply path, live seat accounting via ghe-console, and the rollback posture. Scoped deliberately to licensing and seats — appliance upgrades, backup/restore, ghe-config-apply, TLS renewal, Actions, LDAP and HA are OUT of scope and belong in a future mjbl-ghes-appliance skill.
version: 0.1.0
---

# MJBL GHES Licensing — seats / .ghl import / apply / verify

> **Knowledge base / truth-of-source.** There is no `/home/mjbl` runbook for GHES — **the appliance is the source of truth**, and every number below was measured live on **2026-09-22** with the command printed beside it. Re-measure before acting; do not quote this file as current state. Authoritative surfaces, in precedence order:
> - `ssh ghes -- ghe-license info -j` — the **active** licence. The only place `reference_number` exists.
> - `cat cand.ghl | ssh ghes -- ghe-license info --pipe -j` — a **candidate** file, without importing it. This is the dry run, and it is proven non-mutating (see §Gotchas).
> - `ssh ghes -- ghe-console -y` → `GitHub::Enterprise.license` — **live seat consumption**. `seats_used` is the only correct seat number.
> - `ssh ghes -- nomad job status github-unicorn` — whether the app was actually restarted. **Not `systemctl`.**
> - `https://github.com/enterprises/maruhan-japan-bank-lao/metered_server_licenses/<reference>` — what was purchased, and when.
>
> **The import/apply path was executed once here, on 2026-09-22 (8→9 seats).** Everything downstream of it — rollback, a failed import, `--skip-checks` — is documented from the CLI surface and has **never been run on this appliance**. Those steps carry an explicit ⚠️ NOT REHEARSED marker.

## When to use
- **"Extend the seats" / "we bought a seat" / "add a user but there are no seats"** — the full purchase → identify → back up → check → `import --pipe --apply` → verify cycle (procedure A). The 8→9 change of 2026-09-22 is the worked example.
- **⚠️ "Onboarding is blocked."** Measured 2026-09-22: **9 seats, 9 used, 0 available, `reached_seat_limit? == true`.** There is **zero headroom** — the next account creation fails until a seat is bought or freed. Buy *before* creating the account.
- **"How many seats are left / who is using them?"** — procedure B. Never answer this by counting `User` rows; see the `ghost` gotcha.
- **"Which .ghl is this?"** — two look-alike files sit in `~/Downloads`; only `info --pipe -j` and the download-origin xattr tell them apart.
- **"I uploaded the licence but nothing changed."** → almost always `import` without `--apply`. Gotcha 1.
- **"Did the licence change actually land?"** — the forensic recipe (procedure D): active-file sha256, Nomad submit dates, unicorn process start, `/status`.
- **"When does it expire?"** — `expire_at` / `days_until_expiration`. A seat purchase **resets** the term, so old alarms go stale.
- **"Roll it back."** — ⚠️ NOT REHEARSED. Read both warnings in procedure A step 9 first.
- **NOT for** — appliance upgrades, `ghe-config-apply`, backup/restore, the TLS certificate, Actions runners, LDAP/AD, cluster/HA. See `## Related skills`.

## Architecture / live facts (measured 2026-09-22)
- **Appliance:** GHES **3.15.2**, platform `esx`, built **2025-01-17**, build `8c7559955e`. `github.vte.mjblao.local` = **10.88.101.37** — the **facility /24**, same segment as facility nodes `.35`/`.36`/`.38` and the ingress VIP `.190`.
- **Access — direct, no jump host:** `ssh ghes`. The `~/.ssh/config` alias supplies port **122**, user **admin**, IdentityFile `~/.ssh/personel/id_ed25519`, and **no `ProxyJump`**. ⚠️ Unusual in this estate — the CA host has no local alias and needs `! ssh ca`. Every command here is `ssh ghes -- <cmd>` or `cat file.ghl | ssh ghes -- <cmd> --pipe`.
- **Single node — no cluster, no replica:** `cluster.enabled` unset; `ghe-repl-status` → *"Replication is not configured"*. Three consequences: `ghe-license sync` is a **no-op**; there is **no replica to re-licence**; and `ghe-github-restart` takes its **non-cluster branch** (`/etc/github/cluster` does not exist, so no `ghe-cluster-each`). There is also **no rolling window** — `--apply` restarts the whole application.
- **The app runs under Nomad, not systemd.** `systemctl` shows only `github-enterprise.target`. `nomad job status` lists `github-unicorn`, `github-resqued`, `github-env`, `github-ernicorn`, `github-gitauth`, `github-timerd`, `github-stream-processors`, and more. **Restart evidence lives in Nomad job Submit Dates.**
- **Disk / uptime:** `/data/user` **196G, 65G used (35%)**; host uptime **183 days**. The import writes into `/data/user/common/`.
- **TLS (context only — out of scope to change):** issued by **MJBL Intermediate CA**, CN `github.vte.mjblao.local`, **17 SANs** (`assets` `avatars` `codeload` `containers` `docker` `gist` `maven` `media` `notebooks` `npm` `nuget` `pages` `raw` `rubygems` `uploads` `viewscreen` + apex), valid **2026-08-11 → 2027-08-11**. ⚠️ **NOT expired** — a stale note claimed 2026-09-16; that note is wrong. Cert work belongs to `mjbl-ca-operations`.

### The active licence
| field | value | source |
|---|---|---|
| active file | `/data/user/common/enterprise.ghl` | documented `ghe-license` fallback |
| sha256 | `f507adce735ee632b5765f8ad497c8e638327ec939714f416634a80e299cb7b0` | byte-identical to local `github-enterprise-2f9d9a.ghl` |
| `reference_number` | `2f9d9a` | `ghe-license info -j` |
| `seats` | **9** — `seats_used` **9**, `seats_available` **0** | |
| `expire_at` | `2027-09-22T11:12:41+07:00` (`days_until_expiration` 365, `expired?` false, `valid?` true) | |
| `company` | `MARUHAN JAPAN BANK LAOS` | |
| `metered` / `perpetual` / `unlimited_seating` | **true** / false / false | |
| `advanced_security_enabled` / `_seats` | true / **0** | GHAS on, zero seats |
| `sync_with_global_business` | **true** | metered usage reports to github.com |

### The two candidate files in `~/Downloads`
| file | `reference_number` | seats | `expire_at` | downloaded |
|---|---|---|---|---|
| `github-enterprise-27dcd8.ghl` | `27dcd8` | **8** | `2027-08-20T10:21:39+07:00` | 2026-09-22 09:55 |
| `github-enterprise-2f9d9a.ghl` | `2f9d9a` | **9** | `2027-09-22T11:12:41+07:00` | 2026-09-22 11:12 |

Every other field is identical, so **only `reference_number`, `seats` and `expire_at` distinguish them**. Both are ~32 KB of opaque binary — `file` says `data`, `strings` is noise.

**Three-way identity rule:** `reference_number` == last path segment of the download URL == the filename suffix. `github-enterprise-2f9d9a.ghl` ⇄ `…/metered_server_licenses/2f9d9a` ⇄ `"reference_number":"2f9d9a"`.

**Derived (inference, not measured):** on a metered licence the term is one year from purchase, so **purchase date = `expire_at` − 1 year**. `27dcd8` → 2026-08-20, `2f9d9a` → 2026-09-22. That reconstructs a purchase history from the files alone — and it matches the account-creation dates below.

### Seat census — 9/9, zero headroom
22 user rows, 6 orgs. Seat-consuming (non-suspended, type `User`, excluding `ghost`):

| login | created | notes |
|---|---|---|
| `anatsayap` | 2026-08-20 | |
| `athanaml` | 2026-02-05 | site-admin; **in no org** |
| `digital` | 2026-08-20 | site-admin, service account |
| `khemphets` | 2026-02-05 | site-admin |
| `kiewlamphones` | **2026-09-22** | **the user the 9th seat was bought for**; belongs to `core-banking-mis`, in no org as of 2026-09-22 |
| `laithongs` | 2026-04-20 | |
| `phetsamones` | 2026-08-20 | |
| `phoutthakoneb` | 2026-02-05 | |
| `thidavonem` | 2026-04-09 | |
| `actions-admin` | — | **suspended — consumes nothing** |
| `VilasakCth` | — | **suspended — consumes nothing** |
| `ghost` | — | **never consumes** |

Orgs: `mjbl-digital` (58 repos, 8 members), `core-banking-mis` (5, 3), `actions` (19, 1), `github` (2, 1), `elysiajs` (0, 1), `github-enterprise` (0, 0). Note three accounts created 2026-08-20 against licence `27dcd8` purchased 2026-08-20 — **seat purchases track onboarding dates**.

### The `ghe-license` surface (verbatim, GHES 3.15.2)
```
Usage: [environment-variable] ghe-license [command] [--additional-params]
  GHE_LICENSE_FILE       provide a license via env var
  --pipe                 pipe the license to the script
  import                 Run a license check and import the license.
    --apply                ...you still need to apply the license. --apply consecutively runs
                           ghe-github-restart which restarts the github application
    --skip-checks
  sync                   Synchronize the license to other nodes if existing
  check                  Check license
  info                   Display license information.   -j|--json
  usage                  Display license usage.          -y (no confirm)  -o (stdout)
Falls back to the active license at /data/user/common/enterprise.ghl when no file is given.
Example: cat license.ghl | ssh -p 122 admin@[hostname] -- ghe-license import --pipe
```
Read the `--apply` line literally — **`import` alone does not apply.** Only `import` mutates; `info` and `check` are read-only and both accept `--pipe` / `GHE_LICENSE_FILE`.

### What `--apply` actually runs — `ghe-github-restart`
Read from `/usr/local/bin/ghe-github-restart` on 2026-09-22 — **1019 bytes, dated Jan 17 2025**, the same date as the 3.15.2 build, so it is **stock and unmodified** (a cheap tripwire: re-check size/date after any upgrade). In order it:
1. **Refuses to run** if `ghe-config-in-progress` is not `false` — *"Currently the config-apply process is running."*
2. Runs `ghe-license check`, then `ghe-license sync` (no-op here).
3. `ghe-call-configrb nomad_render_jobs github` + `nomad_run_github_jobs` (cluster-aware only if `/etc/github/cluster` exists — it does not).
4. `sleep 20`, then `ghe-nomad-jobs wait-health-checks`.

Its own header: *"Use this script for example after applying a new license, **to avoid bigger license file upload disruptions**."* It is a **targeted Nomad job re-render, NOT a full `ghe-config-apply`** — deliberately the lighter path. It still replaces every `github-*` job, so expect a short rolling interruption. ⚠️ Lower bound ~20–40 s from the `sleep 20` + health wait; **the user-visible gap was never measured** — do not quote a number.

## Key procedures

**A. Extend the seat count** (the 8→9 change, 2026-09-22). ⚠️ Steps 1–5 and 8 are read-only. **Step 6 mutates production and restarts the GitHub application** — it is **user-authorized, never agent-initiated**.

1. **Purchase** at `https://github.com/enterprises/maruhan-japan-bank-lao/` → GitHub mints a **new** licence with a **new `reference_number` and a new `expire_at`**; the term restarts at purchase, it does not inherit the old expiry.
2. **Download** to `~/Downloads/github-enterprise-<ref>.ghl`.
3. **Identify every candidate before touching the appliance** — the dry run:
   ```bash
   for f in ~/Downloads/github-enterprise-*.ghl; do
     printf '\n== %s\n' "$f"
     mdls -name kMDItemWhereFroms "$f"
     cat "$f" | ssh ghes -- ghe-license info --pipe -j | jq '{reference_number, seats, expire_at}'
   done
   ```
   **Pick by `seats`, never by mtime or filename alone.** `mdls -name kMDItemWhereFroms` recovers the download URL from the macOS Spotlight xattr — invisible in Finder, and how the two files were told apart before either was piped anywhere.
4. **Back up the OUTGOING licence — it is your only rollback artifact:**
   ```bash
   mkdir -p ~/ghes-license-backups
   ssh ghes -- ghe-license info -j | jq '{reference_number, seats, expire_at}'
   ssh ghes -- sha256sum /data/user/common/enterprise.ghl
   ssh ghes -- cat /data/user/common/enterprise.ghl > ~/ghes-license-backups/enterprise-$(date +%Y%m%d-%H%M)-pre.ghl
   shasum -a 256 ~/ghes-license-backups/enterprise-*-pre.ghl   # MUST equal the appliance sha256
   ```
   ⚠️ **`~/Downloads` is not a backup** — it is user-cleanable and machine-local. The only reason a rollback is possible today is that `27dcd8` happens to still be sitting there. Snapshot the pre-change seat state (procedure B) in the same breath.
5. **Preflight + check** (read-only):
   ```bash
   ssh ghes -- /usr/local/share/enterprise/ghe-config-in-progress      # MUST print false
   cat ~/Downloads/github-enterprise-<ref>.ghl | ssh ghes -- ghe-license check --pipe   # "License is valid."
   ```
   ⚠️ `check` validates the **file**, not the **decision** — see gotcha 2. Never reach for `--skip-checks` to get past a failure.
6. **Import and apply** (the production step):
   ```bash
   cat ~/Downloads/github-enterprise-<ref>.ghl | ssh ghes -- ghe-license import --pipe --apply
   ```
7. **Verify — five checks, all read-only.** Reference values are the measured 2026-09-22 results:

   | # | command | expected |
   |---|---|---|
   | 1 | `ssh ghes -- ghe-license info -j \| jq '{reference_number,seats,expire_at}'` | `2f9d9a` / `9` / `2027-09-22T11:12:41+07:00` |
   | 2 | `ssh ghes -- sha256sum /data/user/common/enterprise.ghl` | `f507adce…9cb7b0` — byte-identical to the file you piped |
   | 3 | `ssh ghes -- nomad job status github-unicorn \| head -20` | Submit Date **after** the import (`2026-09-22T04:13:42Z`), version bumped (10→**11**), alloc `60a8b72f` running/healthy, prior alloc stopped, Latest Deployment **successful** |
   | 4 | `ssh ghes -- curl -sk https://localhost/status` | **200** `GitHub lives!` |
   | 5 | procedure B | `seats=9 used=9 available=0 reached_seat_limit?=true` |

   Check 3 is the one people skip and the only one that proves the restart happened. ⚠️ `curl -sk` needs `-k` because **`localhost` is not one of the 17 SANs** — expected, not a cert fault.
8. **Finish the job — create the account AND add it to the RIGHT org.** A seat buys an account, not access. Measured 2026-09-22: `kiewlamphones` consumed the 9th seat while belonging to **no organization** and holding **no pending invitation** anywhere — a paid seat with access to nothing. ⚠️ **Ask which org; do not infer it.** The obvious guess was `mjbl-digital` (58 repos, the largest); the correct answer was `core-banking-mis` (5 repos). Org membership is a per-person access decision, not a default. Invite via `https://github.vte.mjblao.local/orgs/<org>/people`. ⚠️ `ghe-org-membership-update` is **not** this tool — it bulk-sets membership *visibility* (public/private) installation-wide.
9. **Rollback — ⚠️ NOT REHEARSED. Read both warnings.**
   ```bash
   cat ~/ghes-license-backups/enterprise-<ts>-pre.ghl | ssh ghes -- ghe-license info --pipe -j   # confirm it is the OLD one
   cat ~/ghes-license-backups/enterprise-<ts>-pre.ghl | ssh ghes -- ghe-license import --pipe --apply
   ```
   ⚠️ Rolling 9→8 while 9 accounts consume seats leaves the instance **over its limit** — GHES does not delete users to fit. Suspend the newest account first. ⚠️ Rollback also rolls the **expiry** back (2027-09-22 → 2027-08-20). The over-limit behaviour here is **untested**.

**B. Seat audit — who consumes a seat.** `ghe-console` is a **live production Rails console**; `-y` skips its confirmation. Keep every snippet read-only — nothing in this skill needs a write.
```bash
ssh ghes -- ghe-console -y <<'RUBY'
l = GitHub::Enterprise.license
puts({seats: l.seats, used: l.seats_used, available: l.seats_available,
      at_limit: l.reached_seat_limit?, close: l.close_to_seat_limit?,
      expires: l.expire_at, days: l.days_until_expiration, metered: l.metered?}.inspect)
RUBY
```
Useful methods on `GitHub::Enterprise.license`: `seats`, `seats_used`, `seats_available`, `reached_seat_limit?`, `close_to_seat_limit?`, `readable_seats`, `readable_seats_available`, `expire_at`, `days_until_expiration`, `expired?`, `metered?`, `perpetual?`, `valid?`, `unlimited?`, `has_seat_limit?`, `reload!`, `license_data`, `sync_with_global_business`.

**C. Which licence is active right now.** `ghe-license info -j` for identity; `sha256sum /data/user/common/enterprise.ghl` against your local candidates for byte identity. The sha is the only proof a *specific local file* is the live one.

**D. Prove a past change landed (the forensic recipe).** Timeline below is **reconstructed from evidence, not observed live**:

| time (UTC) | evidence |
|---|---|
| 04:12:59 | `2f9d9a` downloaded (`kMDItemWhereFroms` + creation date) |
| 04:13:17 | `enterprise.ghl` mtime; sha256 matches the local `2f9d9a` → that file is now active |
| 04:13:38–04:13:42 | `github-env`, `github-resqued`, `github-timerd`, `github-stream-processors`, `github-ernicorn`, `github-gitauth`, `github-unicorn` all re-submitted → the apply half ran |
| 04:13:42 | `github-unicorn` v**11**, alloc `60a8b72f` healthy, prior v10 stopped, deployment successful; new `unicorn master -c config/unicorn.rb` process start |
| 04:22:11 | `kiewlamphones` created — 9 min after the apply |
| after | `curl -sk https://localhost/status` → **200 "GitHub lives!"** |

⚠️ The ~21 s gap between file write and job re-submission is **consistent with `--apply`** but does not prove it — a hand-run `ghe-github-restart` looks identical. Treat the mechanism as inferred.

**E. Metered usage report.** `ssh ghes -- ghe-license usage -o -y` emits JSON — `instance{server_id, host_name, version, public_key, features[]}` plus an **encrypted base64 `users` blob** (not locally readable; it is the artifact you would send to GitHub). `features` includes `license_usage_sync`, `contributions`, `search`, `private_search`, `content_analysis`, `actions_download_archive`.

## Gotchas & hard-won lessons
- **`ghe-license import` without `--apply` does NOT change the running application.** Evidence: the CLI's own text — *"you still need to apply the license."* Fix: always pass `--apply`, or run `ghe-github-restart` afterwards, and verify with the **Nomad Submit Date**, not the file mtime. (Cost: a licence that passes every file-level check while every seat check still enforces the old count.)
- **⚠️ `check` says "License is valid." for a DOWNGRADE.** Proven 2026-09-22: piping the **8-seat** `27dcd8` at a 9-seat appliance returned `License is valid.` — `check` validates the file's signature and form, **not whether applying it is a good idea**. Fix: gate on `seats` from `info --pipe -j`, never on `check` alone. (Cost: importing the wrong look-alike file would silently downgrade the appliance and lock out the user the seat was bought for.)
- **The dry run is genuinely non-mutating — proven, so trust it.** Same test, before/after: `enterprise.ghl` sha256 `f507adce…` and mtime `04:13:17` unchanged, `github-unicorn` Submit Date unchanged, `info -j` still `2f9d9a`/9 seats. Fix: always `info --pipe -j` every candidate before importing; it costs nothing and is the only way to tell two `.ghl` files apart.
- **⚠️ The appliance keeps NO backup of the licence you replace.** Measured: `/data/user/common/enterprise.ghl` is the **only** `.ghl` on the box, overwritten in place. Fix: back it up to `~/ghes-license-backups/` *before* the import. (Cost: today the sole copy of the outgoing 8-seat `27dcd8` sits in `~/Downloads`, one `rm` from unrecoverable — and a failed import is untested, so whether it leaves the old file intact is **unknown**.)
- **systemd is the wrong place to look for restart evidence.** `systemctl` shows only `github-enterprise.target`; the app is a set of Nomad jobs. Fix: `nomad job status github-unicorn` — Submit Date, version, alloc health, "Latest Deployment successful". (Cost: a long detour hunting a unit file that does not exist, and a near-miss conclusion that the restart never happened.)
- **`ps | grep "unicorn master"` is ambiguous and will fool you.** A long-lived `unicorn master --env production` from **2026-03-22** (183-day uptime, a different service) sits alongside the app's `unicorn master -c config/unicorn.rb`. Sorting by start time puts the March one first and hides the new one behind `head`. Fix: match on the `-c config/unicorn.rb` form, or skip `ps` and use Nomad.
- **Rails console API traps.** `GitHub::Enterprise.license` has **no `reference_number`** (that field exists only in `ghe-license info -j`), and **`GitHub::Enterprise.seats_used` does not exist** — it is `GitHub::Enterprise.license.seats_used`. Both raised `NoMethodError` on first use. (Cost: two NoMethodErrors typed straight into a production console.)
- **Counting users ≠ counting seats — the naive query is off by one.** `User.where(type:'User').where(suspended_at: nil).count` → **10** while `license.seats_used` → **9**, because `ghost` is a real row. Fix: quote `license.seats_used` and nothing else; if you must enumerate, exclude `ghost` **and** suspended accounts. (Cost: a report that declares you over the limit when you are exactly at it — and a seat purchase you did not need.)
- **`ghe-config-in-progress` is NOT on `$PATH`.** `command -v` finds nothing; the real path is `/usr/local/share/enterprise/ghe-config-in-progress` (returns `false` when idle). Fix: call it by full path. (Cost: a preflight that silently "passes" because the command was not found.)
- **`--apply` is refused outright while a config-apply is in flight** — `ghe-github-restart`'s first guard aborts with *"Currently the config-apply process is running."* Fix: check first; if one is running, **wait** — do not kill it to force the licence through. (Cost: an import that appears to succeed with no restart, i.e. gotcha 1.)
- **Buying a seat mints a new reference AND resets the expiry.** `27dcd8` → 2027-08-20; `2f9d9a` → 2027-09-22. Fix: update expiry alarms after every purchase, and remember a rollback rolls the expiry back too. (Cost: an expiry monitor a month out of date.)
- **Buying the seat is not the finish line — and the org is not guessable.** `kiewlamphones` consumed the 9th seat while in **zero orgs** with **zero pending invitations** — a paid seat with access to nothing. Worse, the obvious inference was wrong: the largest org `mjbl-digital` (58 repos) was **not** where they belonged; `core-banking-mis` (5 repos) was. Fix: create the account, **ask the requester which org**, add them there, then re-check `seats_used` (org membership consumes no extra seat). (Cost: nearly granting a new starter access to 58 repos across the wrong business domain.)
- **⚠️ You are at 9/9 with zero available, and seats are a RECURRING cost.** `seats_available=0`, `reached_seat_limit?=true`, licence `metered: true` with `sync_with_global_business: true`, monthly receipts on file for 2026-08-03 and 2026-09-01. Fix: buy *before* creating the account, or free one by suspending an inactive user (suspension consumes nothing — two suspended accounts sit outside the 9 today). Do not over-provision "for headroom" — an idle seat bills every month.
- **`ghe-license sync` is a no-op here, but do not delete it from the procedure.** Single node, replication not configured. It becomes real the day an HA replica exists, and `ghe-github-restart` calls it.
- **Never paste a `.ghl` anywhere.** It is not a credential, but it is a purchased artifact identifying the enterprise. Quote the **JSON fields**, never the file bytes.
- **Everything here is true of GHES 3.15.2.** `ghe-license` flags and `ghe-github-restart`'s body can change across upgrades — re-check `ls -l /usr/local/bin/ghe-github-restart` (1019 bytes, Jan 17 2025) as a stock-script tripwire after any upgrade.

## Related skills
- **`mjbl-k8s-facility`** — same `10.88.101.0/24` segment. The `k8s-config` repo that facility ArgoCD syncs is hosted **on this appliance**, so a GHES outage during a licence apply stalls GitOps.
- **`mjbl-operator-portal`** — pulls its prod image from the GHES container-registry mirror `containers.github.vte.mjblao.local/mjbl-digital/…` (one of the 17 SANs).
- **`mjbl-ca-operations`** — owns the **MJBL Intermediate CA** that issued this appliance's TLS cert. All certificate work belongs there, not here.
- **Deliberate gap:** there is **no general GHES appliance skill**. Backup/restore, upgrades, `ghe-config-apply`, Actions, LDAP and HA are unowned — if they come up, create `mjbl-ghes-appliance` rather than growing this file. The `/mjbl:ghes:*` namespace is reserved for exactly that.
