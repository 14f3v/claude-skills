---
name: cloudflare-worker-scaffold
description: This skill should be used when the user asks to "start a new Cloudflare Worker project", "scaffold a Worker", "spin up a Hono Worker with local dev", "create a Cloudflare Worker wired for wrangler dev", "set up wrangler local development", "new Cloudflare project with Hyperdrive/Postgres (or D1/KV/R2)", or "bootstrap a Workers repo I can run locally offline". It scaffolds ONE opinionated TypeScript Worker (Hono router, /health + example routes) that is local-development-first, letting the user select any subset of four pre-wired bindings — Hyperdrive+Postgres (with a cloudflared db-tunnel helper and postgres.js example), D1, KV, R2 — each shipped with its wrangler fragment, .dev.vars entries, src/ example, and local-emulation notes. Default generation copies bundled templates instantly and offline (no prompts, no network); an optional --c3 mode runs `npm create cloudflare@latest` first and overlays the same local-dev wiring. Use it whenever the user is standing up a fresh Worker and wants it runnable with `wrangler dev` in three modes (pure-local / cloudflared-proxy+local / --remote), even if they don't name the bindings. For deep Wrangler command reference, Workers best-practice review, Durable Objects, or C3 internals, hand off to the cloudflare:wrangler, cloudflare:workers-best-practices, cloudflare:durable-objects, and cloudflare:cloudflare skills rather than duplicating them here.
version: 0.1.0
---

# Cloudflare Worker scaffold (local-dev-first)

Scaffold an opinionated **TypeScript + [Hono](https://hono.dev) Worker** that runs under `wrangler dev` immediately, with any subset of four selectable, pre-wired bindings. A bundled Node assembler does the file composition deterministically and offline — you invoke it, you don't hand-edit templates.

## Bundled assembler

The reliability core is `scripts/scaffold.mjs` in this skill directory. Run it with Node (v18+; the environment has v22):

```sh
node ~/.claude/skills/cloudflare-worker-scaffold/scripts/scaffold.mjs \
  --name <project-name> \
  --dir <target-dir> \
  --bindings <comma-list | all | none> \
  [--mode bundled|c3] [--compat-date YYYY-MM-DD] [--force]
```

It copies `templates/base/**`, applies `templates/overlays/<binding>/**` for each selected binding, and merges via anchor markers so JSONC/TS stay valid. It is idempotent (skips existing files unless `--force`; merges are dedupe-guarded).

## Procedure

1. **Resolve inputs from the user's request:**
   - **name** — the project/Worker name (kebab-case, e.g. `my-api`).
   - **dir** — target directory. Default to the current directory if it is empty, otherwise `./<name>`.
   - **bindings** — any subset of `hyperdrive`, `d1`, `kv`, `r2` (or `all` / `none`). If the user named a database/Postgres, include `hyperdrive`. If unclear, ask ONE short batched question ("Which bindings — hyperdrive / d1 / kv / r2, any subset, or none?"). If the user said "just scaffold it", default to `none` and move on.
   - **mode** — `bundled` (default) unless the user explicitly wants Cloudflare's C3 generator, then `c3`.

2. **Run the assembler** with the resolved flags (see command above).

3. **Install + generate types**, from the target dir:
   ```sh
   npm install
   npm run cf-typegen        # wrangler types -> worker-configuration.d.ts (binding types)
   ```
   Never hand-write the `Env` interface — it comes from the generated `worker-configuration.d.ts`.

4. **Optional** `git init` (skip if `--no-git`, or the dir is already a repo).

5. **Show the user how to run it** — the three local-dev modes (see `references/local-dev-modes.md`) — and the "create real resources" step for deploy (below). Do NOT run `wrangler login` or create real resources unless the user asks; those touch their account.

## Two generation modes

- **bundled (default):** offline, instant. Base templates + selected overlays are copied and merged. No network, no prompts.
- **`--c3`:** run `npm create cloudflare@latest <name> -- --type=hello-world --lang=ts --no-deploy [--no-git]` first, then `node scaffold.mjs --mode c3 --dir <name> --bindings <list>` overlays the Hono base + local-dev extras onto C3's output and key-merges the binding fragments into C3's `wrangler.jsonc` without clobbering it. See `references/c3-overlay.md`.

## The four bindings

| Binding | wrangler key | Env name | Example route | Extra |
|---|---|---|---|---|
| Hyperdrive + Postgres | `hyperdrive` | `HYPERDRIVE` | `/db` (postgres.js) | `scripts/db-tunnel.sh`, `localConnectionString` |
| D1 (SQLite) | `d1_databases` | `DB` | `/d1` | `migrations/0000_init.sql` |
| KV | `kv_namespaces` | `KV` | `/kv/:key` | — |
| R2 | `r2_buckets` | `BUCKET` | `/r2/:key` | — |

Binding IDs are `<PLACEHOLDER>` until the user creates real resources. Deep per-binding notes: `references/bindings.md`.

## Three local-dev modes (summarize for the user)

1. **Pure local** — `npm run dev` (`wrangler dev`): KV/R2/D1 emulated by Miniflare (`.wrangler/state`); Hyperdrive uses `localConnectionString` to reach a DB your machine can reach.
2. **cloudflared proxy + local** — for a private Postgres behind a Cloudflare Tunnel: `./scripts/db-tunnel.sh --hostname db.example.com` exposes it at `localhost:5432`, then `npm run dev`.
3. **Remote** — `npm run dev:remote` (`wrangler dev --remote`): runs on the edge using real bindings (Hyperdrive → VPC/tunnel → private DB); no local proxy. Uses live data.

Full explanation: `references/local-dev-modes.md`.

## Deploy (only when the user asks)

Create the real resources, paste the returned IDs over the `<...>` placeholders in `wrangler.jsonc`, then `npm run cf-typegen` and `npm run deploy`:

```sh
npx wrangler login
npx wrangler kv namespace create KV
npx wrangler d1 create <name>-db
npx wrangler r2 bucket create <name>-bucket
npx wrangler hyperdrive create <name>-hd --connection-string="postgres://user:pass@host:5432/db"
```

## Handoffs (don't duplicate these)

- **Wrangler commands / flags / config fields** → `cloudflare:wrangler`
- **Reviewing generated Worker code vs. production rules** → `cloudflare:workers-best-practices`
- **Durable Objects, Queues, Workflows, AI/Vectorize** (intentionally out of scope here) → `cloudflare:durable-objects` / `cloudflare:cloudflare`
- **C3 internals, custom templates** → `cloudflare:cloudflare` (`references/c3/*`)
- **Hyperdrive deep dive** (`localConnectionString`, private-DB-via-tunnel, connection limits) → `cloudflare:cloudflare` (`references/hyperdrive/*`)

## Notes / gotchas

- **Markers are load-bearing.** The assembler fails cleanly if `/* @scaffold:bindings */` (wrangler.jsonc), `// @scaffold:imports`, or `// @scaffold:routes` (src/index.ts) are missing from the base templates. If Node is unavailable, splice the overlay fragments manually at those markers.
- **`.dev.vars` is never committed** — `.gitignore` lists it; only `.dev.vars.example` ships. Put local secrets (and any `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_*` override) in `.dev.vars`.
- **`compatibility_date`** is stamped to today at scaffold time; re-check against `cloudflare:wrangler` if Cloudflare ships changes.
- **macOS-safe:** `db-tunnel.sh` avoids GNU-only tools (`timeout`); the assembler is Node (portable).
