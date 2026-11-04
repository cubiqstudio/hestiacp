// Code shared by shoot.mjs and audit.mjs: page selection, Playwright loading, the PHP pre-render
// pass, the browser contexts and the console / request listeners.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { ensureGermanLocale, previewRoot, renderPage } from "./php.mjs";
import { runSteps } from "./steps.mjs";

export const repoRoot = path.resolve(previewRoot, "..", "..");
export const VIEWPORTS = {
	desktop: { width: 1440, height: 900 },
	mobile: { width: 390, height: 844 },
};

export const FREEZE_CSS =
	"*,*::before,*::after{animation-duration:0s!important;animation-delay:0s!important;animation-iteration-count:1!important;transition-duration:0s!important;transition-delay:0s!important;scroll-behavior:auto!important;caret-color:transparent!important}:root{--animate-duration:0s!important}";

export function loadManifest(manifestPath) {
	return JSON.parse(fs.readFileSync(path.resolve(manifestPath), "utf8"));
}

/** Page ids or `group:<name>` tokens (or "all") -> manifest entries. Throws on unknown tokens. */
export function selectPages(manifest, spec) {
	if (spec === "all") {
		return manifest.pages;
	}
	const chosen = [];
	for (const token of spec.split(",").filter(Boolean)) {
		const found = token.startsWith("group:")
			? manifest.pages.filter((p) => p.group === token.slice(6))
			: manifest.pages.filter((p) => p.id === token);
		if (found.length === 0) {
			throw new Error(`Unknown page or group: ${token}`);
		}
		chosen.push(...found);
	}
	return [...new Set(chosen)];
}

export function parseViewports(list) {
	const names = list.split(",").filter(Boolean);
	for (const name of names) {
		if (!VIEWPORTS[name]) {
			throw new Error(`Unknown viewport "${name}" (desktop, mobile)`);
		}
	}
	return names;
}

// Playwright is installed globally, not in the repo
export async function loadPlaywright() {
	try {
		return await import("playwright");
	} catch {
		// fall through to the global install
	}
	const roots = [
		process.env.NODE_PATH,
		execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim(),
	]
		.flatMap((v) => (v ?? "").split(path.delimiter))
		.filter(Boolean);
	for (const root of roots) {
		try {
			return createRequire(path.join(root, "noop.js"))("playwright");
		} catch {
			// try next
		}
	}
	throw new Error(
		"playwright not found: install it globally (npm i -g playwright) or set NODE_PATH",
	);
}

export async function pool(items, limit, worker) {
	const queue = [...items];
	const runners = Array.from({ length: Math.min(limit, queue.length) }, async () => {
		while (queue.length) {
			await worker(queue.shift());
		}
	});
	await Promise.all(runners);
}

export const keyOf = (theme, id) => `${theme}/${id}`;

/**
 * Render every theme x page with PHP into <outDir>/html/<theme>/<id>.html.
 * @returns {Promise<{htmlDir: string, results: Map<string, object>}>} results keyed by `theme/id`
 */
export async function prerender({ themes, pages, outDir, manifestPath, concurrency }) {
	const htmlDir = path.join(outDir, "html");
	fs.mkdirSync(htmlDir, { recursive: true });

	let locpath;
	if (pages.some((p) => p.lang === "de")) {
		const loc = ensureGermanLocale(path.join(outDir, ".locale"));
		if (loc.ok) {
			locpath = loc.locpath;
		} else {
			console.warn(
				`warning: cannot build the de_DE locale, German pages stay English (${loc.reason})`,
			);
		}
	}

	const t0 = Date.now();
	const results = new Map();
	const jobs = themes.flatMap((theme) => pages.map((entry) => ({ theme, entry })));
	await pool(jobs, concurrency + 2, async ({ theme, entry }) => {
		const res = await renderPage({
			id: entry.id,
			theme,
			lang: entry.lang ?? "en",
			outFile: path.join(htmlDir, theme, `${entry.id}.html`),
			manifest: manifestPath,
			locpath,
		});
		results.set(keyOf(theme, entry.id), {
			php: res.problems,
			phpCode: res.code,
			consoleErrors: [],
			failedRequests: [],
			stepErrors: [],
			shots: {},
		});
	});
	console.log(`rendered ${jobs.length} html files with PHP in ${Date.now() - t0} ms`);
	return { htmlDir, results };
}

/** One browser context per theme x viewport, `Map<"theme/viewport", context>`. */
export async function createContexts(browser, themes, viewportNames, animationsOff) {
	const contexts = new Map();
	for (const theme of themes) {
		for (const vp of viewportNames) {
			const context = await browser.newContext({
				viewport: VIEWPORTS[vp],
				deviceScaleFactor: 1,
				reducedMotion: animationsOff ? "reduce" : "no-preference",
				colorScheme: "light",
				locale: "en-US",
			});
			if (animationsOff) {
				await context.addInitScript((css) => {
					document.addEventListener("DOMContentLoaded", () => {
						const style = document.createElement("style");
						style.textContent = css;
						document.head.append(style);
					});
				}, FREEZE_CSS);
			}
			contexts.set(`${theme}/${vp}`, context);
		}
	}
	return contexts;
}

/** Collect console errors, uncaught errors and failed / 4xx+ requests of a page into `result`. */
export function watchPage(page, result, tag, base) {
	page.on("console", (msg) => {
		if (msg.type() === "error") {
			result.consoleErrors.push(`[${tag}] ${msg.text()}`);
		}
	});
	page.on("pageerror", (error) => result.consoleErrors.push(`[${tag}] uncaught: ${error.message}`));
	page.on("requestfailed", (request) =>
		result.failedRequests.push(
			`[${tag}] ${request.failure()?.errorText} ${request.url().replace(base, "")}`,
		),
	);
	page.on("response", (response) => {
		if (response.status() >= 400) {
			result.failedRequests.push(
				`[${tag}] ${response.status()} ${response.url().replace(base, "")}`,
			);
		}
	});
}

/**
 * Open a pre-rendered page, wait for fonts and Alpine, then run the `steps` of the manifest entry.
 * @returns {Promise<{clip: string | null, errors: string[]}>}
 */
export async function openPreviewPage(page, { base, theme, entry, viewport, consoleErrors, tag }) {
	await page.goto(`${base}/__preview/${theme}/${entry.id}.html`, { waitUntil: "load" });
	await page.evaluate(() => document.fonts.ready);
	await page
		.waitForFunction(() => window.Alpine !== undefined, null, { timeout: 5000 })
		.catch(() => consoleErrors.push(`[${tag}] Alpine did not start`));
	await page.waitForTimeout(entry.settle ?? 250);
	return runSteps(page, entry.steps, viewport);
}
