# Bindings reference

Each overlay ships a wrangler fragment, an example route under `src/routes/`, and (where relevant) extra files. Binding IDs are `<PLACEHOLDER>` until you create the real resource and paste the returned ID into `wrangler.jsonc`, then re-run `npm run cf-typegen`.

## Hyperdrive + Postgres (`HYPERDRIVE`, route `/db`)

- Fragment includes `localConnectionString` for local dev; `id` is `<HYPERDRIVE_ID>`.
- Example uses `postgres` (postgres.js): `const sql = postgres(c.env.HYPERDRIVE.connectionString, { max: 5, fetch_types: false })` and closes with `c.executionCtx.waitUntil(sql.end())`.
- Local dev connects directly to `localConnectionString`; for a private DB use `scripts/db-tunnel.sh` (see `local-dev-modes.md`).
- Create real resource: `npx wrangler hyperdrive create <name>-hd --connection-string="postgres://user:pass@host:5432/db"`. For a private DB, prefer a Workers VPC service (`wrangler vpc service create ...`) then `hyperdrive create --service-id ...`.
- Deep dive → `cloudflare:cloudflare` `references/hyperdrive/*`.

## D1 (`DB`, route `/d1`)

- Ships `migrations/0000_init.sql`. Apply locally: `npx wrangler d1 migrations apply DB --local` (add `--remote` for production).
- Create real resource: `npx wrangler d1 create <name>-db` → paste `database_id`.
- Local dev emulates D1 via Miniflare (SQLite on disk under `.wrangler/state`).

## KV (`KV`, route `/kv/:key`)

- Example `GET`/`PUT` a key. Emulated locally.
- Create real resource: `npx wrangler kv namespace create KV` → paste `id`.

## R2 (`BUCKET`, route `/r2/:key`)

- Example `PUT` (streams the request body) / `GET` (streams the object back). Emulated locally.
- Create real resource: `npx wrangler r2 bucket create <name>-bucket`.

## Remote bindings during local dev

For bindings with no local emulator or that you want to hit for real while developing (AI, Vectorize, Browser Rendering, Images), add `"remote": true` to the binding in `wrangler.jsonc`. See `cloudflare:wrangler`.

## Node built-ins (`nodejs_compat`)

The base sets `compatibility_flags: ["nodejs_compat"]`. If you import node built-ins (`node:crypto`, etc.) and want their types, run `npm i -D @types/node` and add `"@types/node"` to `types` in `tsconfig.json`. Not required for the shipped examples.

## Out of scope (use other skills)

Durable Objects, Queues, Workflows, AI/Vectorize, Containers → `cloudflare:durable-objects` and `cloudflare:cloudflare`.
