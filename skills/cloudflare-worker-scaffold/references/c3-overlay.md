# `--c3` mode: C3 generator + local-dev overlay

Use `--c3` when the user wants Cloudflare's official generator (C3) to own the base project, with this skill's local-dev wiring layered on top.

## Step 1 — run C3

```sh
npm create cloudflare@latest <name> -- --type=hello-world --lang=ts --no-deploy [--no-git]
```

- `--type=hello-world --lang=ts` → a plain TypeScript Worker. Choosing hello-world (not a framework template) keeps a single, predictable overlay path and avoids drift from C3's own Hono template.
- `--no-deploy` → does not deploy (so no `wrangler login` needed to scaffold).
- `--no-git` → optional, if the user manages git themselves.

## Step 2 — overlay

```sh
node ~/.claude/skills/cloudflare-worker-scaffold/scripts/scaffold.mjs \
  --mode c3 --dir <name> --bindings <list>
```

In `--mode c3` the assembler:

- **Replaces** C3's trivial `src/index.ts` with the Hono base (with markers) and wires the selected route modules in.
- **Adds** the local-dev extras C3 omits (only if absent): `.dev.vars.example`, `vitest.config.ts`, `test/index.spec.ts`, `README.md`, `CLAUDE.md`, and `scripts/db-tunnel.sh` (via the hyperdrive overlay).
- **Key-merges** each binding fragment into C3's existing `wrangler.jsonc` by inserting before the final `}` and skipping any key already present (no marker required, no clobber).
- **Merges** `hono` (+ `postgres` for Hyperdrive) into C3's `package.json` `dependencies`, keeping C3's scripts, `tsconfig.json`, and `.gitignore`.

## Step 3 — finish

```sh
cd <name>
npm install
npm run cf-typegen
npm run dev
```

## Trade-off

Bundled mode is instant and offline but can lag Cloudflare's evolving defaults. `--c3` always starts from Cloudflare's current generator output, at the cost of a network round-trip and C3's interactive/noninteractive flags. When Cloudflare changes defaults, prefer `--c3`, or refresh the bundled templates against `cloudflare:wrangler` / `cloudflare:cloudflare` `references/c3/*`.
