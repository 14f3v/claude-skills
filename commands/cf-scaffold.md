---
description: Scaffold an opinionated, local-dev-first Cloudflare Worker (TypeScript + Hono) with selectable pre-wired bindings (Hyperdrive+Postgres / D1 / KV / R2). Wraps the cloudflare-worker-scaffold skill.
argument-hint: "[--name <n>] [--dir <path>] [--bindings hyperdrive,d1,kv,r2|all|none] [--c3] [--git] [--force]"
---
Use the **cloudflare-worker-scaffold** skill to scaffold a new Cloudflare Worker.

Interpret `$ARGUMENTS` as flags for the skill's assembler (`scripts/scaffold.mjs`):
- `--name <n>` — project/Worker name (kebab-case). If omitted, ask or infer from the target dir.
- `--dir <path>` — target directory (default: current dir if empty, else `./<name>`).
- `--bindings <list>` — any subset of `hyperdrive,d1,kv,r2`, or `all` / `none`. If a database/Postgres is mentioned, include `hyperdrive`.
- `--c3` — bootstrap with `npm create cloudflare@latest` first, then overlay (default is bundled/offline).
- `--git` — run `git init` after scaffolding.
- `--force` — overwrite existing files.

After scaffolding: `npm install`, `npm run cf-typegen`, then show the three local-dev run modes. Do not run `wrangler login` or create real Cloudflare resources unless the user asks.
