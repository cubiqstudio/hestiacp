// Build ALL web/css/src/themes/*.css into <outDir>/<name>.min.css.
//
// Same lightningcss options, resolver and visitor as /build.js (copied on purpose: build.js runs
// itself on import and always writes into web/css/themes, which this script must never touch).
//
//   node test/vylaris-preview/build-css.mjs <outDir>
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import browserslist from "browserslist";
import * as lightningcss from "lightningcss";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const themesSourcePath = path.join(repoRoot, "web/css/src/themes");

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
export async function buildThemes(outDir) {
	const resolvedOut = path.resolve(outDir);
	const realThemes = path.join(repoRoot, "web/css/themes");
	if (resolvedOut === realThemes || resolvedOut.startsWith(`${realThemes}${path.sep}`)) {
		throw new Error(`Refusing to write into ${realThemes}`);
	}
	const entries = (await fs.readdir(themesSourcePath)).filter((e) => path.extname(e) === ".css");
	return Promise.all(
		entries.map(async (entry) => {
			const bytes = await processCSS(
				path.join(themesSourcePath, entry),
				path.join(resolvedOut, entry.replace(".css", ".min.css")),
			);
			return { name: entry.replace(".css", ""), bytes };
		}),
	);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const outDir = process.argv[2];
	if (!outDir) {
		console.error("Usage: node test/vylaris-preview/build-css.mjs <outDir>");
		process.exit(2);
	}
	try {
		const built = await buildThemes(outDir);
		for (const { name, bytes } of built.sort((a, b) => a.name.localeCompare(b.name))) {
			console.log(`built ${name}.min.css (${bytes} bytes)`);
		}
	} catch (error) {
		console.error("CSS build failed:", error.message);
		process.exit(1);
	}
}
