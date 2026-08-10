import { env } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import app from "../src/index";

describe("health", () => {
	it("GET /health returns ok:true", async () => {
		const res = await app.request("/health", {}, env);
		expect(res.status).toBe(200);
		expect(await res.json()).toMatchObject({ ok: true });
	});
});
