import { Hono } from "hono";
import postgres from "postgres";

// Example route: query Postgres through Hyperdrive.
// A client is created per request; Hyperdrive pools the underlying connections.
export const hyperdrive = new Hono<{ Bindings: Env }>();

hyperdrive.get("/", async (c) => {
	const sql = postgres(c.env.HYPERDRIVE.connectionString, {
		// Keep the client lean for the Workers runtime.
		max: 5,
		fetch_types: false,
	});
	try {
		const rows = await sql`select now() as now`;
		// Close the connection after the response is sent.
		c.executionCtx.waitUntil(sql.end());
		return c.json({ ok: true, rows });
	} catch (err) {
		c.executionCtx.waitUntil(sql.end());
		const message = err instanceof Error ? err.message : String(err);
		return c.json({ ok: false, error: message }, 500);
	}
});
