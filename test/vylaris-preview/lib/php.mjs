// Pre-render pages with the PHP CLI (render.php) and manage the German test locale.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export const previewRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

/**
 * GNU gettext only translates when a real (non-C) locale is active. The sandbox has none, so we
 * compile de_DE.UTF-8 into <dir> (no root needed) and point LOCPATH at it.
 * @returns {{ok: boolean, locpath?: string, reason?: string}}
 */
export function ensureGermanLocale(dir) {
	const target = path.join(dir, "de_DE.UTF-8");
	if (fs.existsSync(path.join(target, "LC_CTYPE"))) {
		return { ok: true, locpath: dir };
	}
	fs.mkdirSync(dir, { recursive: true });
	const res = spawnSync("localedef", ["-i", "de_DE", "-f", "UTF-8", target], { encoding: "utf8" });
	// localedef exits 1 for harmless warnings as long as the files were written
	if (fs.existsSync(path.join(target, "LC_CTYPE"))) {
		return { ok: true, locpath: dir };
	}
	return { ok: false, reason: (res.stderr || res.error?.message || "localedef failed").trim() };
}

/**
 * Render one page. Resolves { html path, problems[] } - problems are PHP warnings/notices.
 */
export function renderPage({ id, theme, lang, outFile, manifest, locpath }) {
	return new Promise((resolve) => {
		const args = [
			"-d",
			"short_open_tag=0",
			"-d",
			"memory_limit=512M",
			path.join(previewRoot, "render.php"),
			"--page",
			id,
			"--theme",
			theme,
			"--manifest",
			manifest,
			"--out",
			outFile,
		];
		if (lang) {
			args.push("--lang", lang);
		}
		const env = { PATH: process.env.PATH ?? "" };
		if (locpath) {
			env.LOCPATH = locpath;
		}
		const child = spawn("php", args, { env });
		let stderr = "";
		child.stderr.on("data", (chunk) => {
			stderr += chunk;
		});
		child.on("error", (error) =>
			resolve({ code: 2, problems: [`cannot start php: ${error.message}`] }),
		);
		child.on("close", (code) => {
			const problems = stderr
				.split("\n")
				.filter(Boolean)
				.map((line) => line.replace(/^PHP: /, ""));
			resolve({ code, problems });
		});
	});
}
