---
description: Operate GHES licensing on github.vte.mjblao.local — seat extension, .ghl import + apply, seat audit, and proving a licence change landed. Wraps the mjbl-ghes-licensing skill.
argument-hint: "[task]  e.g. seats | which-file | extend | verify | expiry | rollback"
---

Use the **mjbl-ghes-licensing** skill as the authoritative source for licence and seat operations on the MJBL GitHub Enterprise Server appliance — `github.vte.mjblao.local` (**10.88.101.37**, GHES **3.15.2**, single node, no HA replica, services under **Nomad**). Access is direct: `ssh ghes` (alias → port **122**, user `admin`, `~/.ssh/personel/id_ed25519`) — **no jump host**, unlike the CA host. The appliance is the source of truth; every figure in the skill is stamped **Measured 2026-09-22** and must be re-measured before you act on it.

Interpret $ARGUMENTS:
- `seats` / `how many left` / `audit` → `ssh ghes -- ghe-console -y` → `GitHub::Enterprise.license` for `seats / seats_used / seats_available / reached_seat_limit?`. Measured 2026-09-22 it is **9/9, zero available**. Never count users with a raw `User.where(...)` — `ghost` makes it 10.
- `which-file` / `identify` → the **dry run**: `cat cand.ghl | ssh ghes -- ghe-license info --pipe -j` prints that file's `reference_number`/`seats`/`expire_at` **without importing** (proven non-mutating). Pair with `mdls -name kMDItemWhereFroms` to recover the download URL. `reference_number` == URL last segment == filename suffix.
- `extend` / `add a seat` / `import` → procedure A: purchase → download → identify → **back up the outgoing `/data/user/common/enterprise.ghl`** → `ghe-license check --pipe` → `ghe-license import --pipe --apply` → the five verification checks → **add the account to its org**. ⚠️ `check` passes a DOWNGRADE as "License is valid." — gate on `seats`, not on `check`.
- `verify` / `did it land` → `ghe-license info -j`, the `enterprise.ghl` sha256, **`nomad job status github-unicorn`** (Submit Date / version / deployment — *not* `systemctl`), `curl -sk https://localhost/status` → 200 `GitHub lives!`, and `seats_used`.
- `expiry` → `expire_at` / `days_until_expiration`. Currently **2027-09-22**. A seat purchase **resets** the term, so old alarms go stale.
- `rollback` → re-import the backed-up previous `.ghl` with `--apply`. ⚠️ **NOT REHEARSED**, and 9→8 leaves the instance over its limit unless the newest account is suspended first. Surface both warnings before running anything.

If empty, summarize the skill's "Architecture / live facts" — the appliance (3.15.2, `esx`, 10.88.101.37, single node, Nomad-managed), the active licence (`2f9d9a`, 9 seats, expires 2027-09-22, metered), and the 9/9 seat position — then ask which task they need.

Read the skill's procedure end to end BEFORE any appliance-touching step, and respect the prod gates: steps 1–5 and every verification are read-only and free; **`ghe-license import --apply` restarts the production GitHub application and is user-authorized, never agent-initiated** — there is no replica and no rolling window on this single node. Take the outgoing-licence backup *before* the import — the appliance keeps none, so it is the only rollback artifact. Keep `ghe-console` snippets read-only; it is a live Rails console on production and `-y` skips the confirmation prompt. Never reach for `--skip-checks` to get past a failing `check`. Licensing and seats only — appliance upgrades, backup/restore, `ghe-config-apply`, TLS renewal, Actions and LDAP are out of scope; certificate work belongs to `mjbl-ca-operations`.
