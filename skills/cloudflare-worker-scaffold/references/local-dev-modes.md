# Local development modes

A scaffolded Worker can be run three ways. Only mode 1 and 2 involve your local machine in the network path; mode 3 runs on Cloudflare's edge.

## 1. Pure local — `npm run dev` (`wrangler dev`)

- Your Worker runs on your machine (workerd via Miniflare).
- **KV / R2 / D1** are emulated locally; state persists in `.wrangler/state`. No Cloudflare account needed.
- **Hyperdrive** does NOT route through the deployed config in this mode — `wrangler dev` connects **directly** from your machine to the database given by `localConnectionString` in `wrangler.jsonc` (default `postgres://postgres:postgres@localhost:5432/postgres`). So your machine must be able to reach that DB (e.g. a local Postgres, or one exposed via mode 2). Query caching does not apply locally.
- Precedence for Hyperdrive's local connection: the env var `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE` overrides `localConnectionString`. Export it before `npm run dev` to point at a different DB without editing `wrangler.jsonc`.

## 2. cloudflared proxy + local

For a **private Postgres behind a Cloudflare Tunnel** that your laptop can't reach directly:

```sh
./scripts/db-tunnel.sh --hostname db.example.com \
  --service-token-id <id> --service-token-secret <secret>
```

This runs `cloudflared access tcp` and exposes the private DB at `localhost:5432`. Then point `localConnectionString` (or the env var above) at `localhost:5432` and run `npm run dev`. Requires: a public-hostname (TCP) route on the tunnel, a Cloudflare Access application protecting it with a Service Auth policy, and a service token.

## 3. Remote — `npm run dev:remote` (`wrangler dev --remote`)

- Your Worker code executes **on Cloudflare's edge**, using the real deployed bindings.
- Hyperdrive reaches the private DB via its VPC service / tunnel exactly like production — **no local proxy needed**.
- `localConnectionString` is ignored. ⚠️ Uses live resources and data.

## Which to pick

- Fast iteration, offline, safe data → **mode 1** (with a local Postgres for Hyperdrive).
- Fast iteration against a private DB, no account round-trips → **mode 2**.
- Exercise the real edge + real bindings → **mode 3**.

For the underlying Wrangler flags and Miniflare persistence details, use the `cloudflare:wrangler` and `cloudflare:cloudflare` (`references/miniflare/*`) skills.
