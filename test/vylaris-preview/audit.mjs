// Automated theme audit: contrast, foreign colours, focus indicators, responsive problems and
// console / network errors, measured on the rendered preview pages.
//
//   node test/vylaris-preview/audit.mjs --css <dir> --themes vylaris,vylaris-dark \
//        --viewports desktop,mobile --pages all --out <dir>/audit.json [--palette-from <dir>]
//
//   node test/vylaris-preview/audit.mjs --find-rule <dir>/audit.json [--theme vylaris-dark]
//   node test/vylaris-preview/audit.mjs --compare <baseline>.json --against <current>.json
//
// See README.md ("Audit") for the meaning of every category.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import { colorLib, loadPalette, pageAudit } from "./audit-lib.mjs";
import { COMPARED, compareReports, GROUP_ID } from "./lib/compare.mjs";
import {
	createContexts,
	keyOf,
	loadManifest,
	loadPlaywright,
	openPreviewPage,
	parseViewports,
	pool,
	prerender,
	repoRoot,
	selectPages,
	watchPage,
} from "./lib/harness.mjs";
import { previewRoot } from "./lib/php.mjs";
import { startServer } from "./lib/server.mjs";
import { FAKE_WEBSOCKET } from "./lib/steps.mjs";

const { values: args } = parseArgs({
	options: {
		css: { type: "string" },
		themes: { type: "string", default: "vylaris,vylaris-dark" },
		viewports: { type: "string", default: "desktop,mobile" },
		pages: { type: "string", default: "all" },
		out: { type: "string" },
		"palette-from": { type: "string" },
		"palette-mode": { type: "string", default: "auto" },
		tolerance: { type: "string", default: "3" },
		top: { type: "string", default: "15" },
		"max-items": { type: "string", default: "15" },
		"full-detail": { type: "boolean", default: false },
		concurrency: { type: "string", default: String(Math.max(4, os.availableParallelism() * 2)) },
		settle: { type: "string" },
		skip: { type: "string", default: "" },
		compare: { type: "string" },
		against: { type: "string" },
		"fail-on-new": { type: "boolean", default: false },
		manifest: { type: "string", default: path.join(previewRoot, "pages.json") },
		animations: { type: "string", default: "off" },
		"find-rule": { type: "string" },
		theme: { type: "string" },
		"css-src": { type: "string", default: path.join(repoRoot, "web/css/src") },
		limit: { type: "string", default: "15" },
		help: { type: "boolean", default: false },
	},
});

const usage = `Usage: node test/vylaris-preview/audit.mjs --css <dir> --out <dir>/audit.json [options]

  --css <dir>           directory with <theme>.min.css (build-css.mjs)
  --out <file.json>     JSON report; <file>.md gets the same summary as stdout; the pre-rendered
                        HTML goes to <dir of out>/html
  --themes a,b          default: vylaris,vylaris-dark
  --viewports a,b       desktop (1440x900) / mobile (390x844); default: both
                        (touch targets are only measured on mobile)
  --pages a,b|all       page ids or group:<name>; default: all
  --palette-from <dir>  folder with tokens.css + mode-light.css + mode-dark.css that define the allowed
                        colours; default: web/css/src/themes/vylaris
  --palette-mode m      auto (default: "dark" in the theme name -> dark, else light) | light | dark
  --tolerance <dE>      CIEDE2000 distance that still counts as "in the palette", default 3
  --top <n>             offenders listed per category and theme, default 15
  --max-items <n>       raw items kept per page and category in the JSON, default 15
  --full-detail         keep every raw item of every page in the JSON (can be large)
  --concurrency <n>     parallel pages, default 2x the CPU count (min 4); the audit takes no
                        screenshots, so this is the main speed knob
  --settle <ms>         wait this long after load instead of the per-page "settle" of pages.json
                        (default 250); 60 is enough for pages without animated content
  --skip a,b            leave sections out: contrast, ui, leaks, focus, responsive (focus and leaks
                        are the slowest); skipped sections report 0 findings
  --animations on|off   default off (reduced motion + zero animation durations)

  --compare <audit.json>  compare this run with an earlier report: new / fixed / unchanged groups
                        per theme, viewport and category, appended to the summary
    --against <audit.json>  no browser: compare the baseline with this existing report instead
    --fail-on-new           exit 1 when the comparison has new groups

  --find-rule <audit.json>  no browser: look up the source CSS rules behind the worst foreign colours
    --theme <name>          only this theme (default: all in the report)
    --limit <n>             groups to resolve per theme, default 15
    --css-src <dir>         where to grep, default web/css/src`;

if (args.help) {
	console.log(usage);
	process.exit(0);
}

const C = colorLib();
const round1 = (n) => Math.round(n * 10) / 10;

// =================================================================================================
// --find-rule: map report groups back to source CSS declarations
// =================================================================================================
function* cssFiles(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name !== "node_modules") {
				yield* cssFiles(full);
			}
		} else if (entry.name.endsWith(".css")) {
			yield full;
		}
	}
}

/** Declarations with the (nesting-resolved) selector they sit in. Small hand rolled scanner. */
function scanDeclarations(file) {
	const text = fs
		.readFileSync(file, "utf8")
		.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
	const decls = [];
	const stack = [];
	let buf = "";
	let bufLine = 1;
	let line = 1;
	for (const ch of text) {
		if (ch === "{") {
			const sel = buf.trim();
			const parent = stack.at(-1) ?? "";
			stack.push(
				sel.startsWith("@")
					? `${parent}${parent ? " " : ""}${sel}`
					: parent && !sel.startsWith("@")
						? sel
								.split(",")
								.map((x) =>
									x.includes("&") ? x.trim().replaceAll("&", parent) : `${parent} ${x.trim()}`,
								)
								.join(", ")
						: sel,
			);
			buf = "";
		} else if (ch === "}" || ch === ";") {
			const m = buf.match(/^\s*([a-z-]+|--[\w-]+)\s*:\s*([\s\S]+?)\s*$/);
			if (m && stack.length) {
				decls.push({ file, line: bufLine, selector: stack.at(-1), prop: m[1], value: m[2] });
			}
			if (ch === "}") {
				stack.pop();
			}
			buf = "";
		} else {
			if (buf.trim() === "" && ch.trim() !== "") {
				bufLine = line;
			}
			buf += ch;
		}
		if (ch === "\n") {
			line++;
		}
	}
	return decls;
}

const PROP_FAMILY = {
	color: [/^color$/, /^-webkit-text-fill-color$/],
	"background-color": [/^background(-color)?$/],
	"background-image": [/^background(-image)?$/],
	"border-color": [/^border(-(top|right|bottom|left))?(-color)?$/],
	"outline-color": [/^outline(-color)?$/],
	"box-shadow": [/^box-shadow$/],
	"text-shadow": [/^text-shadow$/],
	fill: [/^fill$/],
	stroke: [/^stroke$/],
	"placeholder-color": [/^color$/],
	"accent-color": [/^accent-color$/],
};

function findRules(reportFile) {
	const report = JSON.parse(fs.readFileSync(reportFile, "utf8"));
	const limit = Number.parseInt(args.limit, 10) || 15;
	const srcRoot = path.resolve(args["css-src"]);
	const files = [...cssFiles(srcRoot)];
	const scanned = new Map(files.map((f) => [f, scanDeclarations(f)]));
	// only the files that end up in this theme's bundle: shared sources, default.css, the theme itself
	// and (for vylaris*) the vylaris/ partials. Other theme entry files are ignored.
	const inBundle = (file, theme) => {
		const rel = path.relative(path.join(srcRoot, "themes"), file);
		if (rel.startsWith("..")) {
			return true;
		}
		if (rel.startsWith(`vylaris${path.sep}`)) {
			return theme.startsWith("vylaris");
		}
		return rel === "default.css" || rel === `${theme}.css`;
	};
	const themes = args.theme ? [args.theme] : report.meta.themes;
	for (const theme of themes) {
		const decls = files.filter((f) => inBundle(f, theme)).flatMap((f) => scanned.get(f));
		const groups = report.groups?.[theme]?.leaks;
		if (!groups) {
			console.log(`no leak groups for theme ${theme}`);
			continue;
		}
		console.log(`\n## ${theme}: source candidates for the ${limit} worst foreign colours\n`);
		for (const g of groups.slice(0, limit)) {
			const family = PROP_FAMILY[g.prop] ?? [new RegExp(`^${g.prop}$`)];
			const wanted = [g.key, g.origin].filter(Boolean).map((k) => {
				const [tag, ...cls] = k.replace(/::\w+$/, "").split(".");
				return { tag, cls };
			});
			const target = C.parse(g.color);
			const scored = [];
			for (const d of decls) {
				if (!family.some((re) => re.test(d.prop))) {
					continue;
				}
				// last compound selector of each comma part
				let score = 0;
				for (const part of d.selector.split(",")) {
					const last = part
						.trim()
						.split(/[\s>+~]+/)
						.at(-1);
					for (const w of wanted) {
						const hit = w.cls.filter((c) =>
							new RegExp(`\\.${c.replace(/[^\w-]/g, "\\$&")}(?![\\w-])`).test(last),
						).length;
						if (hit > 0) {
							score = Math.max(score, hit * 2 - (last.match(/\./g).length - hit) * 0.5);
						} else if (!last.includes(".") && last.startsWith(w.tag)) {
							// a bare tag selector (a, label, body): weak candidate
							score = Math.max(score, 1);
						}
					}
				}
				if (score <= 0) {
					continue;
				}
				const lits = (d.value.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)/g) ?? [])
					.map((x) => C.parse(x))
					.filter(Boolean);
				if (target && lits.some((c) => C.deltaE(C.toLab(c), C.toLab(target)) < 2.5)) {
					score += 3;
				}
				scored.push({ d, score });
			}
			scored.sort((a, b) => b.score - a.score);
			console.log(
				`- ${g.prop} ${g.color} on ${g.key}${g.origin ? ` (set by ${g.origin})` : ""} x${g.count}, nearest ${g.nearest} dE ${g.deltaE}`,
			);
			if (scored.length === 0) {
				console.log(
					"    no matching declaration in the source (inherited from a parent rule or the user agent)",
				);
			}
			for (const { d, score } of scored.slice(0, 4)) {
				console.log(
					`    ${path.relative(repoRoot, d.file)}:${d.line}  ${d.selector.replace(/\s+/g, " ").slice(0, 90)} { ${d.prop}: ${d.value.slice(0, 70)} }  [score ${score}]`,
				);
			}
		}
	}
}

if (args["find-rule"]) {
	findRules(path.resolve(args["find-rule"]));
	process.exit(0);
}

// =================================================================================================
// --compare <baseline> --against <current>: two existing reports, no browser
// =================================================================================================
if (args.against) {
	if (!args.compare) {
		console.error("--against needs --compare <baseline audit.json>");
		process.exit(2);
	}
	const result = compareReports(
		JSON.parse(fs.readFileSync(path.resolve(args.compare), "utf8")),
		JSON.parse(fs.readFileSync(path.resolve(args.against), "utf8")),
		{ top: Number.parseInt(args.top, 10) || 15, baseName: path.resolve(args.compare) },
	);
	console.log(result.md);
	process.exit(args["fail-on-new"] && result.newGroups > 0 ? 1 : 0);
}

// =================================================================================================
// run the audit
// =================================================================================================
if (!args.out || !args.css) {
	console.error(usage);
	process.exit(2);
}

const manifestPath = path.resolve(args.manifest);
const manifest = loadManifest(manifestPath);
const outFile = path.resolve(args.out);
const outDir = path.dirname(outFile);
const cssDir = path.resolve(args.css);
const themes = args.themes.split(",").filter(Boolean);
const tolerance = Number.parseFloat(args.tolerance);
const SECTIONS = ["contrast", "ui", "leaks", "focus", "responsive"];
const skip = args.skip.split(",").filter(Boolean);
if (skip.some((x) => !SECTIONS.includes(x))) {
	console.error(`--skip takes ${SECTIONS.join(", ")}`);
	process.exit(2);
}
const top = Number.parseInt(args.top, 10) || 15;
const maxItems = Number.parseInt(args["max-items"], 10) || 15;
let viewportNames;
let pages;
try {
	viewportNames = parseViewports(args.viewports);
	pages = selectPages(manifest, args.pages);
} catch (error) {
	console.error(error.message);
	process.exit(2);
}
if (!["auto", "light", "dark"].includes(args["palette-mode"])) {
	console.error("--palette-mode must be auto, light or dark");
	process.exit(2);
}

const paletteDir = path.resolve(
	args["palette-from"] ?? path.join(repoRoot, "web/css/src/themes/vylaris"),
);
const modeOf = (theme) =>
	args["palette-mode"] === "auto" ? (/dark/.test(theme) ? "dark" : "light") : args["palette-mode"];
const palettes = {};
const paletteTokens = {};
const paletteWarnings = [];
try {
	for (const mode of ["light", "dark"]) {
		const loaded = loadPalette(paletteDir, mode);
		paletteTokens[mode] = loaded.tokens;
		for (const { name, value } of loaded.skipped) {
			paletteWarnings.push(
				`${mode}: ${name} needs the browser to be evaluated (${value}), not in the palette`,
			);
		}
		if (themes.some((theme) => modeOf(theme) === mode)) {
			palettes[mode] = loaded.colors;
		}
	}
} catch (error) {
	console.error(error.message);
	process.exit(2);
}
// a colour token that exists in one mode only is a mode file that was forgotten
for (const [from, to] of [
	["light", "dark"],
	["dark", "light"],
]) {
	for (const name of paletteTokens[from].filter((n) => !paletteTokens[to].includes(n))) {
		paletteWarnings.push(
			`${name} has a static colour in mode-${from}.css but not in mode-${to}.css`,
		);
	}
}
for (const [mode, list] of Object.entries(palettes)) {
	console.log(
		`palette ${mode}: ${list.length} colours from ${paletteTokens[mode].length} tokens in ${paletteDir}`,
	);
}
for (const warning of paletteWarnings) {
	console.warn(`palette warning: ${warning}`);
}

const concurrency = Math.max(1, Number.parseInt(args.concurrency, 10) || 4);
const { htmlDir, results: renderResults } = await prerender({
	themes,
	pages,
	outDir,
	manifestPath,
	concurrency,
});
for (const [key, r] of renderResults) {
	if (r.phpCode !== 0) {
		console.log(`PHP  ${key}: ${r.php.slice(0, 3).join(" | ")}`);
	}
}

const notifications = JSON.parse(
	fs.readFileSync(path.join(previewRoot, "data/notifications.json"), "utf8"),
);
const server = await startServer({
	cssDir,
	htmlDir,
	webRoot: path.join(repoRoot, "web"),
	notifications,
});
const base = `http://127.0.0.1:${server.port}`;
const { chromium } = await loadPlaywright();
const browser = await chromium.launch();
const contexts = await createContexts(browser, themes, viewportNames, args.animations !== "on");

const jobs = [];
for (const theme of themes) {
	for (const vp of viewportNames) {
		for (const entry of pages) {
			if (!entry.viewports || entry.viewports.includes(vp)) {
				jobs.push({ theme, vp, entry });
			}
		}
	}
}

const records = [];
const t0 = Date.now();
let done = 0;
await pool(jobs, concurrency, async ({ theme, vp, entry }) => {
	const render = renderResults.get(keyOf(theme, entry.id));
	const rec = {
		theme,
		viewport: vp,
		page: entry.id,
		group: entry.group ?? "",
		php: render.phpCode === 0 ? [] : render.php,
		consoleErrors: [],
		failedRequests: [],
		stepErrors: [],
	};
	const pageEntry = args.settle ? { ...entry, settle: Number.parseInt(args.settle, 10) } : entry;
	const page = await contexts.get(`${theme}/${vp}`).newPage();
	watchPage(page, rec, vp, base);
	if (entry.fakeSocket) {
		await page.addInitScript(FAKE_WEBSOCKET);
	}
	try {
		const { errors } = await openPreviewPage(page, {
			base,
			theme,
			entry: pageEntry,
			viewport: vp,
			consoleErrors: rec.consoleErrors,
			tag: vp,
		});
		rec.stepErrors.push(...errors);
		await page.waitForTimeout(60);
		await page.evaluate(`window.__vy = (${colorLib.toString()})()`);
		rec.audit = await page.evaluate(pageAudit, {
			palette: palettes[modeOf(theme)],
			tolerance,
			skip,
			mobile: vp === "mobile",
			maxItems: args["full-detail"] ? 100000 : Math.max(maxItems, 5000),
		});
	} catch (error) {
		rec.stepErrors.push(`audit failed: ${String(error.message).split("\n")[0]}`);
	} finally {
		await page.close();
	}
	records.push(rec);
	done++;
	if (done % 50 === 0 || done === jobs.length) {
		console.log(`  ${done}/${jobs.length} page runs`);
	}
});
await browser.close();
await server.close();
console.log(`audited ${jobs.length} page runs in ${((Date.now() - t0) / 1000).toFixed(1)} s`);

// =================================================================================================
// aggregate
// =================================================================================================
records.sort(
	(a, b) =>
		themes.indexOf(a.theme) - themes.indexOf(b.theme) ||
		viewportNames.indexOf(a.viewport) - viewportNames.indexOf(b.viewport) ||
		a.page.localeCompare(b.page),
);

/** Counters of one record, plus the groups it feeds. */
function countsOf(rec) {
	const a = rec.audit;
	if (!a) {
		return {
			contrast: 0,
			contrastUnknown: 0,
			ui: 0,
			leaks: 0,
			leakGroups: 0,
			focus: 0,
			focusWeak: 0,
			focusLow: 0,
			focusUa: 0,
			overflowPage: 0,
			overflow: 0,
			targets: 0,
			errors:
				rec.consoleErrors.length +
				rec.failedRequests.length +
				rec.stepErrors.length +
				rec.php.length,
			broken: 1,
		};
	}
	return {
		contrast: a.contrast.fails.total,
		contrastUnknown: a.contrast.unknown.total,
		ui: a.ui.fails.total,
		leaks: a.leaks.reduce((n, g) => n + g.count, 0),
		leakGroups: a.leaks.length,
		focus: a.focus.fails.total,
		focusWeak: a.focus.weak.total,
		focusLow: a.focus.lowContrast.total,
		focusUa: a.focus.uaDefault,
		overflowPage: a.responsive.docOverflow ? 1 : 0,
		overflow: a.responsive.culprits.total,
		targets: a.responsive.targets.fails.total,
		errors:
			rec.consoleErrors.length + rec.failedRequests.length + rec.stepErrors.length + rec.php.length,
		broken: 0,
	};
}

const sum = (list) => {
	const total = {};
	for (const c of list) {
		for (const [k, v] of Object.entries(c)) {
			total[k] = (total[k] ?? 0) + v;
		}
	}
	return total;
};

const summary = {};
for (const theme of themes) {
	summary[theme] = {};
	for (const vp of viewportNames) {
		const own = records.filter((r) => r.theme === theme && r.viewport === vp);
		summary[theme][vp] = {
			runs: own.length,
			...sum(own.map((r) => ({ ...countsOf(r) }))),
			checkedText: own.reduce((n, r) => n + (r.audit?.contrast.checked ?? 0), 0),
			checkedFocusable: own.reduce((n, r) => n + (r.audit?.focus.checked ?? 0), 0),
			checkedTargets: own.reduce((n, r) => n + (r.audit?.responsive.targets.checked ?? 0), 0),
		};
	}
}

/** group raw items across pages: key function -> {…first item, count, pages[]} */
function groupBy(theme, collect, keyFn, merge) {
	const groups = new Map();
	for (const rec of records) {
		if (rec.theme !== theme || !rec.audit) {
			continue;
		}
		for (const item of collect(rec)) {
			const key = keyFn(item);
			let g = groups.get(key);
			if (!g) {
				g = {
					...item,
					count: 0,
					pages: new Set(),
					viewports: new Set(),
					example: {
						page: rec.page,
						viewport: rec.viewport,
						sel: item.sel ?? item.examples?.[0]?.sel,
					},
				};
				groups.set(key, g);
			}
			g.count += item.count ?? 1;
			g.pages.add(rec.page);
			g.viewports.add(rec.viewport);
			merge?.(g, item);
		}
	}
	return [...groups.values()]
		.map((g) => ({ ...g, pages: [...g.pages], viewports: [...g.viewports] }))
		.sort((a, b) => b.count - a.count);
}

/** raw items of a record per category: what the groups (and the fingerprints) are made of */
const COLLECT = {
	contrast: (r) => r.audit.contrast.fails.items,
	contrastUnknown: (r) => r.audit.contrast.unknown.items,
	ui: (r) => r.audit.ui.fails.items,
	leaks: (r) => r.audit.leaks,
	focus: (r) => r.audit.focus.fails.items,
	focusWeak: (r) => r.audit.focus.weak.items,
	focusLow: (r) => r.audit.focus.lowContrast.items,
	overflow: (r) => r.audit.responsive.culprits.items,
	targets: (r) => r.audit.responsive.targets.fails.items,
	errors: (r) =>
		[...r.consoleErrors, ...r.failedRequests, ...r.stepErrors, ...r.php].map((m) => ({
			key: m.replace(/^\[(desktop|mobile)\] /, "").slice(0, 160),
			sel: "",
		})),
};
const keepMin = (g, item) => {
	if (item.ratio !== undefined && item.ratio < g.ratio) {
		g.ratio = item.ratio;
	}
};
const MERGE = { contrast: keepMin, ui: keepMin, focusLow: keepMin };

const groupsByTheme = {};
for (const theme of themes) {
	groupsByTheme[theme] = Object.fromEntries(
		Object.keys(COLLECT).map((cat) => [
			cat,
			groupBy(theme, COLLECT[cat], GROUP_ID[cat], MERGE[cat]),
		]),
	);
}

// one row per theme / viewport / page / category / group id with its element count: what --compare diffs
const fingerprints = [];
for (const rec of records) {
	if (!rec.audit) {
		continue;
	}
	for (const [cat] of COMPARED) {
		const counts = new Map();
		for (const item of COLLECT[cat](rec)) {
			const id = GROUP_ID[cat](item);
			counts.set(id, (counts.get(id) ?? 0) + (item.count ?? 1));
		}
		for (const [id, count] of counts) {
			fingerprints.push([rec.theme, rec.viewport, rec.page, cat, id, count]);
		}
	}
}

// known false positives the audit skipped: per theme, rule and check
const allowlist = [];
for (const theme of themes) {
	const rows = new Map();
	for (const rec of records) {
		if (rec.theme !== theme || !rec.audit) {
			continue;
		}
		for (const a of rec.audit.allowlisted) {
			const id = `${a.rule}|${a.check}`;
			const row = rows.get(id) ?? {
				theme,
				rule: a.rule,
				check: a.check,
				count: 0,
				pages: new Set(),
				viewports: new Set(),
				example: `${rec.page}/${rec.viewport}: ${a.examples[0].sel}${a.examples[0].note ? ` (${a.examples[0].note})` : ""}`,
			};
			row.count += a.count;
			row.pages.add(rec.page);
			row.viewports.add(rec.viewport);
			rows.set(id, row);
		}
	}
	for (const row of rows.values()) {
		allowlist.push({ ...row, pages: [...row.pages], viewports: [...row.viewports] });
	}
}

// per page "worst pages" (for the JSON and the summary)
const worstPages = {};
for (const theme of themes) {
	worstPages[theme] = records
		.filter((r) => r.theme === theme && r.audit)
		.map((r) => {
			const c = countsOf(r);
			return {
				page: r.page,
				viewport: r.viewport,
				contrast: c.contrast,
				ui: c.ui,
				leaks: c.leaks,
				focus: c.focus,
				targets: c.targets,
				overflow: c.overflow,
			};
		})
		.sort((a, b) => b.contrast + b.leaks - (a.contrast + a.leaks))
		.slice(0, 10);
}

// =================================================================================================
// write JSON
// =================================================================================================
const trimmed = args["full-detail"]
	? records
	: records.map((r) => {
			if (!r.audit) {
				return r;
			}
			const a = r.audit;
			const cut = (list) => ({ total: list.total, items: list.items.slice(0, maxItems) });
			return {
				...r,
				audit: {
					...a,
					contrast: {
						...a.contrast,
						fails: cut(a.contrast.fails),
						unknown: cut(a.contrast.unknown),
					},
					ui: { ...a.ui, fails: cut(a.ui.fails) },
					leaks: a.leaks
						.slice(0, maxItems)
						.map((g) => ({ ...g, examples: g.examples.slice(0, 1) })),
					focus: {
						...a.focus,
						fails: cut(a.focus.fails),
						weak: cut(a.focus.weak),
						lowContrast: cut(a.focus.lowContrast),
					},
					responsive: {
						...a.responsive,
						culprits: cut(a.responsive.culprits),
						targets: { ...a.responsive.targets, fails: cut(a.responsive.targets.fails) },
					},
				},
			};
		});

const jsonGroups = Object.fromEntries(
	themes.map((theme) => [
		theme,
		Object.fromEntries(Object.entries(groupsByTheme[theme]).map(([k, v]) => [k, v.slice(0, 500)])),
	]),
);
fs.mkdirSync(outDir, { recursive: true });
// one top-level key per line, one page run / group per line: greppable and ~half the size of pretty printing
const jsonLines = (value) =>
	Array.isArray(value)
		? `[\n${value.map((v) => JSON.stringify(v)).join(",\n")}\n]`
		: JSON.stringify(value);
const report = {
	meta: {
		generated: new Date().toISOString(),
		themes,
		viewports: viewportNames,
		pages: pages.map((p) => p.id),
		paletteDir,
		paletteModes: Object.fromEntries(themes.map((t) => [t, modeOf(t)])),
		paletteSize: Object.fromEntries(Object.entries(palettes).map(([m, l]) => [m, l.length])),
		paletteTokens,
		paletteWarnings,
		skipped: skip,
		tolerance,
	},
	summary,
	allowlist,
	groups: jsonGroups,
	worstPages,
	fingerprints,
	records: trimmed,
};
fs.writeFileSync(
	outFile,
	`{\n${Object.entries(report)
		.map(([k, v]) => `${JSON.stringify(k)}: ${jsonLines(v)}`)
		.join(",\n")}\n}\n`,
);

// =================================================================================================
// markdown summary
// =================================================================================================
const esc = (s) =>
	String(s ?? "")
		.replace(/\|/g, "\\|")
		.replace(/\n/g, " ");
const table = (head, rows) =>
	[
		`| ${head.join(" | ")} |`,
		`| ${head.map(() => "---").join(" | ")} |`,
		...rows.map((r) => `| ${r.map(esc).join(" | ")} |`),
	].join("\n");
const pagesOf = (g) =>
	g.pages.length > 3
		? `${g.pages.slice(0, 3).join(", ")} (+${g.pages.length - 3})`
		: g.pages.join(", ");

const md = [];
md.push("# Vylaris theme audit", "");
md.push(
	`Pages: ${pages.length}, themes: ${themes.join(", ")}, viewports: ${viewportNames.join(", ")}. Palette: ${themes.map((t) => `${t} -> ${modeOf(t)}`).join(", ")} (${paletteDir.replace(`${repoRoot}/`, "")}), tolerance dE ${tolerance}.`,
	"",
);
let comparison = null;
if (args.compare) {
	const baseFile = path.resolve(args.compare);
	try {
		comparison = compareReports(JSON.parse(fs.readFileSync(baseFile, "utf8")), report, {
			top,
			baseName: baseFile,
		});
	} catch (error) {
		console.error(`--compare: ${error.message}`);
		process.exit(2);
	}
}
if (skip.length) {
	md.push(`Sections left out with --skip: ${skip.join(", ")} (they show 0).`, "");
}
for (const warning of paletteWarnings) {
	md.push(`Palette warning: ${warning}`, "");
}
md.push("## Overview", "");
md.push(
	'Counts are elements (or element/colour combinations for foreign colours); one problem can be counted in several rows when it shows on several pages. "browser ring only" = focusable elements whose only focus indicator is the browser default ring (no theme rule).',
	"",
);
md.push(
	table(
		[
			"theme",
			"viewport",
			"runs",
			"text contrast",
			"UI contrast",
			"foreign colours (groups)",
			"no focus ring",
			"focus weak",
			"browser ring only",
			"focus ring <3:1",
			"overflow pages / culprits",
			"targets <24px",
			"errors",
		],
		themes.flatMap((theme) =>
			viewportNames.map((vp) => {
				const s = summary[theme][vp];
				return [
					theme,
					vp,
					s.broken ? `${s.runs} (${s.broken} failed)` : s.runs,
					`${s.contrast} of ${s.checkedText}`,
					s.ui,
					`${s.leaks} (${s.leakGroups})`,
					`${s.focus} of ${s.checkedFocusable}`,
					s.focusWeak,
					s.focusUa,
					s.focusLow,
					`${s.overflowPage} / ${s.overflow}`,
					vp === "mobile" ? `${s.targets} of ${s.checkedTargets}` : "n/a",
					s.errors,
				];
			}),
		),
	),
	"",
);

if (comparison) {
	md.push(comparison.md);
}

md.push(
	"## Allowlisted (skipped on purpose, not findings)",
	"",
	"Known false positives, handled in the tool (README: Audit, Allowlisted). Counts are elements.",
	"",
);
if (allowlist.length === 0) {
	md.push("none matched on these pages", "");
} else {
	md.push(
		table(
			["theme", "rule", "check", "elements", "pages", "viewports", "example"],
			allowlist.map((a) => [
				a.theme,
				a.rule,
				a.check,
				a.count,
				a.pages.length,
				a.viewports.join(", "),
				a.example,
			]),
		),
		"",
	);
}

const sections = [
	[
		"contrast",
		"Text contrast failures",
		["count", "pages", "ratio", "needs", "element", "fg on bg", "sample"],
		(g) => [g.count, g.pages.length, g.ratio, g.required, g.key, `${g.fg} on ${g.bg}`, g.text],
	],
	[
		"ui",
		"Non-text contrast (< 3:1)",
		["count", "pages", "ratio", "kind", "element", "fg on bg"],
		(g) => [g.count, g.pages.length, g.ratio, g.kind, g.key, `${g.fg} on ${g.bg}`],
	],
	[
		"leaks",
		"Foreign colours",
		["count", "pages", "property", "colour", "element", "nearest token", "dE", "example"],
		(g) => [
			g.count,
			g.pages.length,
			g.prop,
			g.color,
			g.key + (g.origin ? ` (from ${g.origin})` : ""),
			`${g.nearest} ${g.nearestHex}`,
			g.deltaE,
			`${g.example.page}: ${g.example.sel}`,
		],
	],
	[
		"focus",
		"Focusable without any visible change",
		["count", "pages", "element", "example"],
		(g) => [g.count, g.pages.length, g.key, `${g.example.page}: ${g.text}`],
	],
	[
		"focusWeak",
		"Focus shown by colour / background change only",
		["count", "pages", "element", "change"],
		(g) => [g.count, g.pages.length, g.key, g.changes.join(", ")],
	],
	[
		"focusLow",
		"Focus ring below 3:1 on its background",
		["count", "pages", "ratio", "element", "indicator"],
		(g) => [g.count, g.pages.length, g.ratio, g.key, g.indicator],
	],
	[
		"overflow",
		"Elements that overflow the viewport horizontally",
		["count", "pages", "width", "wider than viewport", "element"],
		(g) => [g.count, g.pages.length, g.width, g.wide ? "yes" : "no", g.key],
	],
	[
		"targets",
		"Touch targets below 24x24 CSS px (mobile)",
		["count", "pages", "size", "element", "sample"],
		(g) => [g.count, g.pages.length, `${g.w}x${g.h}`, g.key, g.text],
	],
	[
		"errors",
		"Console errors, failed requests, step failures",
		["count", "pages", "message"],
		(g) => [g.count, g.pages.length, g.key],
	],
];

for (const theme of themes) {
	md.push(`## ${theme}`, "");
	const worst = worstPages[theme].slice(0, 5);
	if (worst.length) {
		md.push(
			`Worst pages (text contrast + foreign colours): ${worst.map((w) => `${w.page}/${w.viewport} (${w.contrast}+${w.leaks})`).join(", ")}`,
			"",
		);
	}
	for (const [id, title, head, row] of sections) {
		const list = groupsByTheme[theme][id];
		md.push(
			`### ${theme}: ${title} (${list.length} groups, top ${Math.min(top, list.length)})`,
			"",
		);
		if (list.length === 0) {
			md.push("none", "");
			continue;
		}
		md.push(table(head, list.slice(0, top).map(row)), "");
	}
	if (groupsByTheme[theme].contrastUnknown.length) {
		md.push(
			`Contrast not decidable (background image behind text): ${groupsByTheme[theme].contrastUnknown.reduce((n, g) => n + g.count, 0)} elements, e.g. ${groupsByTheme[
				theme
			].contrastUnknown
				.slice(0, 5)
				.map((g) => g.key)
				.join(", ")}`,
			"",
		);
	}
}
const mdText = md.join("\n");
const mdFile = `${outFile.replace(/\.json$/, "")}.md`;
fs.writeFileSync(mdFile, mdText);
console.log(`\n${mdText}`);
console.log(`\nJSON: ${outFile}\nMarkdown: ${mdFile}`);
if (args["fail-on-new"] && comparison && comparison.newGroups > 0) {
	process.exitCode = 1;
}
