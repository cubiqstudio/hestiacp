// Build ALL web/css/src/themes/*.css into <outDir>/<name>.min.css.
//
// Same lightningcss options, resolver and visitor as /build.js (copied on purpose: build.js runs
// itself on import and always writes into web/css/themes, which this script must never touch).
//
//   node test/vylaris-preview/build-css.mjs <outDir> [--isolate <partial>[,<partial>...]]
//
// --isolate: build from a private copy of web/css/src in which every web/css/src/themes/vylaris/*.css
// partial EXCEPT the named ones is replaced by its last committed (git HEAD) version. This lets several
// people work on different partials at the same time without a half-written file breaking each other's build.
import { execFileSync } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import browserslist from "browserslist";
import * as lightningcss from "lightningcss";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const srcRoot = path.join(repoRoot, "web/css/src");
const themesSourcePath = path.join(srcRoot, "themes");

/** Copy web/css/src to <outDir>/.src-isolated, resetting all vylaris partials except `keep` to git HEAD. */
async function isolatedSource(outDir, keep) {
	const copy = path.join(outDir, ".src-isolated");
	await fs.rm(copy, { recursive: true, force: true });
	await fs.cp(srcRoot, copy, { recursive: true });
	const partialDir = path.join(copy, "themes", "vylaris");
	const keepNames = new Set(keep.map((k) => k.replace(/\.css$/, "")));
	for (const file of await fs.readdir(partialDir)) {
		const name = file.replace(/\.css$/, "");
		if (keepNames.has(name) || ["tokens", "mode-light", "mode-dark"].includes(name)) continue;
		let committed = "";
		try {
			committed = execFileSync("git", ["show", `HEAD:web/css/src/themes/vylaris/${file}`], {
				cwd: repoRoot,
				encoding: "utf8",
				stdio: ["ignore", "pipe", "ignore"],
			});
		} catch {
			// not committed yet: use an empty stub
		}
		await fs.writeFile(path.join(partialDir, file), committed);
	}
	for (const k of keepNames) {
		await fs.access(path.join(partialDir, `${k}.css`)).catch(() => {
			throw new Error(`--isolate: unknown partial "${k}"`);
		});
	}
	return path.join(copy, "themes");
}

async function processCSS(inputFile, outputFile) {
	await fs.mkdir(path.dirname(outputFile), { recursive: true });
	const css = await fs.readFile(inputFile);
	const bundle = await lightningcss.bundleAsync({
		filename: inputFile,
		sourceMap: true,
		code: Buffer.from(css),
		minify: true,
		targets: lightningcss.browserslistToTargets(browserslist(undefined, { path: repoRoot })),
		drafts: { customMedia: true, nesting: true },
		visitor: {
			Url: (node) => {
				// Fix relative paths for webfonts
				if (node.url.startsWith("../webfonts/")) {
					return {
						url: node.url.replace("../webfonts/", "/webfonts/"),
						loc: node.loc,
					};
				}
				return node;
			},
		},
		resolver: {
			resolve(specifier, from) {
				if (!specifier.endsWith(".css")) {
					specifier += ".css";
				}
				if (specifier.startsWith("node:")) {
					// build.js uses a cwd relative path, here it is anchored at the repo root
					return path.join(repoRoot, "node_modules", specifier.replace("node:", ""));
				}
				return `${path.dirname(from)}/${specifier}`;
			},
		},
	});
	await fs.writeFile(outputFile, bundle.code);
	await fs.writeFile(`${outputFile}.map`, bundle.map);
	return bundle.code.length;
}

/**
 * @param {string} outDir directory that receives <name>.min.css
 * @returns {Promise<{name: string, bytes: number}[]>}
 */
export async function buildThemes(outDir, { isolate = [] } = {}) {
	const resolvedOut = path.resolve(outDir);
	const realThemes = path.join(repoRoot, "web/css/themes");
	if (resolvedOut === realThemes || resolvedOut.startsWith(`${realThemes}${path.sep}`)) {
		throw new Error(`Refusing to write into ${realThemes}`);
	}
	const sourceDir = isolate.length ? await isolatedSource(resolvedOut, isolate) : themesSourcePath;
	const entries = (await fs.readdir(sourceDir)).filter((e) => path.extname(e) === ".css");
	return Promise.all(
		entries.map(async (entry) => {
			const bytes = await processCSS(
				path.join(sourceDir, entry),
				path.join(resolvedOut, entry.replace(".css", ".min.css")),
			);
			return { name: entry.replace(".css", ""), bytes };
		}),
	);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const args = process.argv.slice(2);
	const outDir = args.find((a) => !a.startsWith("--") && args[args.indexOf(a) - 1] !== "--isolate");
	const isoIndex = args.indexOf("--isolate");
	const isolate = isoIndex >= 0 && args[isoIndex + 1] ? args[isoIndex + 1].split(",") : [];
	if (!outDir) {
		console.error(
			"Usage: node test/vylaris-preview/build-css.mjs <outDir> [--isolate <partial>[,...]]",
		);
		process.exit(2);
	}
	try {
		const built = await buildThemes(outDir, { isolate });
		for (const { name, bytes } of built.sort((a, b) => a.name.localeCompare(b.name))) {
			console.log(`built ${name}.min.css (${bytes} bytes)`);
		}
	} catch (error) {
		console.error("CSS build failed:", error.message);
		process.exit(1);
	}
}
