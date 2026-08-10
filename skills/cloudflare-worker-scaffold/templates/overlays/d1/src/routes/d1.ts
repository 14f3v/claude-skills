import { Hono } from "hono";

// Example route: query D1 (Cloudflare's serverless SQLite).
export const d1 = new Hono<{ Bindings: Env }>();

d1.get("/", async (c) => {
	const { results } = await c.env.DB.prepare("select 1 as one").all();
	return c.json({ ok: true, results });
});
