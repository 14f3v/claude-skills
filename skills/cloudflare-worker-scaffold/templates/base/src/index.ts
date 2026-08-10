import { Hono } from "hono";
// @scaffold:imports

// Bindings are typed from the generated `worker-configuration.d.ts`.
// Run `npm run cf-typegen` after changing bindings in wrangler.jsonc.
const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) =>
	c.json({ ok: true, service: "__PROJECT_NAME__", ts: Date.now() }),
);

// @scaffold:routes

export default app;
