import { Hono } from "hono";

// Example routes: read/write Cloudflare R2 object storage.
export const r2 = new Hono<{ Bindings: Env }>();

r2.put("/:key", async (c) => {
	const key = c.req.param("key");
	await c.env.BUCKET.put(key, c.req.raw.body);
	return c.json({ ok: true, key });
});

r2.get("/:key", async (c) => {
	const key = c.req.param("key");
	const object = await c.env.BUCKET.get(key);
	if (!object) return c.json({ ok: false, error: "not found" }, 404);
	return new Response(object.body, {
		headers: {
			"content-type":
				object.httpMetadata?.contentType ?? "application/octet-stream",
		},
	});
});
