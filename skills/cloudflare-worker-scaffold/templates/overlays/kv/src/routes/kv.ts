import { Hono } from "hono";

// Example routes: read/write Cloudflare KV.
export const kv = new Hono<{ Bindings: Env }>();

kv.get("/:key", async (c) => {
	const key = c.req.param("key");
	const value = await c.env.KV.get(key);
	return c.json({ key, value });
});

kv.put("/:key", async (c) => {
	const key = c.req.param("key");
	const body = await c.req.text();
	await c.env.KV.put(key, body);
	return c.json({ ok: true, key });
});
