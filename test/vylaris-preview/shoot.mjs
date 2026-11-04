// Render the preview pages with PHP and screenshot them with Playwright, no Hestia backend needed.
//
//   node test/vylaris-preview/shoot.mjs --css <dir> --themes vylaris,vylaris-dark,default \
//        --viewports desktop,mobile --pages all --out <dir> [--full-page]
//
// See README.md for all options.
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
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
		themes: { type: "string", default: "vylaris,vylaris-dark,default" },
		viewports: { type: "string", default: "desktop,mobile" },
		pages: { type: "string", default: "all" },
		out: { type: "string" },
		manifest: { type: "string", default: path.join(previewRoot, "pages.json") },
		"full-page": { type: "boolean", default: false },
		animations: { type: "string", default: "off" },
		concurrency: { type: "string", default: "6" },
		"render-only": { type: "boolean", default: false },
		list: { type: "boolean", default: false },
		help: { type: "boolean", default: false },
	},
});

const usage = `Usage: node test/vylaris-preview/shoot.mjs --css <dir> --out <dir> [options]

  --css <dir>          directory with <theme>.min.css (see build-css.mjs)
  --out <dir>          output: <out>/html, <out>/<theme>/<viewport>/<page>.png, <out>/report.json
  --themes a,b         default: vylaris,vylaris-dark,default
  --viewports a,b      desktop (1440x900) and/or mobile (390x844); default: both
  --pages a,b|all      page ids or group:<name>; default: all
  --full-page          screenshot the whole scroll height instead of the viewport
  --animations on|off  off (default): reduced motion and zero animation durations
  --concurrency <n>    parallel pages, default 6
  --render-only        only render with PHP and report PHP problems, no browser
  --manifest <file>    default: test/vylaris-preview/pages.json
  --list               print the page ids and exit`;

if (args.help) {
	console.log(usage);
	process.exit(0);
}

const manifestPath = path.resolve(args.manifest);
const manifest = loadManifest(manifestPath);

if (args.list) {
	for (const p of manifest.pages) {
		console.log(`${p.id}\t${p.group ?? ""}`);
	}
	process.exit(0);
}
if (!args.out || (!args.css && !args["render-only"])) {
	console.error(usage);
	process.exit(2);
}

const outDir = path.resolve(args.out);
const cssDir = args.css ? path.resolve(args.css) : null;
const themes = args.themes.split(",").filter(Boolean);
let viewportNames;
let pages;
try {
	viewportNames = parseViewports(args.viewports);
	pages = selectPages(manifest, args.pages);
} catch (error) {
	console.error(error.message);
	process.exit(2);
}

// ---- main --------------------------------------------------------------------------------------
const concurrency = Math.max(1, Number.parseInt(args.concurrency, 10) || 6);
const { htmlDir, results } = await prerender({
	themes,
	pages,
	outDir,
	manifestPath,
	concurrency,
});

const phpBroken = [...results.entries()].filter(([, r]) => r.phpCode !== 0);
for (const [key, r] of phpBroken) {
	console.log(`PHP  ${key}`);
	for (const line of r.php) {
		console.log(`       ${line}`);
	}
}

// 2. Screenshots
if (!args["render-only"]) {
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
	const animationsOff = args.animations !== "on";
	const contexts = await createContexts(browser, themes, viewportNames, animationsOff);

	const shotJobs = [];
	for (const theme of themes) {
		for (const vp of viewportNames) {
			for (const entry of pages) {
				if (entry.viewports && !entry.viewports.includes(vp)) {
					continue;
				}
				shotJobs.push({ theme, vp, entry });
			}
		}
	}

	const t1 = Date.now();
	await pool(shotJobs, concurrency, async ({ theme, vp, entry }) => {
		const result = results.get(keyOf(theme, entry.id));
		const tag = `${vp}`;
		const page = await contexts.get(`${theme}/${vp}`).newPage();
		watchPage(page, result, tag, base);
		if (entry.fakeSocket) {
			await page.addInitScript(FAKE_WEBSOCKET);
		}
		try {
			const { clip, errors } = await openPreviewPage(page, {
				base,
				theme,
				entry,
				viewport: vp,
				consoleErrors: result.consoleErrors,
				tag,
			});
			for (const message of errors) {
				result.stepErrors.push(`[${tag}] ${message}`);
			}
			await page.waitForTimeout(animationsOff ? 60 : 400);
			const file = path.join(outDir, theme, vp, `${entry.id}.png`);
			fs.mkdirSync(path.dirname(file), { recursive: true });
			if (clip) {
				await page.locator(clip).first().screenshot({ path: file });
			} else {
				await page.screenshot({
					path: file,
					fullPage: args["full-page"] || Boolean(entry.fullPage),
				});
			}
			result.shots[vp] = file;
		} catch (error) {
			result.stepErrors.push(`[${tag}] screenshot failed: ${String(error.message).split("\n")[0]}`);
		} finally {
			await page.close();
		}
	});
	console.log(`took ${shotJobs.length} screenshots in ${Date.now() - t1} ms`);
	await browser.close();
	await server.close();
}

// 3. Report
const rows = [];
let problems = 0;
for (const entry of pages) {
	const cells = [];
	for (const theme of themes) {
		const r = results.get(keyOf(theme, entry.id));
		const flags = [];
		if (r.phpCode !== 0) flags.push(`php:${r.php.length}`);
		if (r.consoleErrors.length) flags.push(`js:${r.consoleErrors.length}`);
		if (r.failedRequests.length) flags.push(`req:${r.failedRequests.length}`);
		if (r.stepErrors.length) flags.push(`step:${r.stepErrors.length}`);
		if (flags.length) problems++;
		cells.push(flags.length ? flags.join(" ") : "ok");
	}
	rows.push([entry.id, ...cells]);
}
const widths = ["page", ...themes].map((h, i) =>
	Math.max(h.length, ...rows.map((r) => r[i].length)),
);
const line = (cols) => cols.map((c, i) => c.padEnd(widths[i])).join("  ");
console.log(`\n${line(["page", ...themes])}`);
console.log(widths.map((w) => "-".repeat(w)).join("  "));
for (const row of rows) {
	console.log(line(row));
}

const detail = (title, pick) => {
	const seen = new Map();
	for (const entry of pages) {
		for (const theme of themes) {
			for (const msg of pick(results.get(keyOf(theme, entry.id)))) {
				const text = msg.replace(/^\[(desktop|mobile)\] /, "");
				const owner = seen.get(text) ?? new Set();
				owner.add(entry.id);
				seen.set(text, owner);
			}
		}
	}
	if (seen.size) {
		console.log(`\n${title}`);
		for (const [text, owners] of seen) {
			const list = [...owners];
			console.log(
				`  ${text}\n    on: ${list.slice(0, 8).join(", ")}${list.length > 8 ? ` (+${list.length - 8})` : ""}`,
			);
		}
	}
};
detail("PHP warnings / notices", (r) => (r.phpCode !== 0 ? r.php : []));
detail("Console errors", (r) => r.consoleErrors);
detail("Failed requests (404 fonts/images/css/js ...)", (r) => r.failedRequests);
detail("Step / screenshot errors", (r) => r.stepErrors);

fs.writeFileSync(
	path.join(outDir, "report.json"),
	JSON.stringify(
		{ themes, viewports: viewportNames, pages: Object.fromEntries(results) },
		null,
		"\t",
	),
);
console.log(
	`\n${pages.length} pages x ${themes.length} themes, ${problems} page/theme combinations with problems. Output: ${outDir}`,
);
process.exit(problems ? 1 : 0);
