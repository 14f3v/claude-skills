# Project guidance for Claude

This is a Cloudflare Worker (TypeScript + Hono), scaffolded local-development-first.

- **Entry:** `src/index.ts` (Hono app). Route modules live in `src/routes/`.
- **Config:** `wrangler.jsonc`. Binding IDs are `<PLACEHOLDERS>` until you create real resources with `wrangler ... create`.
- **Types:** run `npm run cf-typegen` (`wrangler types`) after changing bindings. Never hand-write `Env` — it comes from the generated `worker-configuration.d.ts`.
- **Local dev:** `npm run dev` (local) / `npm run dev:remote` (edge). See `README.md` for the three modes; for a private Postgres use `scripts/db-tunnel.sh`.
- **Secrets:** `.dev.vars` (gitignored). Never commit it.
- **Tests:** `npm test` (Vitest + `@cloudflare/vitest-pool-workers`).

For deeper Cloudflare help, use the `cloudflare:wrangler`, `cloudflare:workers-best-practices`, `cloudflare:durable-objects`, and `cloudflare:cloudflare` skills.
