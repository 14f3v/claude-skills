#!/usr/bin/env node
// scaffold.mjs — assemble a Cloudflare Worker project from bundled templates.
//
// It copies templates/base/** then applies templates/overlays/<binding>/** for
// each selected binding, merging via anchor markers so JSONC/TS stay valid:
//   - wrangler.jsonc : the `/* @scaffold:bindings */` marker (bundled) or
//                      insert-before-last-brace with key dedupe (c3 mode)
//   - src/index.ts   : inject imports before `// @scaffold:imports` and routes
//                      before `// @scaffold:routes`
//   - .dev.vars.example : append per-binding blocks (deduped)
//   - package.json   : deep-merge each overlay's deps.json
//
// Deterministic, offline, idempotent (safe to re-run; skips existing files
// unless --force, and merges are dedupe-guarded).
//
// Usage:
//   node scaffold.mjs --name <name> [--dir <path>] [--bindings hyperdrive,d1,kv,r2]
//                     [--mode bundled|c3] [--compat-date YYYY-MM-DD] [--force]
//   --bindings accepts a comma list, or "all" / "none".

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SKILL_ROOT = path.resolve(__dirname, "..");
const TEMPLATES = path.join(SKILL_ROOT, "templates");
const BASE = path.join(TEMPLATES, "base");
const OVERLAYS = path.join(TEMPLATES, "overlays");
const KNOWN = ["hyperdrive", "d1", "kv", "r2"];

const IMPORTS_MARKER = "// @scaffold:imports";
const ROUTES_MARKER = "// @scaffold:routes";
const BINDINGS_MARKER = "/* @scaffold:bindings */";

// ---------- args ----------
function parseArgs(argv) {
	const out = { bindings: [], mode: "bundled", force: false };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		const next = () => argv[++i];
		switch (a) {
			case "--name":
			case "--project-name": out.name = next(); break;
			case "--dir": out.dir = next(); break;
			case "--bindings": out.bindingsRaw = next(); break;
			case "--mode": out.mode = next(); break;
			case "--compat-date": out.compatDate = next(); break;
			case "--force": out.force = true; break;
			case "-h": case "--help": out.help = true; break;
			default:
				if (!a.startsWith("-") && !out.name) out.name = a;
				else { console.error(`unknown arg: ${a}`); process.exit(2); }
		}
	}
	return out;
}

function usage() {
	console.log(`Usage: node scaffold.mjs --name <name> [--dir <path>] [--bindings hyperdrive,d1,kv,r2] [--mode bundled|c3] [--compat-date YYYY-MM-DD] [--force]`);
}

function resolveBindings(raw) {
	if (raw === undefined) return [];
	const v = raw.trim().toLowerCase();
	if (v === "" || v === "none") return [];
	if (v === "all") return [...KNOWN];
	const list = v.split(",").map((s) => s.trim()).filter(Boolean);
	for (const b of list) {
		if (!KNOWN.includes(b)) {
			console.error(`unknown binding "${b}". Known: ${KNOWN.join(", ")}`);
			process.exit(2);
		}
	}
	// canonical order, de-duplicated
	return KNOWN.filter((b) => list.includes(b));
}

// ---------- helpers ----------
function replaceTokens(s, tokens) {
	for (const [k, v] of Object.entries(tokens)) s = s.split(k).join(v);
	return s;
}
function destName(base) {
	return base.startsWith("dot-") ? "." + base.slice(4) : base;
}
function ensureDir(d) { fs.mkdirSync(d, { recursive: true }); }
function walk(dir) {
	const out = [];
	if (!fs.existsSync(dir)) return out;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) out.push(...walk(p));
		else out.push(p);
	}
	return out;
}
function writeFileSafe(dest, content, force) {
	if (fs.existsSync(dest) && !force) return "skipped";
	ensureDir(path.dirname(dest));
	fs.writeFileSync(dest, content);
	return "written";
}
function mark(status) { return status === "written" ? "+" : "="; }
function read(p) { return fs.existsSync(p) ? fs.readFileSync(p, "utf8") : null; }

function copyOne(src, dest, tokens, force, label) {
	if (!fs.existsSync(src)) return;
	const content = replaceTokens(fs.readFileSync(src, "utf8"), tokens);
	const status = writeFileSafe(dest, content, force);
	console.log(`  [${mark(status)}] ${label}${status === "skipped" ? " (exists, skipped)" : ""}`);
}

function copyTree(srcDir, destDir, target, tokens, force, { chmodSh = false } = {}) {
	for (const abs of walk(srcDir)) {
		const rel = path.relative(srcDir, abs);
		const dest = path.join(destDir, rel);
		const content = replaceTokens(fs.readFileSync(abs, "utf8"), tokens);
		const status = writeFileSafe(dest, content, force);
		if (status === "written" && chmodSh && dest.endsWith(".sh")) fs.chmodSync(dest, 0o755);
		console.log(`  [${mark(status)}] ${path.relative(target, dest)}${status === "skipped" ? " (exists, skipped)" : ""}`);
	}
}

// ---------- merges ----------
function mergeWrangler(target, fragments, tokens) {
	const wp = path.join(target, "wrangler.jsonc");
	let content = read(wp);
	if (content === null) { console.log("  [!] wrangler.jsonc not found; skipping binding merge"); return; }

	const kept = [];
	for (const frag of fragments) {
		const key = (frag.match(/"([a-z0-9_]+)"\s*:/) || [])[1];
		if (key && new RegExp(`"${key}"\\s*:`).test(content)) {
			console.log(`  [=] wrangler: "${key}" already present, skipping`);
			continue;
		}
		kept.push(frag.replace(/\n+$/, ""));
	}

	if (content.includes(BINDINGS_MARKER)) {
		const block = kept.length ? ",\n" + kept.join(",\n") : "";
		content = content.replace(/,?\s*\/\* @scaffold:bindings \*\//, block);
	} else if (kept.length) {
		// c3 mode: no marker — insert before the final closing brace
		const idx = content.lastIndexOf("}");
		const head = content.slice(0, idx).replace(/\s*$/, "");
		content = head + ",\n" + kept.join(",\n") + "\n}" + content.slice(idx + 1);
	}
	content = replaceTokens(content, tokens);
	fs.writeFileSync(wp, content);
	console.log("  [*] wrangler.jsonc: bindings merged");
}

function injectBefore(content, marker, lines) {
	const uniq = lines.map((l) => l.trim()).filter((l) => l && !content.includes(l));
	if (!uniq.length || !content.includes(marker)) return content;
	return content.replace(marker, uniq.join("\n") + "\n" + marker);
}

function mergeSrc(target, imports, routes) {
	const sp = path.join(target, "src", "index.ts");
	let content = read(sp);
	if (content === null) { console.log("  [!] src/index.ts not found; skipping route wiring"); return; }
	content = injectBefore(content, IMPORTS_MARKER, imports);
	content = injectBefore(content, ROUTES_MARKER, routes);
	fs.writeFileSync(sp, content);
	if (imports.length) console.log("  [*] src/index.ts: routes wired");
}

function appendDevVars(target, blocks) {
	if (!blocks.length) return;
	const dp = path.join(target, ".dev.vars.example");
	let content = read(dp) ?? "";
	for (const b of blocks) {
		const anchor = (b.split("\n").map((s) => s.trim()).find((s) => s.startsWith("#") && s.length > 3)) || b.trim();
		if (anchor && content.includes(anchor)) continue;
		content = content.replace(/\s*$/, "\n") + b.replace(/\s*$/, "") + "\n";
	}
	fs.writeFileSync(dp, content);
	console.log("  [*] .dev.vars.example: binding notes appended");
}

function mergeDeps(target, depsObjs) {
	if (!depsObjs.length) return;
	const pp = path.join(target, "package.json");
	const raw = read(pp);
	if (raw === null) { console.log("  [!] package.json not found; skipping deps merge"); return; }
	const pkg = JSON.parse(raw);
	for (const d of depsObjs) {
		for (const section of ["dependencies", "devDependencies"]) {
			if (d[section]) {
				pkg[section] = pkg[section] || {};
				Object.assign(pkg[section], d[section]);
			}
		}
	}
	fs.writeFileSync(pp, JSON.stringify(pkg, null, "\t") + "\n");
	console.log("  [*] package.json: dependencies merged");
}

// ---------- main ----------
function main() {
	const args = parseArgs(process.argv.slice(2));
	if (args.help) { usage(); process.exit(0); }
	if (!args.name) { console.error("error: --name is required"); usage(); process.exit(2); }

	const name = args.name;
	if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) {
		console.error(`warning: "${name}" is not a typical Worker name (lowercase letters, digits, dashes). Continuing.`);
	}
	const mode = args.mode === "c3" ? "c3" : "bundled";
	const bindings = resolveBindings(args.bindingsRaw);
	const target = path.resolve(process.cwd(), args.dir || name);
	const compatDate = args.compatDate || new Date().toISOString().slice(0, 10);
	const tokens = { "__PROJECT_NAME__": name, "__COMPAT_DATE__": compatDate };
	const force = args.force;

	console.log(`\ncloudflare-worker-scaffold`);
	console.log(`  name:     ${name}`);
	console.log(`  dir:      ${target}`);
	console.log(`  mode:     ${mode}`);
	console.log(`  bindings: ${bindings.length ? bindings.join(", ") : "(none)"}`);
	console.log(`  compat:   ${compatDate}\n`);

	if (mode === "c3") {
		if (!fs.existsSync(target)) {
			console.error(`error: --mode c3 expects the C3-generated project dir to exist: ${target}`);
			process.exit(1);
		}
	} else {
		ensureDir(target);
		const existing = fs.readdirSync(target).filter((n) => n !== ".git");
		if (existing.length && !force) {
			console.log(`  note: ${target} is not empty — existing files are kept (use --force to overwrite).\n`);
		}
	}

	// 1. base
	if (mode === "bundled") {
		console.log("base templates:");
		for (const abs of walk(BASE)) {
			const rel = path.relative(BASE, abs).split(path.sep);
			rel[rel.length - 1] = destName(rel[rel.length - 1]);
			const destRel = rel.join(path.sep);
			const content = replaceTokens(fs.readFileSync(abs, "utf8"), tokens);
			const status = writeFileSafe(path.join(target, destRel), content, force);
			console.log(`  [${mark(status)}] ${destRel}${status === "skipped" ? " (exists, skipped)" : ""}`);
		}
	} else {
		console.log("c3 overlay (base Hono app + local-dev extras):");
		copyOne(path.join(BASE, "src/index.ts"), path.join(target, "src/index.ts"), tokens, true, "src/index.ts (replaced)");
		for (const rel of ["vitest.config.ts", "test/index.spec.ts", "README.md", "CLAUDE.md"]) {
			copyOne(path.join(BASE, rel), path.join(target, rel), tokens, false, rel);
		}
		copyOne(path.join(BASE, "dot-dev.vars.example"), path.join(target, ".dev.vars.example"), tokens, false, ".dev.vars.example");
	}

	// 2. overlays
	const fragments = [], imports = [], routes = [], devvars = [], deps = [];
	if (bindings.length) console.log("\nbinding overlays:");
	for (const b of bindings) {
		const od = path.join(OVERLAYS, b);
		copyTree(path.join(od, "src"), path.join(target, "src"), target, tokens, force);
		copyTree(path.join(od, "files"), target, target, tokens, force, { chmodSh: true });
		const frag = read(path.join(od, "wrangler.fragment.jsonc")); if (frag) fragments.push(frag);
		const imp = read(path.join(od, "src.import.txt")); if (imp) imports.push(imp);
		const rt = read(path.join(od, "src.route.txt")); if (rt) routes.push(rt);
		const dv = read(path.join(od, "devvars.append.txt")); if (dv) devvars.push(dv);
		const dj = read(path.join(od, "deps.json")); if (dj) deps.push(JSON.parse(dj));
	}
	if (mode === "c3") deps.push({ dependencies: { hono: "^4.6.0" } });

	// 3. merge
	console.log("\nmerging:");
	mergeWrangler(target, fragments, tokens);
	mergeSrc(target, imports, routes);
	appendDevVars(target, devvars);
	mergeDeps(target, deps);

	// 4. next steps
	console.log(`\n✅ Scaffolded ${name} at ${target}\n`);
	console.log("Next steps:");
	console.log("  npm install");
	console.log("  npm run cf-typegen        # generate worker-configuration.d.ts");
	console.log("  npm run dev               # local dev at http://localhost:8787 (curl /health)");
	console.log("");
	console.log("Local-dev modes:");
	console.log("  1) local    : npm run dev            (Miniflare emulates KV/R2/D1; Hyperdrive uses localConnectionString)");
	console.log("  2) proxy    : ./scripts/db-tunnel.sh --hostname db.example.com   then npm run dev  (private Postgres via cloudflared)");
	console.log("  3) remote   : npm run dev:remote     (runs on the edge; real bindings incl. Hyperdrive->tunnel)");
	if (bindings.length) {
		console.log("\nBefore deploying, create the real resources and paste IDs over the <...> placeholders in wrangler.jsonc:");
		if (bindings.includes("kv")) console.log("  npx wrangler kv namespace create KV");
		if (bindings.includes("d1")) console.log(`  npx wrangler d1 create ${name}-db   &&  npx wrangler d1 migrations apply DB --local`);
		if (bindings.includes("r2")) console.log(`  npx wrangler r2 bucket create ${name}-bucket`);
		if (bindings.includes("hyperdrive")) console.log(`  npx wrangler hyperdrive create ${name}-hd --connection-string="postgres://user:pass@host:5432/db"`);
		console.log("  then: npm run cf-typegen");
	}
	console.log("");
}

main();
